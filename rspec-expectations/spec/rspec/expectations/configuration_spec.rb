# frozen_string_literal: true

module RSpec
  module Expectations
    RSpec.describe Configuration do
      let(:config) { Configuration.new }

      describe "#backtrace_formatter" do
        let(:original_backtrace) { %w[ clean-me/a.rb other/file.rb clean-me/b.rb ] }
        let(:cleaned_backtrace)  { %w[ other/file.rb ] }

        let(:formatted_backtrace) do
          config.backtrace_formatter.format_backtrace(original_backtrace)
        end

        before do
          @old_patterns = RSpec.configuration.backtrace_exclusion_patterns
          @orig_full_backtrace = RSpec.configuration.full_backtrace?
          RSpec.configuration.full_backtrace = false
          RSpec.configuration.backtrace_exclusion_patterns = [/clean-me/]
        end

        after do
          RSpec.configuration.backtrace_exclusion_patterns = @old_patterns
          RSpec.configuration.full_backtrace = @orig_full_backtrace
        end

        it "defaults to rspec-core's backtrace formatter when rspec-core is loaded" do
          expect(config.backtrace_formatter).to be(RSpec.configuration.backtrace_formatter)
          expect(formatted_backtrace).to eq(cleaned_backtrace)
        end

        it "defaults to a null formatter when rspec-core is not loaded" do
          RSpec::Mocks.with_temporary_scope do
            rspec_dup = ::RSpec.dup
            class << rspec_dup; undef configuration; end
            stub_const("RSpec", rspec_dup)

            expect(formatted_backtrace).to eq(original_backtrace)
          end
        end

        it "can be set to another backtrace formatter" do
          config.backtrace_formatter = double(:format_backtrace => ['a'])
          expect(formatted_backtrace).to eq(['a'])
        end
      end

      describe "#include_chain_clauses_in_custom_matcher_descriptions?" do
        it "is false by default" do
          expect(config.include_chain_clauses_in_custom_matcher_descriptions?).to be false
        end

        it "can be set to true" do
          config.include_chain_clauses_in_custom_matcher_descriptions = true
          expect(config.include_chain_clauses_in_custom_matcher_descriptions?).to be true
        end

        it "can be set back to false" do
          config.include_chain_clauses_in_custom_matcher_descriptions = true
          config.include_chain_clauses_in_custom_matcher_descriptions = false
          expect(config.include_chain_clauses_in_custom_matcher_descriptions?).to be false
        end
      end

      describe "#max_formatted_output_length=" do
        before do
          @orig_max_formatted_output_length = RSpec::Support::ObjectFormatter.default_instance.max_formatted_output_length
        end

        after do
          config.max_formatted_output_length = @orig_max_formatted_output_length
        end

        let(:object_with_large_inspect_string) { Struct.new(:value).new("a"*300) }

        it "sets the maximum object formatter length" do
          config.max_formatted_output_length = 10
          expect(RSpec::Support::ObjectFormatter.format(object_with_large_inspect_string)).to eq("#<stru...aaa\">")
        end

        it "formats the entire object when set to nil" do
          config.max_formatted_output_length = nil
          expect(RSpec::Support::ObjectFormatter.format(object_with_large_inspect_string)).to eq(object_with_large_inspect_string.inspect)
        end
      end

      describe "#warn_about_potential_false_positives?" do
        it "is deprecated" do
          expect(RSpec).to receive(:deprecate).with(
            "warn_about_potential_false_positives?",
            :replacement => "`on_potential_false_positives` which supports :warn, :raise, and :nothing behaviors"
          )
          config.warn_about_potential_false_positives?
        end

        it "returns true when on_potential_false_positives is :warn" do
          config.on_potential_false_positives = :warn
          expect(RSpec).to receive(:deprecate)
          expect(config.warn_about_potential_false_positives?).to be true
        end

        it "returns false when on_potential_false_positives is not :warn" do
          config.on_potential_false_positives = :nothing
          expect(RSpec).to receive(:deprecate)
          expect(config.warn_about_potential_false_positives?).to be false
        end
      end

      describe "#warn_about_potential_false_positives=" do
        it "is deprecated" do
          expect(RSpec).to receive(:deprecate).with(
            "warn_about_potential_false_positives=",
            :replacement => "`on_potential_false_positives=` which supports :warn, :raise, and :nothing behaviors"
          ).at_least(:once)
          config.warn_about_potential_false_positives = true
        end

        it "sets on_potential_false_positives to :warn when true" do
          allow(RSpec).to receive(:deprecate)
          config.warn_about_potential_false_positives = true
          expect(config.on_potential_false_positives).to eq(:warn)
        end

        it "sets on_potential_false_positives to :nothing when false" do
          allow(RSpec).to receive(:deprecate)
          config.warn_about_potential_false_positives = false
          expect(config.on_potential_false_positives).to eq(:nothing)
        end
      end

      describe '#on_potential_false_positives' do
        it 'is set to :warn by default' do
          expect(config.on_potential_false_positives).to eq :warn
        end

        it 'can be set to :nothing' do
          config.on_potential_false_positives = :nothing
          expect(config.on_potential_false_positives).to eq :nothing
        end

        it 'can be set back to :warn' do
          config.on_potential_false_positives = :nothing
          config.on_potential_false_positives = :warn
          expect(config.on_potential_false_positives).to eq :warn
        end

        it 'can be set to :raise' do
          config.on_potential_false_positives = :raise
          expect(config.on_potential_false_positives).to eq :raise
        end

        it 'cannot be set to :fooba' do
          expect {
            config.on_potential_false_positives = :fooba
          }.to raise_error(ArgumentError, /Supported values are/)
        end
      end
    end
  end
end
