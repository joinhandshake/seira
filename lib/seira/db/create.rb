module Seira
  class Db
    class Create
      include Seira::Commands

      attr_reader :app, :action, :args, :context

      attr_reader :name, :version, :cpu, :memory, :storage, :replica_for, :make_highly_available
      attr_reader :root_password, :proxyuser_password
      attr_reader :prefix

      def initialize(app:, action:, args:, context:)
        @app = app
        @action = action
        @args = args
        @context = context

        # We allow overriding the version, so you could specify a mysql version but much of the
        # below assumes postgres for now
        @version = 'POSTGRES_9_6'
        @cpu = 1 # Number of CPUs
        @memory = 4 # GB
        @storage = 10 # GB
        @replica_for = nil
        @make_highly_available = false

        @root_password = nil
        @proxyuser_password = nil
      end

      def run(existing_instances)
        @name = "#{app}-#{Seira::Random.unique_name(existing_instances)}"

        run_create_command

        configure_created_db
      end

      def add(existing_instances)
        if !args.empty? && (args[0].start_with? '--prefix=')
          @prefix = args[0].split('=')[1]
        end

        if prefix.nil?
          puts "missing --prefix= for add command. Must be the first argument."
          exit(1)
        end

        # remove prefix from the head of the list since we don't want to pass it to gcloud
        args.pop

        @name = "#{app}-#{prefix}-#{Seira::Random.unique_name(existing_instances)}"
        puts "Attempting to create #{name}"
        run_create_command

        update_root_password
        create_proxy_user

        secrets_name = "#{name}-credentials"
        kubectl("create secret generic  #{secrets_name} --from-literal=ROOT_PASSWORD=#{root_password} --from-literal=PROXYUSER_PASSWORD=#{proxyuser_password}", context: context)
        puts "Credentials were saved in #{secrets_name}"
      end

      def configure(instance_name, master_name)
        @name = instance_name
        @replica_for = master_name

        configure_created_db

        puts "To use this database, use write-pgbouncer-yaml command and deploy the pgbouncer config file that was created and use the ENV that was set."
        puts "To make this database the primary, promote it using the CLI and update the DATABASE_URL."
      end

      private

      def configure_created_db
        if replica_for.nil?
          update_root_password
          create_proxy_user
        end

        set_secrets

        alter_proxy_user_roles if replica_for.nil?
      end

      def run_create_command
        # The 'beta' is needed for HA and other beta features
        create_command = "beta sql instances create #{name}"

        args.each do |arg|
          if arg.start_with? '--version='
            @version = arg.split('=')[1]
          elsif arg.start_with? '--cpu='
            @cpu = arg.split('=')[1]
          elsif arg.start_with? '--memory='
            @memory = arg.split('=')[1]
          elsif arg.start_with? '--storage='
            @storage = arg.split('=')[1]
          elsif arg.start_with? '--primary='
            @replica_for = arg.split('=')[1] # TODO: Read secret to get it automatically, but allow for fallback
          elsif arg.start_with? '--highly-available'
            @make_highly_available = true
          elsif arg.start_with? '--database-name='
            @database_name = arg.split('=')[1]
          elsif /^--[\w\-]+=.+$/.match? arg
            create_command += " #{arg}"
          else
            puts "Warning: Unrecognized argument '#{arg}'"
          end
        end

        if make_highly_available && !replica_for.nil?
          puts "Cannot create an HA read-replica."
          exit(1)
        end

        # Basic configs
        create_command += " --database-version=#{version}"
        create_command += " --network=default" # allow network to be configurable?
        create_command += " --no-assign-ip" # don't assign public ip

        # A read replica cannot have HA, inherits the cpu, mem and storage of its primary
        if replica_for.nil?
          # Make sure to do automated daily backups by default, unless it's a replica
          create_command += " --backup"
          create_command += " --cpu=#{cpu}"
          create_command += " --memory=#{memory}"
          create_command += " --storage-size=#{storage}"

          # Make HA if asked for
          create_command += " --availability-type=REGIONAL" if make_highly_available
        else
          create_command += " --master-instance-name=#{replica_for}"
          # We don't need to wait for it to finish to move ahead if it's a replica, as we don't
          # make any changes to the database itself
          create_command += " --async"
        end

        # Create the sql instance with the specified/default parameters
        if gcloud(create_command, context: context, format: :boolean)
          async_additional =
            unless replica_for.nil?
              ". Database is still being created and may take some time to be available."
            end

          puts "Successfully created sql instance #{name}#{async_additional}"
        else
          puts "Failed to create sql instance"
          exit(1)
        end
      end

      def update_root_password
        # Set the root user's password to something secure
        @root_password = SecureRandom.urlsafe_base64(32)

        if gcloud("sql users set-password postgres --instance=#{name} --password=#{root_password}", context: context, format: :boolean)
          puts "Set root password to #{root_password}"
        else
          puts "Failed to set root password"
          exit(1)
        end
      end

      def create_proxy_user
        # Create proxyuser with secure password
        @proxyuser_password = SecureRandom.urlsafe_base64(32)

        if gcloud("sql users create proxyuser --instance=#{name} --password=#{proxyuser_password}", context: context, format: :boolean)
          puts "Created proxyuser with password #{proxyuser_password}"
        else
          puts "Failed to create proxyuser"
          exit(1)
        end
      end

      def alter_proxy_user_roles
        Seira::Db::AlterProxyuserRoles.new(app: app, action: action, args: [name, root_password], context: context).run
      end

      def set_secrets
        env_name = name.tr('-', '_').upcase

        # If setting as primary, update relevant secrets. Only primaries have root passwords.
        if replica_for.nil?
          create_pgbouncer_secret(db_user: 'proxyuser', db_password: proxyuser_password)
          Secrets.new(app: app, action: 'set', args: ["#{env_name}_ROOT_PASSWORD=#{root_password}"], context: context).run
          # Set DATABASE_URL if not already set
          write_database_env(key: "DATABASE_URL", db_user: 'proxyuser', db_password: proxyuser_password) if Helpers.get_secret(context: context, key: "DATABASE_URL").nil?
          write_database_env(key: "#{env_name}_DB_URL", db_user: 'proxyuser', db_password: proxyuser_password)
        else
          # When creating a replica, we cannot manage users on the replica. We must manage the users on the primary, which the replica
          # inherits. For now we will use the same credentials that the primary uses.
          primary_uri = URI.parse(Helpers.get_secret(context: context, key: 'DATABASE_URL'))
          primary_user = primary_uri.user
          primary_password = primary_uri.password
          create_pgbouncer_secret(db_user: primary_user, db_password: primary_password)
          write_database_env(key: "#{env_name}_DB_URL", db_user: primary_user, db_password: primary_password)
        end
      end

      def create_pgbouncer_secret(db_user:, db_password:)
        kubectl("create secret generic #{pgbouncer_secret_name} --from-literal=DB_USER=#{db_user} --from-literal=DB_PASSWORD=#{db_password}", context: context)
      end

      def write_database_env(key:, db_user:, db_password:)
        Secrets.new(app: app, action: 'set', args: ["#{key}=postgres://#{db_user}:#{db_password}@#{pgbouncer_service_name}:6432"], context: context).run
      end

      def pgbouncer_secret_name
        "#{name}-pgbouncer-secrets"
      end

      def pgbouncer_service_name
        "#{name}-pgbouncer-service"
      end

      def pgbouncer_tier
        name.gsub("#{app}-", "")
      end

      def default_database_name
        "#{app}_#{Helpers.rails_env(context: context)}"
      end

      def ips
        @ips ||= Helpers.sql_ips(name, context: context)
      end
    end
  end
end
