module Seira
  module Commands
    class Gcloud
      attr_reader :context, :command, :format, :clean_output

      def initialize(command, context:, clean_output:, format:)
        @command = command
        @context = context
        @format = format
        @clean_output = clean_output
      end

      def invoke
        puts "Calling: #{calculated_command.green}" unless clean_output

        if format == :boolean
          system(calculated_command)
        elsif format == :json
          `#{calculated_command}`
        end
      end

      private

      def calculated_command
        @_calculated_command ||=
          rv = nil

          rv =
            if context == :none
              "gcloud #{command}"
            else
              "gcloud #{command} --project=#{context[:project]}"
            end
        
          if format == :json
            rv = "#{rv} --format json"
          end

          rv
      end
    end
  end
end
