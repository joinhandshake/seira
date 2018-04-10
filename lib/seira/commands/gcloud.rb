module Seira
  module Commands
    class Gcloud
      attr_reader :context, :command

      def initialize(command, context:)
        @command = command
        @context = context
      end

      def invoke(clean_output: false, format: :boolean)
        puts "Calling: #{calculated_command.green}" unless clean_output

        if format == :boolean
          system(calculated_command)
        elsif format == :json
          `#{calculated_command} --format json`
        end
      end

      private

      def calculated_command
        @_calculated_command ||=
          if context == :none
            "gcloud #{command}"
          else
            "gcloud #{command} --project=#{context[:project]}"
          end
      end
    end
  end
end
