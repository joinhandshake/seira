module Seira
  module Util
    class ResourceRenderer
      include ERB::Util

      def initialize(destination:, template:, locals:)
        @destination = destination
        @template = template
        @locals = locals
      end

      # "binding" is a special method every ruby object has to expose its
      # instance variables
      # https://ruby-doc.org/core-2.2.0/Binding.html
      def render
        ERB.new(@template).result(binding)
      end

      def current_replica_count(deployment)
        25
      end
    end
  end
end