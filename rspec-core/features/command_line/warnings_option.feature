Feature: `--warnings` option (run with warnings enabled)

  Use the `--warnings` option to run specs with warnings enabled.

  Scenario:
    Given a file named "example_spec.rb" with:
      """ruby
      RSpec.describe do
        it 'generates warning' do
          $undefined
        end
      end
      """
    When I run `rspec --warnings example_spec.rb`
    Then the output should contain "warning"

  Scenario:
    Given a file named "example_spec.rb" with:
      """ruby
      RSpec.describe do
        it 'generates warning' do
          $undefined
        end
      end
      """
    When I run `rspec example_spec.rb`
    Then the output should not contain "warning"
