module Seira
  module Commands
    class Kubectl
      attr_reader :context, :command

      def initialize(command, context:)
        @command = command
        @context = context
      end

      def invoke(clean_output: false, return_output: false)
        puts "Calling: #{calculated_command.green}" unless clean_output
        
        if return_output
          `#{calculated_command}`
        else
          system(calculated_command)
        end
      end

      private

      def calculated_command
        @_calculated_command ||= 
          if context == :none
            "kubectl #{command}"
          else
            "kubectl #{command} --namespace=#{context[:app]}"
          end
      end
    end
  end
end