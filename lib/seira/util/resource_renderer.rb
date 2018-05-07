module Seira
  module Util
    class ResourceRenderer
      include ERB::Util

      def initialize(template:, context:, locals:)
        @template = template
        @context = context
        @locals = locals
        @summary = {}
      end

      # "binding" is a special method every ruby object has to expose its
      # instance variables
      # https://ruby-doc.org/core-2.2.0/Binding.html
      def render
        result = ERB.new(@template).result(binding)

        puts "Rendered with following ERB variables:"
        @summary.each do |key, value|
          puts "#{key}: #{value}"
        end

        result
      end

      def current_replica_count(deployment)
        count = Seira::Helpers.get_current_replicas(deployment: deployment, context: @context)
        @summary["#{deployment}-replicas"] = count

        # Validate a sane count so that we don't accidentally deploy 0 replicas
        unless count && count.is_a?(Integer) && count > 0 && count < 9999
          fail "Received invalid value for replica count for Deployment #{deployment} '#{count}'"
        end

        count
      end

      def target_revision
        @locals['REVISION']
      end

      def restarted_at_value
        @locals['RESTARTED_AT_VALUE']
      end
    end
  end
end
