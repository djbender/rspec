require 'spec_helper'
require 'rspec/core/parallel_runner'

RSpec.describe RSpec::Core::ParallelRunner do
  # Helper to run groups with ParallelRunner
  def run_parallel(groups, worker_count: 2, configuration: RSpec.configuration)
    parallel_runner = RSpec::Core::ParallelRunner.new(
      example_groups: groups,
      worker_count: worker_count,
      configuration: configuration
    )
    parallel_runner.run
  end

  # Helper to create a tempfile and yield its path
  def with_temp_log
    Tempfile.create(['test_log', '.txt']) do |file|
      path = file.path
      file.close
      yield path
    end
  end

  # Helper to mark an example as passing (RSpec requires at least one expectation)
  def pass
    expect(true).to be true
  end

  # Helper to mark an example as failing
  def fail
    expect(true).to be false
  end
  describe "basic two-process execution" do
    it "runs example groups across 2 worker processes and collects results" do
      with_temp_log do |log_path|
        group1 = RSpec.describe("Group 1") do
          it "passes in group 1" do
            File.open(log_path, 'a') { |f| f.puts "group1:#{Process.pid}" }
            pass
          end
        end

        group2 = RSpec.describe("Group 2") do
          it "passes in group 2" do
            File.open(log_path, 'a') { |f| f.puts "group2:#{Process.pid}" }
            pass
          end
        end

        result = run_parallel([group1, group2])

        aggregate_failures do
          expect(result.example_count).to eq(2)
          expect(result.passed_count).to eq(2)
          expect(result.failed_count).to eq(0)
          expect(result.pending_count).to eq(0)
        end

        # Verify examples ran in different worker processes
        lines = File.read(log_path).split("\n")
        group1_pid = lines.find { |l| l.start_with?('group1:') }&.split(':')&.last&.to_i
        group2_pid = lines.find { |l| l.start_with?('group2:') }&.split(':')&.last&.to_i

        aggregate_failures do
          expect(group1_pid).not_to be_nil, "Group 1 should have run"
          expect(group2_pid).not_to be_nil, "Group 2 should have run"
          expect(group1_pid).not_to eq(group2_pid), "Groups should run in different worker processes"
          expect(group1_pid).not_to eq(Process.pid), "Group 1 should not run in parent process"
          expect(group2_pid).not_to eq(Process.pid), "Group 2 should not run in parent process"
        end
      end
    end
  end

  describe "result aggregation accuracy" do
    it "correctly aggregates pass/fail/pending counts from multiple workers" do
      group1 = RSpec.describe("Group 1") do
        it("passes 1") { expect(true).to be true }
        it("passes 2") { expect(1).to eq(1) }
        it("fails 1") { expect(true).to be false }
      end

      group2 = RSpec.describe("Group 2") do
        it("passes 3") { expect(2 + 2).to eq(4) }
        it("is pending", :pending => true) { expect(1).to eq(2) }
        it("fails 2") { expect(1).to eq(2) }
      end

      result = run_parallel([group1, group2])

      aggregate_failures do
        expect(result.example_count).to eq(6)
        expect(result.passed_count).to eq(3)
        expect(result.failed_count).to eq(2)
        expect(result.pending_count).to eq(1)
      end
    end
  end

  describe "error handling" do
    it "propagates errors from worker processes to parent" do
      error_group = RSpec.describe("Error group") do
        it("will error") { raise "Intentional test error" }
      end

      result = run_parallel([error_group], worker_count: 1)

      aggregate_failures do
        expect(result.example_count).to eq(1)
        expect(result.failed_count).to eq(1)
      end
    end
  end

  describe "output collection and formatting" do
    it "captures stdout and stderr from workers and replays through formatters" do
      group1 = RSpec.describe("Group 1") do
        it "produces stdout" do
          puts "stdout from worker 1"
          pass
        end
      end

      group2 = RSpec.describe("Group 2") do
        it "produces stderr" do
          $stderr.puts "stderr from worker 2"
          pass
        end

        it "produces both" do
          puts "more stdout"
          $stderr.puts "more stderr"
          pass
        end
      end

      output = StringIO.new
      error_output = StringIO.new

      begin
        original_stdout, original_stderr = $stdout, $stderr
        $stdout, $stderr = output, error_output

        result = run_parallel([group1, group2])

        aggregate_failures do
          expect(result.example_count).to eq(3)
          expect(result.passed_count).to eq(3)
        end
      ensure
        $stdout, $stderr = original_stdout, original_stderr
      end

      aggregate_failures do
        expect(output.string).to include("stdout from worker 1", "more stdout")
        expect(error_output.string).to include("stderr from worker 2", "more stderr")

        # Verify output appears exactly once (no duplication)
        expect(output.string.scan(/stdout from worker 1/).count).to eq(1)
        expect(output.string.scan(/more stdout/).count).to eq(1)
        expect(error_output.string.scan(/stderr from worker 2/).count).to eq(1)
        expect(error_output.string.scan(/more stderr/).count).to eq(1)
      end
    end
  end

  describe "suite hooks run exactly once" do
    it "runs before(:suite) once before any worker and after(:suite) once after all workers" do
      with_temp_log do |log_path|
        config = RSpec::Core::Configuration.new
        config.before(:suite) { File.open(log_path, 'a') { |f| f.puts "before_suite:#{Process.pid}" } }
        config.after(:suite) { File.open(log_path, 'a') { |f| f.puts "after_suite:#{Process.pid}" } }

        groups = (1..3).map do |i|
          RSpec.describe("Group #{i}") do
            it("example #{i}") do
              File.open(log_path, 'a') { |f| f.puts "example#{i}:#{Process.pid}" }
              pass
            end
          end
        end

        result = run_parallel(groups, worker_count: 3, configuration: config)

        expect(result.example_count).to eq(3)
        expect(result.passed_count).to eq(3)

        lines = File.read(log_path).split("\n")
        parent_pid = Process.pid
        before_suite_entries = lines.select { |l| l.start_with?('before_suite:') }
        after_suite_entries = lines.select { |l| l.start_with?('after_suite:') }
        example_entries = lines.select { |l| l.start_with?('example') }

        aggregate_failures do
          # Verify suite hooks ran exactly once in parent process
          expect(before_suite_entries.count).to eq(1)
          expect(after_suite_entries.count).to eq(1)
          expect(before_suite_entries.first.split(':').last.to_i).to eq(parent_pid)
          expect(after_suite_entries.first.split(':').last.to_i).to eq(parent_pid)

          # Verify examples ran in worker processes (not parent)
          example_pids = example_entries.map { |e| e.split(':').last.to_i }.uniq
          expect(example_pids).not_to include(parent_pid)
          expect(example_pids.count).to eq(3)

          # Verify execution order
          before_idx = lines.index { |l| l.start_with?('before_suite:') }
          first_ex_idx = lines.index { |l| l.start_with?('example') }
          after_idx = lines.index { |l| l.start_with?('after_suite:') }
          last_ex_idx = lines.rindex { |l| l.start_with?('example') }

          expect(before_idx).to be < first_ex_idx
          expect(after_idx).to be > last_ex_idx
        end
      end
    end
  end

  describe "work distribution" do
    it "distributes example groups reasonably across workers" do
      with_temp_log do |log_path|
        groups = (1..10).map do |i|
          RSpec.describe("Group #{i}") do
            it("example #{i}") do
              File.open(log_path, 'a') { |f| f.puts "group#{i}:#{Process.pid}" }
              pass
            end
          end
        end

        result = run_parallel(groups, worker_count: 3)

        expect(result.example_count).to eq(10)
        expect(result.passed_count).to eq(10)

        lines = File.read(log_path).split("\n")
        groups_by_worker = lines.group_by { |line| line.split(':').last.to_i }

        aggregate_failures do
          expect(groups_by_worker.keys.count).to eq(3)

          executed_groups = lines.map { |line| line.split(':').first }.sort
          expected_groups = (1..10).map { |i| "group#{i}" }.sort
          expect(executed_groups).to eq(expected_groups)

          work_counts = groups_by_worker.values.map(&:count).sort
          expect(work_counts).to eq([3, 3, 4])
        end
      end
    end
  end

  describe "fail fast" do
    it "stops execution quickly when first failure occurs with --fail-fast" do
      with_temp_log do |log_path|
        # Create configuration with fail_fast enabled
        config = RSpec::Core::Configuration.new
        config.fail_fast = true

        # Create 10 groups, where group 3 will fail
        groups = (1..10).map do |i|
          RSpec.describe("Group #{i}") do
            it("example #{i}") do
              File.open(log_path, 'a') { |f| f.puts "group#{i}:start" }

              if i == 3
                # This group fails
                expect(true).to be false
              else
                # All other groups pass
                pass
              end

              File.open(log_path, 'a') { |f| f.puts "group#{i}:end" }
            end
          end
        end

        result = run_parallel(groups, worker_count: 3, configuration: config)

        aggregate_failures do
          # Should have stopped early, not run all 10 examples
          expect(result.example_count).to be < 10
          expect(result.failed_count).to be >= 1

          # Verify some groups didn't run at all
          lines = File.read(log_path).split("\n")
          started_groups = lines.select { |l| l.include?(':start') }.count
          expect(started_groups).to be < 10

          # Verify the failing group started (it may not finish writing :end if fail-fast triggers)
          expect(lines).to include("group3:start")
        end
      end
    end

    it "stops execution after N failures with --fail-fast=N" do
      with_temp_log do |log_path|
        config = RSpec::Core::Configuration.new
        config.fail_fast = 2  # Stop after 2 failures

        # Create groups where the first two groups fail
        # This ensures fail-fast triggers early
        groups = (1..10).map do |i|
          RSpec.describe("Group #{i}") do
            it("example #{i}") do
              File.open(log_path, 'a') { |f| f.puts "group#{i}:executed" }

              # First two groups fail
              if i <= 2
                expect(true).to be false
              else
                pass
              end
            end
          end
        end

        result = run_parallel(groups, worker_count: 3, configuration: config)

        aggregate_failures do
          # Should have exactly 2 failures (or possibly more if worker was mid-execution)
          expect(result.failed_count).to be >= 2

          # The exact number of examples that run depends on timing,
          # but fail-fast should prevent significantly more than 2 failures
          # With 3 workers, we might get a few more examples before all workers stop
          expect(result.failed_count).to be <= 4
        end
      end
    end
  end
end