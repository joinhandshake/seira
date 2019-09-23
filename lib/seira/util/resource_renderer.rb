module Seira
  module Util
    class ResourceRenderer
      include ERB::Util

      DEFAULT_JOB_PARALELLISM = 1

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

      # BEGIN ERB templating methods and variables
      def current_replica_count(deployment)
        count = Seira::Helpers.get_current_replicas(deployment: deployment, context: @context)
        @summary["#{deployment}-replicas"] = count

        # Validate a sane count so that we don't accidentally deploy 0 replicas
        unless count && count.is_a?(Integer)
          fail "Received invalid value for replica count for Deployment #{deployment} '#{count}'"
        end

        count
      end

      def get_secret(secret_name)
        secret_value = Seira::Helpers.get_secret(key: secret_name, context: @context)
        @summary[secret_name] = 'fetched'

        # Validate we actually get something back
        fail "Missing value for secret #{secret_name}" unless secret_value

        secret_value
      end

      def job_parallelism(parallelism)
        rv = parallelism || DEFAULT_JOB_PARALELLISM
        @summary['parallelism'] = rv
        rv
      end

      def target_revision
        rv = @locals['REVISION']
        @summary["revision"] = rv
        rv
      end

      def restarted_at_value
        rv = @locals['RESTARTED_AT_VALUE']
        @summary["restarted_at_value"] = rv
        rv
      end
      # END ERB templating methods and variables
    end
  end
end
