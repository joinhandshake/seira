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

      def log_link(context:, app:, query:)
        link = context[:settings].log_link_format
        return nil if link.nil?
        link.gsub! 'APP', app
        link.gsub! 'CLUSTER', context[:cluster]
        link.gsub! 'QUERY', query
        link
      end
    end
  end
end
