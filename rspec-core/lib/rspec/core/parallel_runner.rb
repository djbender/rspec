RSpec::Support.require_rspec_core 'parallel/example_serializer'

module RSpec
  module Core
    # Runs example groups in parallel across multiple worker processes.
    # This provides significant performance improvements for large test suites
    # by utilizing multiple CPU cores.
    #
    # @private
    class ParallelRunner
      # Buffer size for reading from pipes (4KB)
      # This aligns with typical OS page size and is standard for pipe I/O
      PIPE_READ_BUFFER_SIZE = 4096

      # Signal sent to workers to stop execution (for fail-fast)
      STOP_SIGNAL = "STOP"

      # Number of bytes to read when checking for stop signal
      STOP_SIGNAL_READ_SIZE = 4

      # Exit code for successful worker completion
      WORKER_SUCCESS_EXIT_CODE = 0

      # Timeout for non-blocking stop signal check (0 = immediate return)
      STOP_CHECK_TIMEOUT = 0

      # Result object returned from parallel execution
      class Result
        attr_reader :example_count, :passed_count, :failed_count, :pending_count, :worker_results

        def initialize(example_count:, passed_count:, failed_count:, pending_count:, worker_results: [])
          @example_count = example_count
          @passed_count = passed_count
          @failed_count = failed_count
          @pending_count = pending_count
          @worker_results = worker_results
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
        # Save the current working directory before forking
        # Workers will restore to this directory to avoid issues if tests change directories
        @original_working_directory = Dir.pwd

        # Run suite hooks in main process, wrapping worker execution
        @configuration.with_suite_hooks do
          # Divide groups among workers
          groups_per_worker = distribute_groups

          # Create pipe for stop signal (used for fail-fast)
          stop_reader, stop_writer = IO.pipe

          # Fork worker processes and collect results
          # We need to collect workers and wait for them concurrently to support fail-fast
          workers = groups_per_worker.map.with_index do |groups, index|
            fork_worker(groups, index, stop_reader)
          end

          # Close the reader in parent (only workers read from it)
          stop_reader.close

          # Collect results from workers, monitoring for fail-fast condition
          worker_results = collect_worker_results(workers, stop_writer)

          # Close the stop writer
          stop_writer.close

          # Aggregate results
          aggregate_results(worker_results)
        end
      end

      # Replay example notifications to the reporter
      # This allows formatters to receive notifications about examples that ran in workers
      # @param worker_results [Array<Hash>] results from all workers
      # @param reporter [RSpec::Core::Reporter] the main process reporter
      def replay_notifications(worker_results, reporter)
        # Iterate through each worker's results in order
        worker_results.each do |result|
          next unless result[:examples]

          # Replay each example's notifications
          result[:examples].each do |serialized_example|
            # Create a stub object that quacks like an Example
            example_stub = Parallel::ExampleStub.new(serialized_example)

            # Send the same notifications that would have been sent during normal execution
            reporter.example_started(example_stub)

            # Send status-specific notification
            case example_stub.execution_result.status
            when :passed
              reporter.example_passed(example_stub)
            when :failed
              reporter.example_failed(example_stub)
            when :pending
              reporter.example_pending(example_stub)
            end

            reporter.example_finished(example_stub)
          end
        end
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

      # Fork a worker process to run groups
      # @param groups [Array<ExampleGroup>] groups to run in this worker
      # @param _worker_index [Integer] worker index (reserved for future use in logging/debugging)
      # @param stop_reader [IO] pipe to check for stop signal
      # @return [Hash] worker information (pid, pipes)
      def fork_worker(groups, _worker_index, stop_reader)
        # Create pipes for IPC and output capture
        result_reader, result_writer = IO.pipe
        stdout_reader, stdout_writer = IO.pipe
        stderr_reader, stderr_writer = IO.pipe

        pid = fork do
          result_reader.close
          stdout_reader.close
          stderr_reader.close

          begin
            # Restore to the original working directory
            # This prevents "No such file or directory - getcwd" errors that can occur
            # when tests change directories and those directories get deleted
            if @original_working_directory
              begin
                Dir.chdir(@original_working_directory)
              rescue Errno::ENOENT
                # If even the original directory was deleted, chdir to a safe fallback
                require 'tmpdir' # Lazy-load only when needed
                Dir.chdir(Dir.tmpdir)
              end
            end

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

            # Run the groups with stop signal checking
            result = run_groups_in_worker(groups, stop_reader)

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
            stop_reader.close
          end
          exit!(WORKER_SUCCESS_EXIT_CODE)
        end

        result_writer.close
        stdout_writer.close
        stderr_writer.close

        # Return worker info for later collection
        {
          pid: pid,
          result_reader: result_reader,
          stdout_reader: stdout_reader,
          stderr_reader: stderr_reader
        }
      end

      # Collect results from all workers, monitoring for fail-fast
      # @param workers [Array<Hash>] worker information from fork_worker
      # @param stop_writer [IO] pipe to signal workers to stop
      # @return [Array<Hash>] results from all workers
      def collect_worker_results(workers, stop_writer)
        results = []
        total_failures = 0
        fail_fast_triggered = false

        workers.each do |worker|
          # Read all streams concurrently to avoid deadlock
          result_data, stdout_output, stderr_output = read_worker_streams(
            worker[:result_reader], worker[:stdout_reader], worker[:stderr_reader]
          )

          # Unmarshal the result
          result = Marshal.load(result_data)

          # Wait for worker to finish
          Process.wait(worker[:pid])

          # Replay worker output to main process
          $stdout.write(stdout_output) unless stdout_output.empty?
          $stderr.write(stderr_output) unless stderr_output.empty?

          # Check if worker encountered an error
          if result.is_a?(Hash) && result[:error]
            raise "Worker process failed: #{result[:message]}\n#{result[:backtrace]&.join("\n")}"
          end

          results << result

          # Check fail-fast condition
          total_failures += result[:failed_count]
          if should_stop_for_fail_fast?(total_failures) && !fail_fast_triggered
            fail_fast_triggered = true
            # Signal remaining workers to stop
            begin
              stop_writer.write(STOP_SIGNAL)
              stop_writer.flush
            rescue Errno::EPIPE
              # Pipe already closed (all workers finished), ignore
            end
          end
        end

        results
      end

      # Check if we should trigger fail-fast
      # @param failure_count [Integer] total failures so far
      # @return [Boolean] true if fail-fast limit is met
      def should_stop_for_fail_fast?(failure_count)
        return false unless (fail_fast = @configuration.fail_fast)

        if fail_fast == true
          failure_count >= 1
        else
          failure_count >= fail_fast
        end
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
              data = io.readpartial(PIPE_READ_BUFFER_SIZE)
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
      # @param groups [Array<ExampleGroup>] groups to run
      # @param stop_reader [IO] pipe to check for stop signal
      def run_groups_in_worker(groups, stop_reader)
        # Set the global configuration to the one passed from parent
        # This ensures workers use the same configuration as the main process
        RSpec.configuration = @configuration
        RSpec.world.configuration = @configuration
        @configuration.world = RSpec.world

        # CRITICAL: Workers must run sequentially to avoid fork bomb
        # Set parallel_workers to nil to prevent workers from forking more workers
        @configuration.parallel_workers = nil
        # Mark that we're running inside a parallel worker
        @configuration.in_parallel_worker = true

        # Create a simple reporter to track results
        reporter = SimpleReporter.new(@configuration)

        groups.each do |group|
          # Check if we should stop (non-blocking check)
          if should_stop?(stop_reader)
            break
          end

          group.run(reporter)

          # Check fail-fast after each group
          if reporter.fail_fast_limit_met?
            break
          end
        end

        # Serialize all examples for transmission to main process
        serialized_examples = reporter.examples.map do |example|
          Parallel::ExampleSerializer.serialize_example(example)
        end

        {
          examples: serialized_examples,
          example_count: reporter.examples.size,
          passed_count: reporter.passed_examples.size,
          failed_count: reporter.failed_examples.size,
          pending_count: reporter.pending_examples.size
        }
      end

      # Check if parent has signaled to stop (non-blocking)
      # @param stop_reader [IO] pipe to check for stop signal
      # @return [Boolean] true if stop signal received
      def should_stop?(stop_reader)
        # Use IO.select with timeout for non-blocking check
        ready, = IO.select([stop_reader], nil, nil, STOP_CHECK_TIMEOUT)
        if ready
          begin
            # Try to read the stop signal
            stop_reader.read_nonblock(STOP_SIGNAL_READ_SIZE)
            return true
          rescue IO::WaitReadable, EOFError
            # No data available or pipe closed
            return false
          end
        end
        false
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

        Result.new(**totals, worker_results: worker_results)
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
