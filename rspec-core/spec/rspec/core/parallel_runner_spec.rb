require 'spec_helper'
require 'rspec/core/parallel_runner'

RSpec.describe RSpec::Core::ParallelRunner do
  describe "basic two-process execution" do
    it "runs example groups across 2 worker processes and collects results" do
      results_path = nil

      Tempfile.create(['parallel_test', '.txt']) do |results_file|
        results_path = results_file.path
        results_file.close

        # Create 2 simple example groups
        group1 = RSpec.describe("Group 1") do
          it "passes in group 1" do
            File.open(results_path, 'a') { |f| f.puts "group1:#{Process.pid}" }
            expect(1 + 1).to eq(2)
          end
        end

        group2 = RSpec.describe("Group 2") do
          it "passes in group 2" do
            File.open(results_path, 'a') { |f| f.puts "group2:#{Process.pid}" }
            expect(2 + 2).to eq(4)
          end
        end

        # Run with parallel runner using 2 workers
        parallel_runner = RSpec::Core::ParallelRunner.new(
          example_groups: [group1, group2],
          worker_count: 2,
          configuration: RSpec.configuration
        )

        result = parallel_runner.run

        # Verify results
        expect(result.example_count).to eq(2)
        expect(result.passed_count).to eq(2)
        expect(result.failed_count).to eq(0)
        expect(result.pending_count).to eq(0)

        # Verify examples ran in different processes
        results_content = File.read(results_path)
        lines = results_content.split("\n")

        group1_pid = lines.find { |l| l.start_with?('group1:') }&.split(':')&.last&.to_i
        group2_pid = lines.find { |l| l.start_with?('group2:') }&.split(':')&.last&.to_i

        expect(group1_pid).not_to be_nil, "Group 1 should have run"
        expect(group2_pid).not_to be_nil, "Group 2 should have run"
        expect(group1_pid).not_to eq(group2_pid), "Groups should run in different worker processes"

        # Verify parent process didn't run examples
        expect(group1_pid).not_to eq(Process.pid), "Group 1 should not run in parent process"
        expect(group2_pid).not_to eq(Process.pid), "Group 2 should not run in parent process"
      end
    end
  end

  describe "result aggregation accuracy" do
    it "correctly aggregates pass/fail/pending counts from multiple workers" do
      # Worker 1: 2 passing, 1 failing
      group1 = RSpec.describe("Group 1") do
        it("passes 1") { expect(true).to be true }
        it("passes 2") { expect(1).to eq(1) }
        it("fails 1") { expect(true).to be false }
      end

      # Worker 2: 1 passing, 1 pending, 1 failing
      group2 = RSpec.describe("Group 2") do
        it("passes 3") { expect(2 + 2).to eq(4) }
        it("is pending", :pending => true) { expect(1).to eq(2) }
        it("fails 2") { expect(1).to eq(2) }
      end

      # Run with 2 workers
      parallel_runner = RSpec::Core::ParallelRunner.new(
        example_groups: [group1, group2],
        worker_count: 2,
        configuration: RSpec.configuration
      )

      result = parallel_runner.run

      # Verify final counts: 3 passed, 2 failed, 1 pending
      expect(result.example_count).to eq(6)
      expect(result.passed_count).to eq(3)
      expect(result.failed_count).to eq(2)
      expect(result.pending_count).to eq(1)
    end
  end

  describe "error handling" do
    it "propagates errors from worker processes to parent" do
      # Create a group that will raise an error during execution
      error_group = RSpec.describe("Error group") do
        it("will error") { raise "Intentional test error" }
      end

      parallel_runner = RSpec::Core::ParallelRunner.new(
        example_groups: [error_group],
        worker_count: 1,
        configuration: RSpec.configuration
      )

      # The worker handles the error and reports it as a failed example
      # (not a worker process error)
      result = parallel_runner.run

      # The error is captured as a failed example, not a worker crash
      aggregate_failures do
        expect(result.example_count).to eq(1)
        expect(result.failed_count).to eq(1)
      end
    end
  end

  describe "output collection and formatting" do
    it "captures stdout and stderr from workers and replays through formatters" do
      # Create groups that produce stdout and stderr output
      group1 = RSpec.describe("Group 1") do
        it "produces stdout" do
          puts "stdout from worker 1"
          expect(true).to be true
        end
      end

      group2 = RSpec.describe("Group 2") do
        it "produces stderr" do
          $stderr.puts "stderr from worker 2"
          expect(true).to be true
        end

        it "produces both" do
          puts "more stdout"
          $stderr.puts "more stderr"
          expect(true).to be true
        end
      end

      # Capture all output from the parallel runner
      output = StringIO.new
      error_output = StringIO.new

      original_stdout = $stdout
      original_stderr = $stderr

      begin
        $stdout = output
        $stderr = error_output

        parallel_runner = RSpec::Core::ParallelRunner.new(
          example_groups: [group1, group2],
          worker_count: 2,
          configuration: RSpec.configuration
        )

        result = parallel_runner.run

        aggregate_failures do
          expect(result.example_count).to eq(3)
          expect(result.passed_count).to eq(3)
        end
      ensure
        $stdout = original_stdout
        $stderr = original_stderr
      end

      # Verify all output was captured and replayed
      output_str = output.string
      error_str = error_output.string

      aggregate_failures do
        expect(output_str).to include("stdout from worker 1")
        expect(output_str).to include("more stdout")
        expect(error_str).to include("stderr from worker 2")
        expect(error_str).to include("more stderr")

        # Verify output appears exactly once (no duplication)
        expect(output_str.scan(/stdout from worker 1/).count).to eq(1)
        expect(output_str.scan(/more stdout/).count).to eq(1)
        expect(error_str.scan(/stderr from worker 2/).count).to eq(1)
        expect(error_str.scan(/more stderr/).count).to eq(1)
      end
    end
  end

  describe "suite hooks run exactly once" do
    it "runs before(:suite) once before any worker and after(:suite) once after all workers" do
      hook_log_path = nil

      Tempfile.create(['hook_log', '.txt']) do |hook_log_file|
        hook_log_path = hook_log_file.path
        hook_log_file.close

        # Create a custom configuration with suite hooks
        config = RSpec::Core::Configuration.new
        config.before(:suite) do
          File.open(hook_log_path, 'a') { |f| f.puts "before_suite:#{Process.pid}" }
        end
        config.after(:suite) do
          File.open(hook_log_path, 'a') { |f| f.puts "after_suite:#{Process.pid}" }
        end

        # Create 3 example groups to run across 3 workers
        group1 = RSpec.describe("Group 1") do
          it("example 1") do
            File.open(hook_log_path, 'a') { |f| f.puts "example1:#{Process.pid}" }
            expect(true).to be true
          end
        end

        group2 = RSpec.describe("Group 2") do
          it("example 2") do
            File.open(hook_log_path, 'a') { |f| f.puts "example2:#{Process.pid}" }
            expect(true).to be true
          end
        end

        group3 = RSpec.describe("Group 3") do
          it("example 3") do
            File.open(hook_log_path, 'a') { |f| f.puts "example3:#{Process.pid}" }
            expect(true).to be true
          end
        end

        # Run with 3 workers
        parallel_runner = RSpec::Core::ParallelRunner.new(
          example_groups: [group1, group2, group3],
          worker_count: 3,
          configuration: config
        )

        result = parallel_runner.run

        # Verify examples ran successfully
        aggregate_failures do
          expect(result.example_count).to eq(3)
          expect(result.passed_count).to eq(3)
        end

        # Parse the hook log
        log_content = File.read(hook_log_path)
        log_lines = log_content.split("\n")

        # Extract PIDs
        parent_pid = Process.pid
        before_suite_entries = log_lines.select { |l| l.start_with?('before_suite:') }
        after_suite_entries = log_lines.select { |l| l.start_with?('after_suite:') }
        example_entries = log_lines.select { |l| l.start_with?('example') }

        aggregate_failures do
          # Verify suite hooks ran exactly once
          expect(before_suite_entries.count).to eq(1), "before(:suite) should run exactly once"
          expect(after_suite_entries.count).to eq(1), "after(:suite) should run exactly once"

          # Verify suite hooks ran in parent process
          before_suite_pid = before_suite_entries.first.split(':').last.to_i
          after_suite_pid = after_suite_entries.first.split(':').last.to_i
          expect(before_suite_pid).to eq(parent_pid), "before(:suite) should run in parent process"
          expect(after_suite_pid).to eq(parent_pid), "after(:suite) should run in parent process"

          # Verify examples ran in worker processes (not parent)
          example_pids = example_entries.map { |e| e.split(':').last.to_i }.uniq
          expect(example_pids).not_to include(parent_pid), "Examples should not run in parent process"
          expect(example_pids.count).to eq(3), "Examples should run across 3 different worker processes"

          # Verify execution order: before_suite appears before any example
          before_suite_index = log_lines.index { |l| l.start_with?('before_suite:') }
          first_example_index = log_lines.index { |l| l.start_with?('example') }
          expect(before_suite_index).to be < first_example_index, "before(:suite) should run before any example"

          # Verify execution order: after_suite appears after all examples
          after_suite_index = log_lines.index { |l| l.start_with?('after_suite:') }
          last_example_index = log_lines.rindex { |l| l.start_with?('example') }
          expect(after_suite_index).to be > last_example_index, "after(:suite) should run after all examples"
        end
      end
    end
  end
end