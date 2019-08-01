require 'json'

# Example usages:
# seira staging specs config set RAILS_ENV=staging
# seira demo tracking config unset DISABLE_SOME_FEATURE
# seira staging importer config list
# TODO: Can we avoid writing to disk completely and instead pipe in raw json?
module Seira
  class Config
    include Seira::Commands

    VALID_ACTIONS = %w[help get set unset list].freeze
    SUMMARY = "Manage your application's environment variables configuration".freeze

    attr_reader :app, :action, :args, :context

    def initialize(app:, action:, args:, context:)
      @app = app
      @action = action
      @args = args
      @context = context
    end

    def run
      case action
      when 'help'
        run_help
      when 'get'
        validate_single_key
        run_get
      when 'set'
        validate_keys_and_values
        run_set
      when 'unset'
        validate_single_key
        run_unset
      when 'list'
        run_list
      else
        fail "Unknown command encountered"
      end
    end

    def main_config_name
      "#{app}-env-config"
    end

    def get(key)
      config = fetch_current_config
      value = config.dig('data', key)
      value.nil? ? nil : value
    end

    private

    def run_help
      puts SUMMARY
      puts "\n\n"
      puts "Possible actions:\n\n"
      puts "get: fetch the value of a config value: `config get DB_MAX_IDLE_CONNS`"
      puts "set: set one or more config values: `config set DB_MAX_IDLE_CONNS=10 DB_MAX_CONN_LIFETIME=2m`"
      puts "     to specify a value with spaces: `config set FOO=\"Lorem ipsum\"`"
      puts "unset: remove a config key: `config unset DB_MAX_IDLE_CONNS`"
      puts "list: list all config keys and values"
    end

    def validate_single_key
      if key.nil? || key.strip == ""
        puts "Please specify a key in all caps and with underscores"
        exit(1)
      end
    end

    def validate_keys_and_values
      if args.empty? || !args.all? { |arg| /^[^=]+=.+$/ =~ arg }
        puts "Please list keys and values to set like KEY_ONE=value_one KEY_TWO=value_two"
        exit(1)
      end
    end

    def run_get
      value = get(key)
      if value.nil?
        puts "Config '#{key}' not found"
      else
        puts "#{key.green}: #{value}"
      end
    end

    def run_set
      config = fetch_current_config
      config['data'].merge!(key_value_map.transform_values { |value| value })
      write_config(config: config)
    end

    def run_unset
      config = fetch_current_config
      config['data'].delete(key)
      write_config(config: config)
    end

    def run_list
      config = fetch_current_config
      puts "Base64 encoded keys for #{app}:"
      config['data'].each do |k, v|
        puts "#{k.green}: #{v}"
      end
    end

    # In the normal case the config we are updating is just main_config_name,
    # but in special cases we may be doing an operation on a different config
    def write_config(config:, config_name: main_config_name)
      Dir.mktmpdir do |dir|
        file_name = "#{dir}/temp-config-#{Seira::Cluster.current_cluster}-#{config_name}.json"
        File.open(file_name, "w") do |f|
          f.write(config.to_json)
        end

        # This only works if the config map already exists
        if kubectl("replace -f #{file_name}", context: context)
          puts "Successfully created/replaced #{config_name} config #{key} in cluster #{Seira::Cluster.current_cluster}"
        else
          puts "Failed to update configmap"
        end
      end
    end

    # Returns the configmap hashmap
    def fetch_current_config
      json_string = kubectl("get configmap #{main_config_name} -o json", context: context, return_output: true)
      json = JSON.parse(json_string)
      fail "Unexpected Kind" unless json['kind'] == 'ConfigMap'
      json
    end

    def key
      args[0]
    end

    def key_value_map
      args.map do |arg|
        equals_index = arg.index('=')
        [arg[0..equals_index - 1], arg[equals_index + 1..-1]]
      end.to_h
    end
  end
end
