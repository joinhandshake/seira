module Seira
  module Commands
    class Kubectl
      attr_reader :context, :command

      def initialize(command, context:)
        @command = command
        @context = context
      end

      def invoke
        puts "Calling kubectl command #{calculated_command.green}"
        system(calculated_command)
      end

      private

      def calculated_command
        @_calculated_command ||= "kubectl #{command} --namespace=#{context[:app]}"
      end
    end
  end
end