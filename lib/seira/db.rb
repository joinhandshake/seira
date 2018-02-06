require 'securerandom'

require_relative 'db/create'

module Seira
  class Db
    VALID_ACTIONS = %w[help create delete list restart connect ps kill analyze].freeze
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
      when 'ps'
        run_ps
      when 'kill'
        run_kill
      when 'analyze'
        run_analyze
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
      puts "restart: Fully restart the database."
      puts "connect: Open a psql command prompt. You will be shown the password needed before the prompt opens."
      puts "ps: List running queries"
      puts "kill: Kill a query"
      puts "analyze: Display database performance information"
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

    def run_ps
      verbose = false
      args.each do |arg|
        if arg == '--verbose' || arg == '-v'
          verbose = true
        else
          puts "Warning: unrecognized argument #{arg}"
        end
      end

      execute_db_command(<<~SQL
        SELECT
          pid,
          state,
          application_name AS source,
          age(now(),query_start) AS running_for,
          query_start,
          wait_event IS NOT NULL AS waiting,
          query
        FROM pg_stat_activity
        WHERE
          query <> '<insufficient privilege>'
          #{verbose ? '' : "AND state <> 'idle'"}
          AND pid <> pg_backend_pid()
        ORDER BY query_start DESC
        SQL
      )
    end

    def run_kill
      force = false
      pid = nil

      args.each do |arg|
        if arg == '--force' || arg == '-f'
          force = true
        elsif /^\d+$/ =~ arg
          if pid.nil?
            pid = arg
          else
            puts 'Must specify only one PID'
            exit 1
          end
        else
          puts "Warning: unrecognized argument #{arg}"
        end
      end

      execute_db_command("SELECT #{force ? 'pg_terminate_backend' : 'pg_cancel_backend'}(#{pid})")
    end

    def run_analyze
      puts 'Cache Hit Rates'.bold
      execute_db_command(
        <<~SQL
          SELECT sum(heap_blks_read) as heap_read, sum(heap_blks_hit)  as heap_hit, (sum(heap_blks_hit) - sum(heap_blks_read)) / sum(heap_blks_hit) as ratio
          FROM pg_statio_user_tables;
        SQL
      )

      puts 'Index Usage Rates'.bold
      execute_db_command(
        <<~SQL
          SELECT relname, 100 * idx_scan / (seq_scan + idx_scan) percent_of_times_index_used, n_live_tup rows_in_table
          FROM pg_stat_user_tables
          WHERE (seq_scan + idx_scan) > 0
          ORDER BY n_live_tup DESC;
        SQL
      )
    end

    def execute_db_command(sql_command)
      # TODO(josh): move pgbouncer naming logic here and in Create to a common location
      tier = primary_instance.gsub("#{app}-", '')
      matching_pods = Helpers.fetch_pods(app: app, filters: { tier: tier })
      if matching_pods.length < 1
        puts 'Could not find pgbouncer pod to connect to'
        exit 1
      end
      pod_name = matching_pods.first['metadata']['name']
      exit 1 unless system("kubectl exec #{pod_name} --namespace #{app} -- psql -c \"#{sql_command}\"")
    end

    def existing_instances
      `gcloud sql instances list --uri`.split("\n").map { |uri| uri.split('/').last }.select { |name| name.start_with? "#{app}-" }.map { |name| name.gsub(/^#{app}-/, '') }
    end
  end
end
