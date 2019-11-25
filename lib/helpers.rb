module Seira
  class Helpers
    include Seira::Commands

    class << self
      def rails_env(context:)
        parsed_env = context[:settings].settings['seira']['clusters'][context[:cluster]]['environment']
        parsed_env = context[:cluster] if parsed_env.nil?
        if parsed_env == 'internal'
          'production'
        else
          parsed_env
        end
      end

      def fetch_pods(filters:, context:)
        filter_string = { app: context[:app] }.merge(filters).map { |k, v| "#{k}=#{v}" }.join(',')
        output = Seira::Commands.kubectl("get pods -o json --selector=#{filter_string}", context: context, return_output: true)
        JSON.parse(output)['items']
      end

      def fetch_pod(name, context:)
        output = Seira::Commands.kubectl("get pod #{name} -o json", context: context, return_output: true)
        JSON.parse(output) unless output.empty?
      end

      def log_link(context:, query:)
        link = context[:settings].log_link_format
        return nil if link.nil?
        link.gsub! 'APP', context[:app]
        link.gsub! 'CLUSTER', context[:cluster]
        link.gsub! 'QUERY', query
        link
      end

      def get_secret(key:, context:)
        Secrets.new(app: context[:app], action: 'get', args: [], context: context).get(key)
      end

      def get_current_replicas(deployment:, context:)
        output = Seira::Commands.kubectl("get deployment #{deployment} -o json", context: context, return_output: true)
        JSON.parse(output)['spec']['replicas']
      end

      def shell_username
        `whoami`
      rescue
        'unknown'
      end

      def sql_ips(name, context:)
        describe_command = "sql instances describe #{name}"
        json = JSON.parse(Seira::Commands.gcloud(describe_command, context: context, format: :json))
        private_ip = extract_ip_if_present(json['ipAddresses'].find { |address| address['type'] == 'PRIVATE' })
        public_ip = extract_ip_if_present(json['ipAddresses'].find { |address| address['type'] == 'PRIMARY' })
        { private: private_ip, public: public_ip }
      end

      def extract_ip_if_present(ip_address)
        return nil if ip_address.nil?

        ip_address['ipAddress']
      end
    end
  end
end
