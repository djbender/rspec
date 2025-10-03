module RSpec
  module Core
    # Provides utilities for parallel test execution.
    # Contains serializers and stub objects for transmitting example data between processes.
    #
    # @private
    module Parallel
      # Serializes Example objects for transmission from worker processes to main process.
      # Example objects contain circular references and non-serializable state (e.g., ExampleGroup instances),
      # so we extract only the data needed by formatters.
      #
      # @private
      module ExampleSerializer
        # Serialize an Example object to a hash suitable for Marshal transmission
        # @param example [RSpec::Core::Example] the example to serialize
        # @return [Hash] serialized example data
        def self.serialize_example(example)
          {
            :id => example.id,
            :description => example.description,
            :full_description => example.full_description,
            :location => example.location,
            :file_path => example.file_path,
            :line_number => example.metadata[:line_number],
            :execution_result => serialize_execution_result(example.execution_result),
            :metadata => serialize_metadata(example.metadata)
          }
        end

        # Serialize an ExecutionResult object
        # @param result [RSpec::Core::Example::ExecutionResult] the result to serialize
        # @return [Hash] serialized execution result data
        def self.serialize_execution_result(result)
          {
            :status => result.status,
            :run_time => result.run_time,
            :exception => serialize_exception(result.exception),
            :pending_message => result.pending_message,
            :pending_fixed => result.pending_fixed?,
            :pending_exception => serialize_exception(result.pending_exception)
          }
        end

        # Serialize an exception object
        # @param exception [Exception, nil] the exception to serialize
        # @return [Hash, nil] serialized exception data or nil
        def self.serialize_exception(exception)
          return nil unless exception

          {
            :class_name => exception.class.name,
            :message => exception.message,
            :backtrace => exception.backtrace || []
          }
        end

        # Serialize metadata hash, extracting only serializable values
        # @param metadata [Hash] the metadata hash
        # @return [Hash] serialized metadata
        def self.serialize_metadata(metadata)
          # Extract commonly used metadata keys that are serializable
          # Avoid serializing ExampleGroup classes or Proc objects
          {
            :description => metadata[:description],
            :full_description => metadata[:full_description],
            :file_path => metadata[:file_path],
            :line_number => metadata[:line_number],
            :location => metadata[:location],
            :rerun_file_path => metadata[:rerun_file_path],
            :scoped_id => metadata[:scoped_id],
            :shared_group_inclusion_backtrace => metadata[:shared_group_inclusion_backtrace]
          }
        end
      end

      # Stub object that quacks like an Example for formatters
      # Formatters expect Example objects with specific methods, so we create
      # a minimal object that satisfies their interface.
      #
      # @private
      class ExampleStub
        attr_reader :id, :description, :full_description, :location, :file_path, :execution_result

        def initialize(serialized_data)
          @id = serialized_data[:id]
          @description = serialized_data[:description]
          @full_description = serialized_data[:full_description]
          @location = serialized_data[:location]
          @file_path = serialized_data[:file_path]
          @metadata = serialized_data[:metadata] || {}
          @execution_result = ExecutionResultStub.new(serialized_data[:execution_result])
        end

        # Return a stub example group for profiling
        # The profiler needs to access example_group.parent_groups, so we provide a minimal stub
        def example_group
          ExampleGroupStub.new
        end

        # Provide metadata access that returns nil-safe defaults
        attr_reader :metadata

        # Return the location for rerunning this example
        def location_rerun_argument
          @location
        end
      end

      # Stub object that quacks like an ExampleGroup
      # Minimal implementation for profiler support
      #
      # @private
      class ExampleGroupStub
        def parent_groups
          []
        end
      end

      # Stub object that quacks like an ExecutionResult
      #
      # @private
      class ExecutionResultStub
        attr_reader :status, :run_time, :exception, :pending_message, :pending_exception

        def initialize(serialized_data)
          @status = serialized_data[:status]
          @run_time = serialized_data[:run_time]
          @exception = serialized_data[:exception] ? ExceptionStub.new(serialized_data[:exception]) : nil
          @pending_message = serialized_data[:pending_message]
          @pending_fixed = serialized_data[:pending_fixed]
          @pending_exception = serialized_data[:pending_exception] ? ExceptionStub.new(serialized_data[:pending_exception]) : nil
        end

        def pending_fixed?
          @pending_fixed
        end

        def example_skipped?
          @status == :pending && !@pending_exception
        end
      end

      # Stub object that quacks like an Exception
      #
      # @private
      class ExceptionStub
        attr_reader :message, :backtrace

        def initialize(serialized_data)
          @class_name = serialized_data[:class_name]
          @message = serialized_data[:message]
          @backtrace = serialized_data[:backtrace]
        end

        def class
          # Return the actual exception class if it exists, otherwise use RuntimeError

          Object.const_get(@class_name)
        rescue NameError
          RuntimeError
        end

        # Return nil for cause (we don't serialize exception chains)
        def cause
          nil
        end
      end
    end
  end
end
