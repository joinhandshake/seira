module Seira
  class Helpers
    include Seira::Commands

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
        output = Seira::Commands.kubectl("get pods -o json --selector=#{filter_string}", context: { app: app }, return_output: true)
        JSON.parse(output)['items']
      end

      def log_link(context:, app:, query:)
        link = context[:settings].log_link_format
        return nil if link.nil?
        link.gsub! 'APP', app
        link.gsub! 'CLUSTER', context[:cluster]
        link.gsub! 'QUERY', query
        link
      end

      def get_secret(app:, key:, context: {})
        Secrets.new(app: app, action: 'get', args: [], context: context).get(key)
      end
    end
  end
end
