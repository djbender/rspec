module RSpec
  module Core
    # Provides the main entry point to run a suite of RSpec examples.
    class Runner
      # @attr_reader
      # @private
      attr_reader :options, :configuration, :world

      # Register an `at_exit` hook that runs the suite when the process exits.
      #
      # @note This is not generally needed. The `rspec` command takes care
      #       of running examples for you without involving an `at_exit`
      #       hook. This is only needed if you are running specs using
      #       the `ruby` command, and even then, the normal way to invoke
      #       this is by requiring `rspec/autorun`.
      def self.autorun
        if autorun_disabled?
          RSpec.deprecate("Requiring `rspec/autorun` when running RSpec via the `rspec` command")
          return
        elsif installed_at_exit? || running_in_drb?
          return
        end

        at_exit { perform_at_exit }
        @installed_at_exit = true
      end

      # @private
      def self.perform_at_exit
        # Don't bother running any specs and just let the program terminate
        # if we got here due to an unrescued exception (anything other than
        # SystemExit, which is raised when somebody calls Kernel#exit).
        return unless $!.nil? || $!.is_a?(SystemExit)

        # We got here because either the end of the program was reached or
        # somebody called Kernel#exit. Run the specs and then override any
        # existing exit status with RSpec's exit status if any specs failed.
        invoke
      end

      # Runs the suite of specs and exits the process with an appropriate exit
      # code.
      def self.invoke
        disable_autorun!
        status = run(ARGV, $stderr, $stdout).to_i
        exit(status) if status != 0
      end

      # Run a suite of RSpec examples. Does not exit.
      #
      # This is used internally by RSpec to run a suite, but is available
      # for use by any other automation tool.
      #
      # If you want to run this multiple times in the same process, and you
      # want files like `spec_helper.rb` to be reloaded, be sure to load `load`
      # instead of `require`.
      #
      # @param args [Array] command-line-supported arguments
      # @param err [IO] error stream
      # @param out [IO] output stream
      # @return [Fixnum] exit status code. 0 if all specs passed,
      #   or the configured failure exit code (1 by default) if specs
      #   failed.
      def self.run(args, err=$stderr, out=$stdout)
        trap_interrupt
        options = ConfigurationOptions.new(args)

        if options.options[:runner]
          options.options[:runner].call(options, err, out)
        else
          new(options).run(err, out)
        end
      end

      def initialize(options, configuration=RSpec.configuration, world=RSpec.world)
        @options       = options
        @configuration = configuration
        @world         = world
      end

      # Configures and runs a spec suite.
      #
      # @param err [IO] error stream
      # @param out [IO] output stream
      def run(err, out)
        setup(err, out)
        return @configuration.reporter.exit_early(exit_code) if RSpec.world.wants_to_quit

        run_specs(@world.ordered_example_groups).tap do
          persist_example_statuses
        end
      end

      # Wires together the various configuration objects and state holders.
      #
      # @param err [IO] error stream
      # @param out [IO] output stream
      def setup(err, out)
        configure(err, out)
        return if RSpec.world.wants_to_quit

        @configuration.load_spec_files
      ensure
        @world.announce_filters
      end

      # Runs the provided example groups.
      #
      # @param example_groups [Array<RSpec::Core::ExampleGroup>] groups to run
      # @return [Fixnum] exit status code. 0 if all specs passed,
      #   or the configured failure exit code (1 by default) if specs
      #   failed.
      def run_specs(example_groups)
        # Determine worker count, preferring CLI option over config setting
        worker_count = @configuration.parallel_workers

        # Use parallel execution if worker_count > 1
        if worker_count && worker_count > 1
          # Separate parallel-safe from serial-only tests
          # Tests marked with :serial metadata run sequentially after parallel tests
          parallel_groups, sequential_groups = partition_groups_for_parallel(example_groups)

          # Run parallel tests first (if any)
          parallel_exit_code = if parallel_groups.any?
                                 run_specs_in_parallel(parallel_groups, worker_count)
                               else
                                 0 # No parallel tests to run
                               end

          # Run sequential tests after (if any)
          sequential_exit_code = if sequential_groups.any?
                                   run_specs_sequentially(sequential_groups)
                                 else
                                   0 # No sequential tests to run
                                 end

          # Return failure if either phase failed
          parallel_exit_code == 0 ? sequential_exit_code : parallel_exit_code
        else
          # Sequential execution for all tests (original behavior)
          run_specs_sequentially(example_groups)
        end
      end

      # @private
      # Run specs in parallel using ParallelRunner
      def run_specs_in_parallel(example_groups, worker_count)
        RSpec::Support.require_rspec_core 'parallel_runner'
        examples_count = @world.example_count(example_groups)

        # Wrap parallel execution in reporter.report to ensure proper
        # formatter lifecycle (start, stop, notifications, etc.)
        examples_passed = @configuration.reporter.report(examples_count) do |reporter|
          # Inform user about parallel execution (but not if we're already in a worker)
          unless @configuration.in_parallel_worker
            process_word = worker_count == 1 ? "process" : "processes"
            reporter.message("\nRunning tests in parallel using #{worker_count} #{process_word}\n")
          end

          parallel_runner = RSpec::Core::ParallelRunner.new(
            :example_groups => example_groups,
            :worker_count => worker_count,
            :configuration => @configuration
          )

          result = parallel_runner.run

          # Replay example notifications to formatters
          # This allows formatters to show individual example results even though
          # examples ran in worker processes
          parallel_runner.replay_notifications(result.worker_results, reporter)

          # Determine if all examples passed
          result.failed_count == 0
        end

        exit_code(examples_passed)
      end

      # @private
      # Run specs sequentially (non-parallel execution)
      def run_specs_sequentially(example_groups)
        examples_count = @world.example_count(example_groups)

        examples_passed = @configuration.reporter.report(examples_count) do |reporter|
          @configuration.with_suite_hooks do
            if examples_count == 0 && @configuration.fail_if_no_examples
              return @configuration.failure_exit_code
            end

            example_groups.map { |g| g.run(reporter) }.all?
          end
        end

        exit_code(examples_passed)
      end

      # @private
      # Partition example groups into parallel-safe and serial-only
      # Serial tests are those marked with :serial metadata
      def partition_groups_for_parallel(groups)
        groups.partition { |g| !g.metadata[:serial] }
      end

      # @private
      def configure(err, out)
        @configuration.error_stream = err
        @configuration.output_stream = out if @configuration.output_stream == $stdout
        @options.configure(@configuration)
      end

      # @private
      def self.disable_autorun!
        @autorun_disabled = true
      end

      # @private
      def self.autorun_disabled?
        @autorun_disabled ||= false
      end

      # @private
      def self.installed_at_exit?
        @installed_at_exit ||= false
      end

      # @private
      def self.running_in_drb?
        return false unless defined?(DRb)

        server = begin
                   DRb.current_server
                 rescue DRb::DRbServerNotFound
                   return false
                 end

        return false unless server && server.alive?

        require 'socket'
        require 'uri'

        local_ipv4 = begin
                       IPSocket.getaddress(Socket.gethostname)
                     rescue SocketError
                       return false
                     end

        ["127.0.0.1", "localhost", local_ipv4].any? { |addr| addr == URI(DRb.current_server.uri).host }
      end

      # @private
      def self.trap_interrupt
        trap('INT') { handle_interrupt }
      end

      # @private
      def self.handle_interrupt
        if RSpec.world.wants_to_quit
          exit!(1)
        else
          RSpec.world.wants_to_quit = true

          $stderr.puts(
            "\nRSpec is shutting down and will print the summary report... Interrupt again to force quit " \
            "(warning: at_exit hooks will be skipped if you force quit)."
          )
        end
      end

      # @private
      def exit_code(examples_passed=false)
        return @configuration.error_exit_code || @configuration.failure_exit_code if @world.non_example_failure
        return @configuration.failure_exit_code unless examples_passed

        0
      end

    private

      def persist_example_statuses
        return if @configuration.dry_run
        return unless (path = @configuration.example_status_persistence_file_path)

        ExampleStatusPersister.persist(@world.all_examples, path)
      rescue SystemCallError => e
        RSpec.warning "Could not write example statuses to #{path} (configured as " \
                      "`config.example_status_persistence_file_path`) due to a " \
                      "system error: #{e.inspect}. Please check that the config " \
                      "option is set to an accessible, valid file path", :call_site => nil
      end
    end
  end
end
