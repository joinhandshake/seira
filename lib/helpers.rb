module Seira
  class Helpers
    class << self
      def rails_env(context:)
        if context[:cluster] == 'internal'
          'production'
        else
          context[:cluster]
        end
      end

      def fetch_pods(filters:, app:)
        filter_string = { app: app }.merge(filters).map { |k, v| "#{k}=#{v}" }.join(',')
        JSON.parse(`kubectl get pods --namespace=#{app} -o json --selector=#{filter_string}`)['items']
      end
    end
  end
end
