require 'support/aruba_support'

RSpec.describe 'Parallel execution with --parallel flag', :slow do
  include_context "aruba support"

  before(:all) { setup_aruba }

  before :all do
    # Create spec files with multiple examples to test parallel distribution
    write_file_formatted 'spec/group_1_spec.rb', "
      RSpec.describe 'Group 1' do
        it 'example 1' do
          expect(1).to eq(1)
        end

        it 'example 2' do
          expect(2).to eq(2)
        end

        it 'example 3' do
          expect(3).to eq(3)
        end
      end
    "

    write_file_formatted 'spec/group_2_spec.rb', "
      RSpec.describe 'Group 2' do
        it 'example 1' do
          expect('a').to eq('a')
        end

        it 'example 2' do
          expect('b').to eq('b')
        end
      end
    "

    write_file_formatted 'spec/group_3_spec.rb', "
      RSpec.describe 'Group 3' do
        it 'example 1' do
          expect(true).to be true
        end
      end
    "
  end

  after(:all) do
    remove 'spec/group_1_spec.rb'
    remove 'spec/group_2_spec.rb'
    remove 'spec/group_3_spec.rb'
  end

  describe 'basic parallel execution' do
    it 'runs all examples successfully with --parallel flag' do
      run_command 'spec --parallel=2'

      expect(last_cmd_stdout).to include('6 examples, 0 failures')
      expect(last_cmd_exit_status).to eq(0)
    end

    it 'runs successfully with --parallel and no count specified' do
      run_command 'spec --parallel'

      expect(last_cmd_stdout).to include('6 examples, 0 failures')
      expect(last_cmd_exit_status).to eq(0)
    end

    it 'accepts --parallel with worker count greater than available examples' do
      run_command 'spec --parallel=4'

      expect(last_cmd_stdout).to include('6 examples, 0 failures')
      expect(last_cmd_exit_status).to eq(0)
    end
  end

  describe 'failure handling' do
    before :all do
      write_file_formatted 'spec/failing_spec.rb', "
        RSpec.describe 'Failing group' do
          it 'passes' do
            expect(1).to eq(1)
          end

          it 'fails' do
            expect(1).to eq(2)
          end

          it 'also passes' do
            expect(2).to eq(2)
          end
        end
      "
    end

    after(:all) { remove 'spec/failing_spec.rb' }

    it 'reports failures correctly in parallel mode' do
      run_command 'spec --parallel=2'

      expect(last_cmd_stdout).to include('9 examples, 1 failure')
      expect(last_cmd_stdout).to include('expected: 2')
      expect(last_cmd_stdout).to include('got: 1')
      expect(last_cmd_exit_status).to_not eq(0)
    end

    it 'handles --fail-fast with parallel execution' do
      run_command 'spec/failing_spec.rb --parallel=2 --fail-fast'

      expect(last_cmd_stdout).to match(/\d+ examples?, 1 failure/)
      expect(last_cmd_exit_status).to_not eq(0)
    end
  end

  describe 'output formatting' do
    it 'works with documentation formatter' do
      run_command 'spec --parallel=2 -f doc'

      expect(last_cmd_stdout).to include('Running tests in parallel')
      expect(last_cmd_stdout).to include('example 1')
      expect(last_cmd_stdout).to include('example 2')
      expect(last_cmd_stdout).to include('6 examples, 0 failures')
      expect(last_cmd_exit_status).to eq(0)
    end

    it 'works with progress formatter' do
      run_command 'spec --parallel=2 -f p'

      expect(last_cmd_stdout).to match(/\.+/)
      expect(last_cmd_stdout).to include('6 examples, 0 failures')
      expect(last_cmd_exit_status).to eq(0)
    end
  end

  describe 'invalid arguments' do
    it 'warns when given a non-integer value' do
      run_command 'spec --parallel=foo'

      expect(last_cmd_stderr).to include('Expected an integer value for `--parallel`')
      expect(last_cmd_exit_status).to eq(0) # Still runs with default
    end

    it 'warns when given zero' do
      run_command 'spec --parallel=0'

      expect(last_cmd_stderr).to include('Expected a positive integer for `--parallel`')
      expect(last_cmd_exit_status).to eq(0) # Still runs with 1 worker
    end

    it 'warns when given a negative number' do
      run_command 'spec --parallel=-2'

      expect(last_cmd_stderr).to include('Expected a positive integer for `--parallel`')
      expect(last_cmd_exit_status).to eq(0) # Still runs with 1 worker
    end
  end

  describe 'interaction with other options' do
    it 'works with --seed option' do
      run_command 'spec --parallel=2 --seed 42'

      expect(last_cmd_stdout).to include('Randomized with seed 42')
      expect(last_cmd_stdout).to include('6 examples, 0 failures')
      expect(last_cmd_exit_status).to eq(0)
    end

    it 'works with --order defined' do
      run_command 'spec --parallel=2 --order defined'

      expect(last_cmd_stdout).to include('6 examples, 0 failures')
      expect(last_cmd_stdout).to_not include('Randomized')
      expect(last_cmd_exit_status).to eq(0)
    end

    it 'works with specific file paths' do
      run_command 'spec/group_1_spec.rb spec/group_2_spec.rb --parallel=2'

      expect(last_cmd_stdout).to include('5 examples, 0 failures')
      expect(last_cmd_exit_status).to eq(0)
    end
  end

  describe 'pending examples' do
    before :all do
      write_file_formatted 'spec/pending_spec.rb', "
        RSpec.describe 'Pending group' do
          it 'passes' do
            expect(1).to eq(1)
          end

          it 'is pending' do
            pending 'not implemented yet'
            expect(1).to eq(2)
          end

          it 'is skipped', skip: true do
            expect(1).to eq(2)
          end
        end
      "
    end

    after(:all) { remove 'spec/pending_spec.rb' }

    it 'reports pending examples correctly' do
      run_command 'spec --parallel=2'

      expect(last_cmd_stdout).to include('9 examples, 0 failures, 2 pending')
      expect(last_cmd_stdout).to include('not implemented yet')
      expect(last_cmd_exit_status).to eq(0)
    end
  end

  describe 'example metadata and filtering' do
    before :all do
      write_file_formatted 'spec/tagged_spec.rb', "
        RSpec.describe 'Tagged examples' do
          it 'is slow', :slow do
            expect(1).to eq(1)
          end

          it 'is fast' do
            expect(2).to eq(2)
          end

          it 'is also slow', :slow do
            expect(3).to eq(3)
          end
        end
      "
    end

    after(:all) { remove 'spec/tagged_spec.rb' }

    it 'works with tag filtering' do
      run_command 'spec --parallel=2 --tag slow'

      expect(last_cmd_stdout).to include('2 examples, 0 failures')
      expect(last_cmd_exit_status).to eq(0)
    end

    it 'works with tag exclusion' do
      run_command 'spec/tagged_spec.rb --parallel=2 --tag ~slow'

      expect(last_cmd_stdout).to include('1 example, 0 failures')
      expect(last_cmd_exit_status).to eq(0)
    end
  end

  describe 'with --parallel=1' do
    it 'runs serially but through parallel infrastructure' do
      run_command 'spec --parallel=1'

      expect(last_cmd_stdout).to include('6 examples, 0 failures')
      expect(last_cmd_exit_status).to eq(0)
    end
  end

  describe 'file path with line numbers' do
    it 'runs specific examples via line number in parallel mode' do
      # Line 3 targets the first example in group_1_spec.rb
      run_command 'spec/group_1_spec.rb:3 --parallel=2'

      expect(last_cmd_stdout).to include('1 example, 0 failures')
      expect(last_cmd_exit_status).to eq(0)
    end

    it 'runs multiple file:line specifications in parallel' do
      # Line 3 in both files targets the first example in each
      run_command 'spec/group_1_spec.rb:3 spec/group_2_spec.rb:3 --parallel=2'

      expect(last_cmd_stdout).to include('2 examples, 0 failures')
      expect(last_cmd_exit_status).to eq(0)
    end
  end
end
