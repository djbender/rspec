module RSpec
  module Core
    # Runs example groups in parallel across multiple worker processes.
    # This provides significant performance improvements for large test suites
    # by utilizing multiple CPU cores.
    #
    # @private
    class ParallelRunner
      # Result object returned from parallel execution
      class Result
        attr_reader :example_count, :passed_count, :failed_count, :pending_count

        def initialize(example_count:, passed_count:, failed_count:, pending_count:)
          @example_count = example_count
          @passed_count = passed_count
          @failed_count = failed_count
          @pending_count = pending_count
        end
      end

      # @param example_groups [Array<ExampleGroup>] the groups to run
      # @param worker_count [Integer] number of worker processes to fork
      # @param configuration [Configuration] RSpec configuration
      def initialize(example_groups:, worker_count:, configuration:)
        @example_groups = example_groups
        @worker_count = worker_count
        @configuration = configuration
      end

      # Run the example groups across worker processes
      # @return [Result] aggregated results from all workers
      def run
        # Divide groups among workers
        groups_per_worker = distribute_groups

        # Fork worker processes and collect results
        worker_results = groups_per_worker.map.with_index do |groups, index|
          run_worker(groups, index)
        end

        # Aggregate results
        aggregate_results(worker_results)
      end

      private

      # Distribute example groups across workers
      def distribute_groups
        groups_per_worker = Array.new(@worker_count) { [] }

        @example_groups.each_with_index do |group, index|
          worker_index = index % @worker_count
          groups_per_worker[worker_index] << group
        end

        groups_per_worker
      end

      # Run groups in a worker process
      # @param groups [Array<ExampleGroup>] groups to run in this worker
      # @param _worker_index [Integer] worker index (reserved for future use in logging/debugging)
      def run_worker(groups, _worker_index)
        # Create pipes for IPC and output capture
        result_reader, result_writer = IO.pipe
        stdout_reader, stdout_writer = IO.pipe
        stderr_reader, stderr_writer = IO.pipe

        pid = fork do
          result_reader.close
          stdout_reader.close
          stderr_reader.close

          begin
            # Redirect stdout and stderr to pipes
            # We use STDOUT/STDERR constants (real IO file descriptors) instead of
            # $stdout/$stderr (which may be reassigned to StringIO in tests).
            # This ensures we can reliably dup/reopen the streams.
            saved_stdout = STDOUT.dup
            saved_stderr = STDERR.dup

            STDOUT.reopen(stdout_writer)
            STDERR.reopen(stderr_writer)
            $stdout = STDOUT
            $stderr = STDERR

            # Run the groups
            result = run_groups_in_worker(groups)

            # Flush any buffered output before restoring
            $stdout.flush
            $stderr.flush

            # Restore stdout/stderr for Marshal
            # We must restore to original FDs because $stdout/$stderr might be
            # StringIO objects in test environments (not real IO objects)
            STDOUT.reopen(saved_stdout)
            STDERR.reopen(saved_stderr)
            $stdout = STDOUT
            $stderr = STDERR
            saved_stdout.close
            saved_stderr.close

            # Send result back to parent
            Marshal.dump(result, result_writer)
          rescue StandardError => e
            # Send error information back to parent
            error_result = {
              error: true,
              message: e.message,
              backtrace: e.backtrace,
              example_count: 0,
              passed_count: 0,
              failed_count: 0,
              pending_count: 0
            }
            Marshal.dump(error_result, result_writer)
          ensure
            result_writer.close
            stdout_writer.close
            stderr_writer.close
          end
          exit!(0)
        end

        result_writer.close
        stdout_writer.close
        stderr_writer.close

        # Read all streams concurrently to avoid deadlock
        result_data, stdout_output, stderr_output = read_worker_streams(
          result_reader, stdout_reader, stderr_reader
        )

        # Unmarshal the result
        result = Marshal.load(result_data)

        # Wait for worker to finish
        Process.wait(pid)

        # Replay worker output to main process
        $stdout.write(stdout_output) unless stdout_output.empty?
        $stderr.write(stderr_output) unless stderr_output.empty?

        # Check if worker encountered an error
        if result.is_a?(Hash) && result[:error]
          raise "Worker process failed: #{result[:message]}\n#{result[:backtrace]&.join("\n")}"
        end

        result
      end

      # Read from multiple IO streams concurrently using IO.select
      # @param result_reader [IO] pipe for reading marshaled result data
      # @param stdout_reader [IO] pipe for reading worker stdout
      # @param stderr_reader [IO] pipe for reading worker stderr
      # @return [Array<String>] tuple of [result_data, stdout_output, stderr_output]
      def read_worker_streams(result_reader, stdout_reader, stderr_reader)
        result_data = String.new
        stdout_output = String.new
        stderr_output = String.new

        # Use IO.select to read from multiple streams without blocking
        readers = [result_reader, stdout_reader, stderr_reader]
        until readers.empty?
          ready, = IO.select(readers)
          ready.each do |io|
            begin
              # Read in 4KB chunks - balances efficiency with responsiveness.
              # This size aligns with typical OS page size and is a standard
              # buffer size for pipe I/O operations.
              data = io.readpartial(4096)
              if io == result_reader
                result_data << data
              elsif io == stdout_reader
                stdout_output << data
              else
                stderr_output << data
              end
            rescue EOFError
              readers.delete(io)
              io.close
            end
          end
        end

        [result_data, stdout_output, stderr_output]
      end

      # Run groups within a worker process
      def run_groups_in_worker(groups)
        # Create a simple reporter to track results
        reporter = SimpleReporter.new(@configuration)

        groups.each do |group|
          group.run(reporter)
        end

        {
          example_count: reporter.examples.size,
          passed_count: reporter.passed_examples.size,
          failed_count: reporter.failed_examples.size,
          pending_count: reporter.pending_examples.size
        }
      end

      # Aggregate results from all workers
      def aggregate_results(worker_results)
        totals = worker_results.reduce(
          example_count: 0,
          passed_count: 0,
          failed_count: 0,
          pending_count: 0
        ) do |acc, result|
          {
            example_count: acc[:example_count] + result[:example_count],
            passed_count: acc[:passed_count] + result[:passed_count],
            failed_count: acc[:failed_count] + result[:failed_count],
            pending_count: acc[:pending_count] + result[:pending_count]
          }
        end

        Result.new(**totals)
      end

      # Simple reporter for collecting results within a worker
      class SimpleReporter
        attr_reader :examples, :passed_examples, :failed_examples, :pending_examples

        def initialize(configuration)
          @examples = []
          @passed_examples = []
          @failed_examples = []
          @pending_examples = []
          @configuration = configuration
        end

        def example_group_started(_group)
          # No-op: we don't track group-level events
        end

        def example_group_finished(_group)
          # No-op: we don't track group-level events
        end

        def example_started(example)
          @examples << example
        end

        def example_finished(_example)
          # No-op: we track pass/fail/pending separately
        end

        def example_passed(example)
          @passed_examples << example
        end

        def example_failed(example)
          @failed_examples << example
        end

        def example_pending(example)
          @pending_examples << example
        end

        def start(_expected_example_count)
          # No-op: minimal reporter doesn't need start hook
        end

        def stop
          # No-op: minimal reporter doesn't need stop hook
        end

        def message(_message)
          # No-op: minimal reporter doesn't output messages
        end

        def fail_fast_limit_met?
          return false unless (fail_fast = @configuration.fail_fast)

          if fail_fast == true
            @failed_examples.any?
          else
            fail_fast <= @failed_examples.size
          end
        end

        def report(expected_example_count)
          start(expected_example_count)
          yield self
          stop
        end
      end
    end
  end
end
