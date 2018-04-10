require 'securerandom'

require_relative 'db/create'

module Seira
  class Db
    include Seira::Commands

    VALID_ACTIONS = %w[help create delete list restart connect ps kill analyze create-readonly-user].freeze
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
      when 'create-readonly-user'
        run_create_readonly_user
      else
        fail "Unknown command encountered"
      end
    end

    # NOTE: Relies on the pgbouncer instance being named based on the db name, as is done in create command
    def primary_instance
      database_url = Helpers.get_secret(app: app, key: 'DATABASE_URL')
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
      puts "create-readonly-user: Create a database user named by --username=<name> with only SELECT access privileges"
    end

    def run_create
      Seira::Db::Create.new(app: app, action: action, args: args, context: context).run(existing_instances)
    end

    def run_delete
      name = "#{app}-#{args[0]}"
      if gcloud("sql instances delete #{name}", context: context, format: :boolean)
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
      if gcloud("sql instances restart #{name}", context: context, format: :boolean)
        puts "Successfully restarted sql instance #{name}"
      else
        puts "Failed to restart sql instance #{name}"
      end
    end

    def run_connect
      name = args[0] || primary_instance
      puts "Connecting to #{name}..."
      root_password = Helpers.get_secret(app: app, key: "#{name.tr('-', '_').upcase}_ROOT_PASSWORD") || "Not found in secrets"
      puts "Your root password for 'postgres' user is: #{root_password}"
      system("gcloud sql connect #{name}")
    end

    def run_ps
      verbose = false
      args.each do |arg|
        if %w[--verbose -v].include? arg
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
        if %w[--force -f].include? arg
          force = true
        elsif /^\d+$/.match? arg
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

    # Example: seira staging app-name db create-readonly-user --username=readonlyuser
    def run_create_readonly_user
      instance_name = primary_instance # Always make user changes to primary instance, and they will propogate to replicas
      user_name = nil

      args.each do |arg|
        if arg.start_with? '--username='
          user_name = arg.split('=')[1]
        else
          puts "Warning: Unrecognized argument '#{arg}'"
        end
      end

      if user_name.nil? || user_name.strip.chomp == ''
        puts "Please specify the name of the read-only user to create, such as --username=testuser"
        exit(1)
      end

      # Require that the name be alpha only for simplicity and strict but basic validation
      if user_name.match(/\A[a-zA-Z]*\z/).nil?
        puts "Username must be characters only"
        exit(1)
      end

      valid_instance_names = existing_instances(remove_app_prefix: false).join(', ')
      if instance_name.nil? || instance_name.strip.chomp == '' || !valid_instance_names.include?(instance_name)
        puts "Could not find a valid instance name - does the DATABASE_URL have a value? Must be one of: #{valid_instance_names}"
        exit(1)
      end

      password = SecureRandom.urlsafe_base64(32)
      if gcloud("sql users create #{user_name} '' --instance=#{instance_name} --password=#{password}", context: context, format: :boolean)
        puts "Created user '#{user_name}' with password #{password}"
      else
        puts "Failed to create user '#{user_name}'"
        exit(1)
      end

      puts 'Setting permissions...'
      admin_commands =
        <<~SQL
          REVOKE cloudsqlsuperuser FROM #{user_name};
          ALTER ROLE #{user_name} NOCREATEDB NOCREATEROLE;
        SQL
      database_commands =
        <<~SQL
          REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM #{user_name};
          GRANT SELECT ON ALL TABLES IN SCHEMA public TO #{user_name};
          ALTER DEFAULT PRIVILEGES IN SCHEMA "public" GRANT SELECT ON TABLES TO #{user_name};
        SQL
      execute_db_command(admin_commands, as_admin: true)
      execute_db_command(database_commands)
    end

    def execute_db_command(sql_command, as_admin: false)
      # TODO(josh): move pgbouncer naming logic here and in Create to a common location
      instance_name = primary_instance
      tier = instance_name.gsub("#{app}-", '')
      matching_pods = Helpers.fetch_pods(app: app, filters: { tier: tier })
      if matching_pods.empty?
        puts 'Could not find pgbouncer pod to connect to'
        exit 1
      end
      pod_name = matching_pods.first['metadata']['name']
      psql_command =
        if as_admin
          root_password = Helpers.get_secret(app: app, key: "#{instance_name.tr('-', '_').upcase}_ROOT_PASSWORD")
          "psql postgres://postgres:#{root_password}@127.0.0.1:5432"
        else
          'psql'
        end
      exit 1 unless system("kubectl exec #{pod_name} --namespace #{app} -- #{psql_command} -c \"#{sql_command}\"")
    end

    def existing_instances(remove_app_prefix: true)
      plain_list = `gcloud sql instances list --uri`.split("\n").map { |uri| uri.split('/').last }.select { |name| name.start_with? "#{app}-" }

      if remove_app_prefix
        plain_list.map { |name| name.gsub(/^#{app}-/, '') }
      else
        plain_list
      end
    end
  end
end
