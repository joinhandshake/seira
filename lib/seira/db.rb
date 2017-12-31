require 'securerandom'

require_relative 'db/create'

module Seira
  class Db
    VALID_ACTIONS = %w[help create delete list restart connect].freeze
    SUMMARY = "Manage your Cloud SQL Postgres databases.".freeze

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
      when 'create'
        run_create
      when 'delete'
        run_delete
      when 'list'
        run_list
      when 'restart'
        run_restart
      when 'connect'
        run_connect
      else
        fail "Unknown command encountered"
      end
    end

    # NOTE: Relies on the pgbouncer instance being named based on the db name, as is done in create command
    def primary_instance
      database_url = Secrets.new(app: app, action: 'get', args: [], context: context).get('DATABASE_URL')
      return nil unless database_url

      primary_uri = URI.parse(database_url)
      host = primary_uri.host

      # Convert handshake-onyx-burmese-pgbouncer-service to handshake-onyx-burmese
      host.gsub('-pgbouncer-service', '')
    end

    private

    def run_help
      puts SUMMARY
      puts "\n"
      puts "create: Create a new postgres instance in cloud sql. Supports creating replicas and other numerous flags."
      puts "delete: Delete a postgres instance from cloud sql. Use with caution, and remove all kubernetes configs first."
      puts "list: List all postgres instances."
    end

    def run_create
      Seira::Db::Create.new(app: app, action: action, args: args, context: context).run(existing_instances)
    end

    def run_delete
      name = "#{app}-#{args[0]}"
      if system("gcloud sql instances delete #{name}")
        puts "Successfully deleted sql instance #{name}"

        # TODO: Automate the below
        puts "Don't forget to delete the deployment, configmap, secret, and service for the pgbouncer instance."
      else
        puts "Failed to delete sql instance #{name}"
      end
    end

    def run_list
      puts existing_instances
    end

    def run_restart
      name = "#{app}-#{args[0]}"
      if system("gcloud sql instances restart #{name}")
        puts "Successfully restarted sql instance #{name}"
      else
        puts "Failed to restart sql instance #{name}"
      end
    end

    def run_connect
      name = args[0] || primary_instance
      puts "Connecting to #{name}..."
      root_password = Secrets.new(app: app, action: 'get', args: [], context: context).get("#{name.tr('-', '_').upcase}_ROOT_PASSWORD") || "Not found in secrets"
      puts "Your root password for 'postgres' user is: #{root_password}"
      system("gcloud sql connect #{name}")
    end

    def existing_instances
      `gcloud sql instances list --uri`.split("\n").map { |uri| uri.split('/').last }.select { |name| name.start_with? "#{app}-" }.map { |name| name.gsub(/^#{app}-/, '') }
    end
  end
end
