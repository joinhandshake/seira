require 'securerandom'

require_relative 'db/create.rb'

module Seira
  class Db
    VALID_ACTIONS = %w[help create delete list].freeze
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
      else
        fail "Unknown command encountered"
      end
    end

    private

    def run_help
      puts SUMMARY
      puts "\n\n"
      puts "TODO"
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

    def existing_instances
      `gcloud sql instances list --uri`.split("\n").map { |uri| uri.split('/').last }.select { |name| name.start_with? "#{app}-" }.map { |name| name.gsub(/^#{app}-/, '') }
    end
  end
end
