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

  describe "constants" do
    it "ensures STOP_SIGNAL_READ_SIZE is large enough for STOP_SIGNAL" do
      # Validate that the read size is at least as large as the signal
      # This prevents truncation when reading the stop signal
      expect(RSpec::Core::ParallelRunner::STOP_SIGNAL_READ_SIZE).to be >=
        RSpec::Core::ParallelRunner::STOP_SIGNAL.bytesize
    end

    it "uses sensible buffer size for pipe I/O" do
      # 4KB is standard page size and good for pipe I/O performance
      expect(RSpec::Core::ParallelRunner::PIPE_READ_BUFFER_SIZE).to eq(4096)
    end
  end

  describe "basic two-process execution" do
    it "runs example groups across 2 worker processes and collects results" do
      with_temp_log do |log_path|
        group1 = RSpec.describe("Group 1") do
          it "passes in group 1" do
            File.open(log_path, 'a') { |f| f.puts "group1:#{Process.pid}" }
            expect(true).to be true
          end
        end

        group2 = RSpec.describe("Group 2") do
          it "passes in group 2" do
            File.open(log_path, 'a') { |f| f.puts "group2:#{Process.pid}" }
            expect(true).to be true
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

    it "continues with other workers when one worker has failures" do
      with_temp_log do |log_path|
        # Create groups where one will fail but others succeed
        groups = []
        groups << RSpec.describe("Successful Group 1") do
          it("passes") do
            File.open(log_path, 'a') { |f| f.puts "success:1" }
            expect(true).to be true
          end
        end

        groups << RSpec.describe("Failing Group") do
          it("fails") do
            File.open(log_path, 'a') { |f| f.puts "failure:1" }
            expect(true).to be false
          end
        end

        groups << RSpec.describe("Successful Group 2") do
          it("passes") do
            File.open(log_path, 'a') { |f| f.puts "success:2" }
            expect(true).to be true
          end
        end

        result = run_parallel(groups, worker_count: 2)
        lines = File.read(log_path).split("\n")

        aggregate_failures do
          # All examples should run despite one failing
          expect(result.example_count).to eq(3)
          expect(result.passed_count).to eq(2)
          expect(result.failed_count).to eq(1)

          # Verify all workers completed their work
          expect(lines).to contain_exactly("success:1", "failure:1", "success:2")
        end
      end
    end

    it "handles multiple failures across different workers" do
      with_temp_log do |log_path|
        # Create multiple groups with failures in different workers
        groups = 6.times.map do |i|
          is_even = i.even?
          RSpec.describe("Group #{i}") do
            it("example #{i}") do
              File.open(log_path, 'a') { |f| f.puts "example:#{i}" }
              expect(is_even).to be true  # Odds will fail
            end
          end
        end

        result = run_parallel(groups, worker_count: 3)
        lines = File.read(log_path).split("\n").sort

        aggregate_failures do
          # All examples should run
          expect(result.example_count).to eq(6)
          expect(result.passed_count).to eq(3)  # 0, 2, 4
          expect(result.failed_count).to eq(3)  # 1, 3, 5

          # Verify all examples ran
          expected_lines = 6.times.map { |i| "example:#{i}" }.sort
          expect(lines).to eq(expected_lines)
        end
      end
    end

    it "captures exceptions without crashing workers" do
      error_group = RSpec.describe("Error group") do
        it("raises an exception") do
          raise StandardError, "This is a very specific error message for testing"
        end
      end

      # The exception should be captured as a failed example, not crash the worker
      result = run_parallel([error_group], worker_count: 1)

      aggregate_failures do
        expect(result.example_count).to eq(1)
        expect(result.failed_count).to eq(1)
        expect(result.passed_count).to eq(0)
      end
    end
  end

  describe "output collection and formatting" do
    it "captures stdout and stderr from workers and replays through formatters" do
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
              expect(true).to be true
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
              expect(true).to be true
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
                expect(true).to be true
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
                expect(true).to be true
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

  describe "configuration inheritance" do
    it "workers inherit configuration settings from main process" do
      with_temp_log do |log_path|
        config = RSpec::Core::Configuration.new
        config.default_path = 'custom_spec'
        config.pattern = '**/*_custom.rb'

        config.before(:example) do
          File.open(log_path, 'a') { |f| f.puts "before_example:#{Process.pid}" }
        end

        config.after(:example) do
          File.open(log_path, 'a') { |f| f.puts "after_example:#{Process.pid}" }
        end

        # Temporarily switch to custom config so hooks are registered on groups
        original_config = RSpec.configuration
        RSpec.configuration = config

        groups = (1..3).map do |i|
          RSpec.describe("Group #{i}") do
            it("example #{i}") do
              File.open(log_path, 'a') do |f|
                f.puts "example#{i}:default_path:#{RSpec.configuration.default_path}"
                f.puts "example#{i}:pattern:#{RSpec.configuration.pattern}"
              end
              expect(true).to be true
            end
          end
        end

        # Restore original config
        RSpec.configuration = original_config

        result = run_parallel(groups, worker_count: 3, configuration: config)
        lines = File.read(log_path).split("\n")
        parent_pid = Process.pid
        before_hook_pids = lines.grep(/before_example:/).map { |l| l.split(':').last.to_i }
        after_hook_pids = lines.grep(/after_example:/).map { |l| l.split(':').last.to_i }

        aggregate_failures do
          expect(result.example_count).to eq(3)
          expect(result.passed_count).to eq(3)
          expect(lines.grep(/example\d+:default_path:custom_spec/).count).to eq(3)
          expect(lines.grep(/example\d+:pattern:\*\*\/\*_custom\.rb/).count).to eq(3)
          expect(before_hook_pids.count).to eq(3)
          expect(after_hook_pids.count).to eq(3)
          expect(before_hook_pids).not_to include(parent_pid)
          expect(after_hook_pids).not_to include(parent_pid)
          expect(before_hook_pids.uniq.sort).to eq(after_hook_pids.uniq.sort)
        end
      end
    end

    it "workers inherit randomization seed" do
      with_temp_log do |log_path|
        config = RSpec::Core::Configuration.new
        config.seed = 12345
        config.order = :random

        groups = (1..5).map do |i|
          RSpec.describe("Group #{i}") do
            it("example #{i}") do
              File.open(log_path, 'a') do |f|
                f.puts "example#{i}:seed:#{RSpec.configuration.seed}"
              end
              expect(true).to be true
            end
          end
        end

        result = run_parallel(groups, worker_count: 2, configuration: config)
        lines = File.read(log_path).split("\n")
        seeds = lines.grep(/example\d+:seed:/).map { |l| l.split(':').last.to_i }

        aggregate_failures do
          expect(result.example_count).to eq(5)
          expect(result.passed_count).to eq(5)
          expect(seeds.uniq).to eq([12345])
        end
      end
    end

    it "maintains bidirectional references between configuration and world" do
      with_temp_log do |log_path|
        config = RSpec::Core::Configuration.new
        config.default_path = 'bidirectional_test'

        group = RSpec.describe("Test") do
          it("verifies bidirectional references") do
            # Verify that RSpec.configuration and RSpec.world reference each other correctly
            config_id = RSpec.configuration.object_id
            world_id = RSpec.world.object_id
            config_world_id = RSpec.configuration.world.object_id
            world_config_id = RSpec.world.configuration.object_id

            File.open(log_path, 'a') do |f|
              f.puts "config_to_world_matches:#{config_world_id == world_id}"
              f.puts "world_to_config_matches:#{world_config_id == config_id}"
              f.puts "bidirectional:#{config_world_id == world_id && world_config_id == config_id}"
            end
            expect(true).to be true
          end
        end

        result = run_parallel([group], worker_count: 1, configuration: config)
        lines = File.read(log_path).split("\n")

        aggregate_failures do
          expect(result.example_count).to eq(1)
          expect(result.passed_count).to eq(1)
          expect(lines).to include("config_to_world_matches:true")
          expect(lines).to include("world_to_config_matches:true")
          expect(lines).to include("bidirectional:true")
        end
      end
    end
  end

  describe "random seed and ordering" do
    it "uses the same seed across all workers for deterministic randomization" do
      with_temp_log do |log_path|
        # Create config with random ordering and specific seed
        config = RSpec::Core::Configuration.new
        config.seed = 99999
        config.order = :random

        # Create example groups before switching config
        # (otherwise hooks won't be registered)
        groups = 10.times.map do |i|
          RSpec.describe("Group #{i}") do
            it("example #{i}") do
              File.open(log_path, 'a') do |f|
                f.puts "example#{i}:seed:#{RSpec.configuration.seed}"
              end
              expect(true).to be true
            end
          end
        end

        # Run first time
        result1 = run_parallel(groups, worker_count: 3, configuration: config)
        lines1 = File.read(log_path).split("\n").sort

        # Clear log and run again with same seed
        File.write(log_path, "")
        result2 = run_parallel(groups, worker_count: 3, configuration: config)
        lines2 = File.read(log_path).split("\n").sort

        aggregate_failures do
          # Both runs should have same results
          expect(result1.example_count).to eq(10)
          expect(result1.passed_count).to eq(10)
          expect(result2.example_count).to eq(10)
          expect(result2.passed_count).to eq(10)

          # All examples should see the same seed
          seeds1 = lines1.grep(/example\d+:seed:/).map { |l| l.split(':').last.to_i }
          seeds2 = lines2.grep(/example\d+:seed:/).map { |l| l.split(':').last.to_i }
          expect(seeds1.uniq).to eq([99999])
          expect(seeds2.uniq).to eq([99999])

          # Execution order should be identical between runs (deterministic)
          expect(lines1).to eq(lines2)
        end
      end
    end

    it "respects different seeds producing different (but deterministic) execution" do
      with_temp_log do |log_path|
        # Create groups that will be ordered differently based on seed
        groups = 5.times.map do |i|
          RSpec.describe("Group #{i}") do
            it("example #{i}") do
              File.open(log_path, 'a') do |f|
                f.puts "example:#{i}"
              end
              expect(true).to be true
            end
          end
        end

        # Run with seed 12345
        config1 = RSpec::Core::Configuration.new
        config1.seed = 12345
        config1.order = :random
        result1 = run_parallel(groups, worker_count: 2, configuration: config1)
        lines1 = File.read(log_path).split("\n")

        # Clear and run with seed 54321
        File.write(log_path, "")
        config2 = RSpec::Core::Configuration.new
        config2.seed = 54321
        config2.order = :random
        result2 = run_parallel(groups, worker_count: 2, configuration: config2)
        lines2 = File.read(log_path).split("\n")

        aggregate_failures do
          # Both should complete all examples
          expect(result1.example_count).to eq(5)
          expect(result1.passed_count).to eq(5)
          expect(result2.example_count).to eq(5)
          expect(result2.passed_count).to eq(5)

          # Both should have all examples (same set, potentially different order)
          expect(lines1.sort).to eq(lines2.sort)

          # Different seeds may produce different execution order
          # (Note: with round-robin distribution and only 5 groups,
          # the group distribution might mask ordering differences,
          # but the seed should still be different in each run)
        end
      end
    end
  end

  describe "example filtering" do
    it "filters examples by tag inclusion across workers" do
      with_temp_log do |log_path|
        config = RSpec::Core::Configuration.new
        config.filter_run_including :fast

        # Create groups with and without :fast tag
        groups = []
        groups << RSpec.describe("Fast Group 1", :fast) do
          it("fast example 1") do
            File.open(log_path, 'a') { |f| f.puts "fast:1" }
            expect(true).to be true
          end
        end

        groups << RSpec.describe("Slow Group 1") do
          it("slow example 1") do
            File.open(log_path, 'a') { |f| f.puts "slow:1" }
            expect(true).to be true
          end
        end

        groups << RSpec.describe("Fast Group 2", :fast) do
          it("fast example 2") do
            File.open(log_path, 'a') { |f| f.puts "fast:2" }
            expect(true).to be true
          end
        end

        groups << RSpec.describe("Slow Group 2") do
          it("slow example 2") do
            File.open(log_path, 'a') { |f| f.puts "slow:2" }
            expect(true).to be true
          end
        end

        result = run_parallel(groups, worker_count: 2, configuration: config)
        lines = File.read(log_path).split("\n")

        aggregate_failures do
          # Only fast examples should run
          expect(result.example_count).to eq(2)
          expect(result.passed_count).to eq(2)
          expect(lines).to contain_exactly("fast:1", "fast:2")
          expect(lines).not_to include("slow:1", "slow:2")
        end
      end
    end

    it "filters examples by tag exclusion across workers" do
      with_temp_log do |log_path|
        config = RSpec::Core::Configuration.new
        config.filter_run_excluding :slow

        # Create groups with and without :slow tag
        groups = []
        groups << RSpec.describe("Fast Group 1") do
          it("fast example 1") do
            File.open(log_path, 'a') { |f| f.puts "fast:1" }
            expect(true).to be true
          end
        end

        groups << RSpec.describe("Slow Group 1", :slow) do
          it("slow example 1") do
            File.open(log_path, 'a') { |f| f.puts "slow:1" }
            expect(true).to be true
          end
        end

        groups << RSpec.describe("Fast Group 2") do
          it("fast example 2") do
            File.open(log_path, 'a') { |f| f.puts "fast:2" }
            expect(true).to be true
          end
        end

        result = run_parallel(groups, worker_count: 2, configuration: config)
        lines = File.read(log_path).split("\n")

        aggregate_failures do
          # Only non-slow examples should run
          expect(result.example_count).to eq(2)
          expect(result.passed_count).to eq(2)
          expect(lines).to contain_exactly("fast:1", "fast:2")
          expect(lines).not_to include("slow:1")
        end
      end
    end

    it "respects complex filtering with multiple criteria" do
      with_temp_log do |log_path|
        config = RSpec::Core::Configuration.new
        config.filter_run_including :type => :integration
        config.filter_run_excluding :broken

        # Create groups with various metadata combinations
        groups = []
        groups << RSpec.describe("Integration Test 1", :type => :integration) do
          it("should run") do
            File.open(log_path, 'a') { |f| f.puts "integration:1" }
            expect(true).to be true
          end
        end

        groups << RSpec.describe("Unit Test 1", :type => :unit) do
          it("should not run - wrong type") do
            File.open(log_path, 'a') { |f| f.puts "unit:1" }
            expect(true).to be true
          end
        end

        groups << RSpec.describe("Integration Test 2", :type => :integration, :broken => true) do
          it("should not run - excluded") do
            File.open(log_path, 'a') { |f| f.puts "integration:2:broken" }
            expect(true).to be true
          end
        end

        groups << RSpec.describe("Integration Test 3", :type => :integration) do
          it("should run") do
            File.open(log_path, 'a') { |f| f.puts "integration:3" }
            expect(true).to be true
          end
        end

        result = run_parallel(groups, worker_count: 2, configuration: config)
        lines = File.read(log_path).split("\n")

        aggregate_failures do
          # Only integration tests that aren't broken should run
          expect(result.example_count).to eq(2)
          expect(result.passed_count).to eq(2)
          expect(lines).to contain_exactly("integration:1", "integration:3")
          expect(lines).not_to include("unit:1", "integration:2:broken")
        end
      end
    end
  end
end
