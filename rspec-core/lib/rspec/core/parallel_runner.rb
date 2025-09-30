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
      def run_worker(groups, _worker_index)
        # Create pipe for IPC
        reader, writer = IO.pipe

        pid = fork do
          reader.close

          begin
            # Run the groups
            result = run_groups_in_worker(groups)

            # Send result back to parent
            Marshal.dump(result, writer)
          ensure
            writer.close
          end
          exit!(0)
        end

        writer.close

        begin
          # Read result from worker
          result = Marshal.load(reader)
        ensure
          reader.close
        end

        # Wait for worker to finish
        Process.wait(pid)

        result
      end

      # Run groups within a worker process
      def run_groups_in_worker(groups)
        # Create a simple reporter to track results
        reporter = SimpleReporter.new

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

        def initialize(configuration = RSpec.configuration)
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