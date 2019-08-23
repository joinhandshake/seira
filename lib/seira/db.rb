require 'securerandom'
require 'English'

require_relative 'db/alter_proxyuser_roles'
require_relative 'db/write_pgbouncer_yaml'
require_relative 'db/create'

module Seira
  class Db
    include Seira::Commands

    VALID_ACTIONS = %w[
      help create delete list restart connect ps kill 
      analyze create-readonly-user psql table-sizes 
      index-sizes vacuum unused-indexes unused-indices 
      user-connections info alter-proxyuser-roles add
      write-pbouncer-yaml
    ].freeze
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
      when 'add'
        run_add
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
      when 'psql'
        run_psql
      when 'table-sizes'
        run_table_sizes
      when 'index-sizes'
        run_index_sizes
      when 'vacuum'
        run_vacuum
      when 'unused-indexes', 'unused-indices'
        run_unused_indexes
      when 'user-connections'
        run_user_connections
      when 'info'
        run_info
      when 'alter-proxyuser-roles'
        run_alter_proxyuser_roles
      when 'write-pgbouncer-yaml'
        run_write_pgbouncer_yaml
      else
        fail "Unknown command encountered"
      end
    end

    # NOTE: Relies on the pgbouncer instance being named based on the db name, as is done in create command
    def primary_instance
      database_url = Helpers.get_secret(context: context, key: 'DATABASE_URL')
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
      puts <<~HELPTEXT
        analyze:                Display database performance information
        connect:                Open a psql command prompt via gcloud connect. You will be shown the password needed before the prompt opens.
        create:                 Create a new postgres instance in cloud sql. Supports creating replicas and other numerous flags.
        add:                    Adds a new database to the given project. Requires --prefix=my-prefix to prefix the random name
        create-readonly-user:   Create a database user named by --username=<name> with only SELECT access privileges
        delete:                 Delete a postgres instance from cloud sql. Use with caution, and remove all kubernetes configs first.
        index-sizes:            List sizes of all indexes in the database
        info:                   Summarize all database instances for the app
        kill:                   Kill a query
        list:                   List all postgres instances.
        ps:                     List running queries
        psql:                   Open a psql prompt via kubectl exec into a pgbouncer pod.
        restart:                Fully restart the database.
        table-sizes:            List sizes of all tables in the database
        unused-indexes:         Show indexes with zero or low usage
        user-connections:       List number of connections per user
        vacuum:                 Run a VACUUM ANALYZE
        alter-proxyuser-roles:  Update NOCREATEDB and NOCREATEROLE roles for proxyuser in cloud sql.
        write-pbouncer-yaml:    Produces a Kubernetes Deployment yaml to run Pgbouncer for specified database.
      HELPTEXT
    end

    def run_create
      Seira::Db::Create.new(app: app, action: action, args: args, context: context).run(existing_instances)
    end

    def run_add
      Seira::Db::Create.new(app: app, action: action, args: args, context: context).add(existing_instances)
    end

    def run_alter_proxyuser_roles
      Seira::Db::AlterProxyuserRoles.new(app: app, action: action, args: args, context: context).run
    end

    def run_write_pgbouncer_yaml
      Seira::Db::WritePgbouncerYaml.new(app: app, args: args, context: context).run
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
      root_password = Helpers.get_secret(context: context, key: "#{name.tr('-', '_').upcase}_ROOT_PASSWORD") || "Not found in secrets"
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

      execute_db_command(
        <<~SQL
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
      if gcloud("sql users create #{user_name} --instance=#{instance_name} --password=#{password}", context: context, format: :boolean)
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

      puts "Connecting"
      execute_db_command(admin_commands, as_admin: true)
      execute_db_command(database_commands)
    end

    def run_psql
      execute_db_command(nil, interactive: true)
    end

    def run_table_sizes
      # https://wiki.postgresql.org/wiki/Disk_Usage
      execute_db_command(
        <<~SQL
          SELECT table_name
            , row_estimate
            , pg_size_pretty(table_bytes) AS table
            , pg_size_pretty(index_bytes) AS index
            , pg_size_pretty(toast_bytes) AS toast
            , pg_size_pretty(total_bytes) AS total
          FROM (
            SELECT *, total_bytes-index_bytes-COALESCE(toast_bytes,0) AS table_bytes FROM (
              SELECT relname AS table_name
                  , c.reltuples AS row_estimate
                  , pg_total_relation_size(c.oid) AS total_bytes
                  , pg_indexes_size(c.oid) AS index_bytes
                  , pg_total_relation_size(reltoastrelid) AS toast_bytes
                FROM pg_class c
                LEFT JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE relkind = 'r'
                AND n.nspname = 'public'
            ) a
          ) a
          ORDER BY total_bytes DESC;
        SQL
      )
    end

    def run_index_sizes
      # https://wiki.postgresql.org/wiki/Disk_Usage
      execute_db_command(
        <<~SQL
          SELECT relname AS index
            , c.reltuples AS row_estimate
            , pg_size_pretty(pg_relation_size(c.oid)) AS "size"
          FROM pg_class c
          LEFT JOIN pg_namespace n ON (n.oid = c.relnamespace)
          WHERE relkind = 'i'
          AND n.nspname = 'public'
          ORDER BY pg_relation_size(c.oid) DESC;
        SQL
      )
    end

    def run_vacuum
      execute_db_command(
        <<~SQL
          VACUUM VERBOSE ANALYZE;
        SQL
      )
    end

    def run_unused_indexes
      # https://github.com/heroku/heroku-pg-extras/blob/master/commands/unused_indexes.js
      execute_db_command(
        <<~SQL
          SELECT
            schemaname || '.' || relname AS table,
            indexrelname AS index,
            pg_size_pretty(pg_relation_size(i.indexrelid)) AS index_size,
            idx_scan as index_scans
          FROM pg_stat_user_indexes ui
          JOIN pg_index i ON ui.indexrelid = i.indexrelid
          WHERE NOT indisunique AND idx_scan < 50 AND pg_relation_size(relid) > 5 * 8192
          ORDER BY pg_relation_size(i.indexrelid) / nullif(idx_scan, 0) DESC NULLS FIRST,
          pg_relation_size(i.indexrelid) DESC;
        SQL
      )
    end

    def run_user_connections
      execute_db_command(
        <<~SQL
          SELECT usename AS user, count(pid) FROM pg_stat_activity GROUP BY usename;
        SQL
      )
    end

    def run_info
      instances = JSON.parse(gcloud("sql instances list --filter='name~\\A#{app}-'", context: context, format: :json))
      instances.each do |instance|
        db_info_command =
          <<~SQL
            COPY (SELECT pg_size_pretty(sum(pg_database_size(datname))) FROM pg_database) TO stdout;
            COPY (SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE') TO stdout;
            COPY (SELECT count(*) FROM pg_stat_activity) TO stdout;
          SQL
        db_info = execute_db_command(db_info_command, print: false)
        data_size, table_count, connection_count = db_info.split("\n")
        instance['data_size'] = data_size
        instance['table_count'] = table_count
        instance['connection_count'] = connection_count
      end
      instances.each do |instance|
        # https://cloud.google.com/sql/faq
        disk_size = instance['settings']['dataDiskSizeGb'].to_f
        connection_limit =
          if disk_size <= 0.6
            25
          elsif disk_size <= 3.75
            50
          elsif disk_size <= 6
            100
          elsif disk_size <= 7.5
            150
          elsif disk_size <= 15
            200
          elsif disk_size <= 30
            250
          elsif disk_size <= 60
            300
          elsif disk_size <= 120
            400
          else
            500
          end

        backup_info = instance['settings']['backupConfiguration']['enabled'] == 'true' ? instance['settings']['backupConfiguration']['startTime'] : 'false'

        puts "\n"
        puts instance['name'].bold
        puts <<~INFOTEXT
          State:        #{instance['state']}
          Tables:       #{instance['table_count']}
          Disk Size:    #{disk_size} GB
          Data Size:    #{instance['data_size']}
          Auto Resize:  #{instance['settings']['storageAutoResize']}
          Disk Type:    #{instance['settings']['dataDiskType']}
          Tier:         #{instance['settings']['tier']}
          Availability: #{instance['settings']['availabilityType']}
          Version:      #{instance['databaseVersion']}
          Backups:      #{backup_info}
          Connections:  #{instance['connection_count']}/#{connection_limit}(?)
        INFOTEXT
      end
    end

    def execute_db_command(sql_command, as_admin: false, interactive: false, print: true)
      # TODO(josh): move pgbouncer naming logic here and in Create to a common location
      instance_name = primary_instance
      private_ip = Helpers.sql_ips(instance_name, context: context)[:private]
      tier = instance_name.gsub("#{app}-", '')
      matching_pods = Helpers.fetch_pods(context: context, filters: { tier: tier })
      if matching_pods.empty?
        puts 'Could not find pgbouncer pod to connect to'
        exit 1
      end
      pod_name = matching_pods.first['metadata']['name']
      psql_command =
        if as_admin
          root_password = Helpers.get_secret(context: context, key: "#{instance_name.tr('-', '_').upcase}_ROOT_PASSWORD")
          "psql postgres://postgres:#{root_password}@#{private_ip}:5432"
        else
          "psql"
        end
      system_command = "kubectl exec #{pod_name} --namespace #{app}"
      system_command += ' -ti' if interactive
      system_command += " -- #{psql_command}"
      system_command += " -c \"#{sql_command}\"" unless sql_command.nil?
      if interactive
        exit(1) unless system(system_command)
      else
        output = `#{system_command}`
        success = $CHILD_STATUS.success?
        puts output if print || !success
        exit(1) unless success
        output
      end
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
