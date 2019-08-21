require 'json'
require 'base64'

# Example usages:
# seira staging specs secret set RAILS_ENV=staging
# seira demo tracking secret unset DISABLE_SOME_FEATURE
# seira staging importer secret list
# TODO: Can we avoid writing to disk completely and instead pipe in raw json?
module Seira
  class Secrets
    include Seira::Commands

    VALID_ACTIONS = %w[help get set unset list list-decoded create-secret-container].freeze
    PGBOUNCER_SECRETS_NAME = 'pgbouncer-secrets'.freeze
    SUMMARY = "Manage your application's secrets and environment variables.".freeze

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
      when 'list-decoded'
        run_list_decoded
      when 'create-secret-container'
        run_create_secret_container
      else
        fail "Unknown command encountered"
      end
    end

    def copy_secret_across_namespace(key:, to:, from:)
      puts "Copying the #{key} secret from namespace #{from} to #{to}."
      json_string = kubectl("get secret #{key} -o json -n #{from}", context: :none, return_output: true)
      secrets = JSON.parse(json_string)

      # At this point we would preferably simply do a write_secrets call, but the metadata is highly coupled to old
      # namespace so we need to clear out the old metadata
      new_secrets = Marshal.load(Marshal.dump(secrets))
      new_secrets.delete('metadata')
      new_secrets['metadata'] = {
        'name' => key,
        'namespace' => to
      }
      write_secrets(secrets: new_secrets, secret_name: key)
    end

    def main_secret_name
      "#{app}-secrets"
    end

    def get(key)
      secrets = fetch_current_secrets
      encoded_value = secrets.dig('data', key)
      encoded_value.nil? ? nil : Base64.decode64(encoded_value)
    end

    private

    def run_help
      puts SUMMARY
      puts "\n\n"
      puts "Possible actions to operate on secret contaiers. Default"
      puts "container will be used unless --container=<name> specified:\n\n"
      puts "get: fetch the value of a secret: `secrets get PASSWORD`"
      puts "set: set one or more secret values: `secrets set USERNAME=admin PASSWORD=asdf`"
      puts "     to specify a value with spaces: `secrets set LIPSUM=\"Lorem ipsum\"`"
      puts "     to specify a value with newlines: `secrets set RSA_KEY=\"$(cat key.pem)\"`"
      puts "unset: remove a secret: `secrets unset PASSWORD`"
      puts "list: list all secret keys and values"
      puts "list-decoded: list all secret keys and values, and decode from base64"
      puts "\n\n"
      puts "create-secret-container: takes one argument, the name, and creates a new container of secrets (Secret object) with that name"
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
        puts "Secret '#{key}' not found"
      else
        puts "#{key.green}: #{value}"
      end
    end

    def run_set
      secrets = fetch_current_secrets
      secrets['data'].merge!(key_value_map.transform_values { |value| Base64.strict_encode64(value) })
      write_secrets(secrets: secrets)
    end

    def run_unset
      secrets = fetch_current_secrets
      secrets['data'].delete(key)
      write_secrets(secrets: secrets)
    end

    def run_list
      secrets = fetch_current_secrets
      puts "Base64 encoded keys for #{app}:"
      secrets['data'].each do |k, v|
        puts "#{k.green}: #{v}"
      end
    end

    def run_list_decoded
      secrets = fetch_current_secrets
      puts "Decoded (raw) keys for #{app}:"
      secrets['data'].each do |k, v|
        puts "#{k.green}: #{Base64.decode64(v)}"
      end
    end

    def run_create_secret_container
      secret_name = key
      puts "Creating Kubernetes Secret with name '#{secret_name}'..."
      kubectl("create secret generic #{secret_name}", context: context)
      puts "Secret Object '#{secret_name}' created. You can now set, unset, list secrets in this container Secret object."
    end

    # In the normal case the secret we are updating is just main_secret_name,
    # but in special cases we may be doing an operation on a different secret such
    # as use passing --container arg
    def write_secrets(secrets:, secret_name: secret_container_from_args)
      Dir.mktmpdir do |dir|
        file_name = "#{dir}/temp-secrets-#{Seira::Cluster.current_cluster}-#{secret_name}.json"
        File.open(file_name, "w") do |f|
          f.write(secrets.to_json)
        end

        # The command we use depends on if it already exists or not
        secret_exists = kubectl("get secret #{secret_name}", context: context) # TODO: Do not log, pipe output to dev/null
        command = secret_exists ? "replace" : "create"

        if kubectl("#{command} -f #{file_name}", context: context)
          puts "Successfully created/replaced #{secret_name} secret #{key} in cluster #{Seira::Cluster.current_cluster}"
        else
          puts "Failed to update secret"
        end
      end
    end

    # Returns the still-base64encoded secrets hashmap
    def fetch_current_secrets
      json_string = kubectl("get secret #{secret_container_from_args} -o json", context: context, return_output: true)
      json = JSON.parse(json_string)
      json['data'] ||= {} # For secret that has no key/values yet, this ensures a consistent experience
      fail "Unexpected Kind" unless json['kind'] == 'Secret'
      json
    end

    def key
      args[0]
    end

    def secret_container_from_args
      relevant_arg = args.find { |arg| arg.start_with? '--container=' }

      if relevant_arg
        relevant_arg.split("=")[1]
      else
        main_secret_name
      end
    end

    # Filter out parameters which start with --
    def key_value_map
      args.select { |arg| !arg.start_with?("--") }.map do |arg|
        equals_index = arg.index('=')
        [arg[0..equals_index - 1], arg[equals_index + 1..-1]]
      end.to_h
    end
  end
end
