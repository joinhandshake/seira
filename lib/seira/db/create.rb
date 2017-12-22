module Seira
  class Db
    class Create
      attr_reader :app, :action, :args, :context
      attr_reader :name, :version, :cpu, :memory, :storage, :set_as_primary, :replica_for, :make_highly_available
      attr_reader :root_password, :proxyuser_password

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
        @set_as_primary = false
        @replica_for = nil
        @make_highly_available = false

        @root_password = nil
        @proxyuser_password = nil
      end

      def run(existing_instances)
        @name = "#{app}-#{Seira::Random.unique_name(existing_instances)}"

        run_create_command

        if replica_for.nil?
          update_root_password
          create_proxy_user
        end

        set_secrets
        copy_pgbouncer_yaml
      end

      private

      def run_create_command
        # The 'beta' is needed for HA and other beta features
        create_command = "gcloud beta sql instances create #{name}"

        args.each do |arg|
          if arg.start_with? '--version='
            version = arg.split('=')[1]
          elsif arg.start_with? '--cpu='
            cpu = arg.split('=')[1]
          elsif arg.start_with? '--memory='
            memory = arg.split('=')[1]
          elsif arg.start_with? '--storage='
            storage = arg.split('=')[1]
          elsif arg.start_with? '--set-as-primary='
            set_as_primary = %w[true yes t y].include?(arg.split('=')[1])
          elsif arg.start_with? '--primary='
            replica_for = arg.split('=')[1] # TODO: Read secret to get it automatically
          elsif arg.start_with? '--highly-available'
            make_highly_available = true
          elsif /^--[\w\-]+=.+$/.match? arg
            create_command += " #{arg}"
          else
            puts "Warning: Unrecognized argument '#{arg}'"
          end
        end

        if set_as_primary && !replica_for.nil?
          puts "Cannot make a read-replica the primary database."
          exit(1)
        end

        if make_highly_available && !replica_for.nil?
          puts "Cannot create an HA read-replica."
          exit(1)
        end

        # Basic configs
        create_command += " --database-version=#{version}"

        # A read replica cannot have HA, inherits the cpu, mem and storage of its primary
        if replica_for.nil?
          # Make sure to do automated daily backups by default, unless it's a replica
          create_command += " --backup"
          create_command += " --cpu=#{cpu}"
          create_command += " --memory=#{memory}"
          create_command += " --storage-size=#{storage}"

          # Make HA if asked for
          create_command += " --availability-type=REGIONAL" if make_highly_available
        end

        # Make a read-replica if asked for
        create_command += " --master-instance-name=#{replica_for}" unless replica_for.nil?

        puts "Running: #{create_command}"

        # Create the sql instance with the specified/default parameters
        if system(create_command)
          puts "Successfully created sql instance #{name}"
        else
          puts "Failed to create sql instance"
          exit(1)
        end
      end

      def update_root_password
        # Set the root user's password to something secure
        @root_password = SecureRandom.urlsafe_base64(32)

        if system("gcloud sql users set-password postgres '' --instance=#{name} --password=#{root_password}")
          puts "Set root password to #{root_password}"
        else
          puts "Failed to set root password"
          exit(1)
        end
      end

      def create_proxy_user
        # Create proxyuser with secure password
        @proxyuser_password = SecureRandom.urlsafe_base64(32)

        if system("gcloud sql users create proxyuser '' --instance=#{name} --password=#{proxyuser_password}")
          puts "Created proxyuser with password #{proxyuser_password}"
        else
          puts "Failed to create proxyuser"
          exit(1)
        end

        # Connect to the instance and remove some of the default group memberships and permissions
        # from proxyuser, leaving it with only what it needs to be able to do
        expect_script = <<~BASH
          set timeout 90
          spawn gcloud sql connect #{name}
          expect "Password for user postgres:"
          send "#{root_password}\\r"
          expect "postgres=>"
          send "ALTER ROLE proxyuser NOCREATEDB NOCREATEROLE;\\r"
          expect "postgres=>"
        BASH
        if system("expect <<EOF\n#{expect_script}EOF")
          puts "Successfully removed unnecessary permissions from proxyuser"
        else
          puts "Failed to remove unnecessary permissions from proxyuser"
          exit(1)
        end
      end

      def set_secrets
        # If setting as primary, update relevant secrets
        if set_as_primary
          create_pgbouncer_secret
          Secrets.new(app: app, action: 'set', args: ["DATABASE_URL=postgres://proxyuser:#{proxyuser_password}@#{pgbouncer_service_name}:6432"], context: context).run
        end
        # Regardless of primary or not, store a URL for this db matching its unique name
        env_name = name.tr('-', '_').upcase
        Secrets.new(app: app, action: 'set', args: ["#{env_name}_DB_URL=postgres://proxyuser:#{proxyuser_password}@#{pgbouncer_service_name}:6432", "#{env_name}_ROOT_PASSWORD=#{root_password}"], context: context).run
      end
    end

    def create_pgbouncer_secret
      db_user = args[0]
      db_password = args[1]
      puts `kubectl create secret generic #{pgbouncer_secret_name} --namespace #{app} --from-literal=DB_USER=#{db_user} --from-literal=DB_PASSWORD=#{db_password}`
    end

    def pgbouncer_secret_name
      "#{name}-pgbouncer-secrets"
    end

    def pgbouncer_configs_name
      "#{name}-pgbouncer-configs"
    end

    def pgbouncer_service_name
      "#{app}-#{name}-pgbouncer-service"
    end

    def copy_pgbouncer_yaml
      pgbouncer_yaml = <<-FOO
      ---
      apiVersion: v1
      kind: ConfigMap
      metadata:
        name: #{pgbouncer_configs_name}
        namespace: #{app}
      data:
        DB_HOST: "127.0.0.1"
        DB_PORT: "5432"
        LISTEN_PORT: "6432"
        LISTEN_ADDRESS: "*"
        TCP_KEEPALIVE: "1"
        TCP_KEEPCNT: "5"
        TCP_KEEPIDLE: "300" # see: https://git.io/vi0Aj
        TCP_KEEPINTVL: "300"
        LOG_DISCONNECTIONS: "0" # spammy, not needed
        MAX_CLIENT_CONN: "500"
        MAX_DB_CONNECTIONS: "90"
        DEFAULT_POOL_SIZE: "90"
        POOL_MODE: "transaction"
      ---
      apiVersion: extensions/v1beta1
      kind: Deployment
      metadata:
        name: #{name}-pgbouncer
        namespace: #{app}
        labels:
          app: #{app}
          tier: database
          database: #{app}-#{name}
      spec:
        replicas: 1
        minReadySeconds: 20
        strategy:
          type: RollingUpdate
          rollingUpdate:
            maxSurge: 1
            maxUnavailable: 1
        template:
          metadata:
            labels:
              app: #{app}
              tier: database
              database: #{app}-#{name}
          spec:
            containers:
              - image: handshake/pgbouncer:0.1.2
                name: pgbouncer
                ports:
                  - containerPort: 6432
                    protocol: TCP
                envFrom:
                  - configMapRef:
                      name: #{pgbouncer_configs_name}
                  - secretRef:
                      name: #{pgbouncer_secret_name}
                readinessProbe:
                  tcpSocket:
                    port: 6432
                  initialDelaySeconds: 5
                  periodSeconds: 10
                livenessProbe:
                  tcpSocket:
                    port: 6432
                  initialDelaySeconds: 15
                  periodSeconds: 20
                resources:
                  requests:
                    cpu: 100m
                    memory: 300m
              - image: gcr.io/cloudsql-docker/gce-proxy:1.11    # Gcloud SQL Proxy
                name: cloudsql-proxy
                command:
                  - /cloud_sql_proxy
                  - --dir=/cloudsql
                  - -instances=#{context[:project]}:#{context[:default_zone]}:#{app}-#{name}=tcp:5432
                  - -credential_file=/secrets/cloudsql/credentials.json
                ports:
                  - containerPort: 5432
                    protocol: TCP
                envFrom:
                  - configMapRef:
                      name: cloudsql-configs
                volumeMounts:
                  - name: cloudsql-credentials
                    mountPath: /secrets/cloudsql
                    readOnly: true
                  - name: ssl-certs
                    mountPath: /etc/ssl/certs
                  - name: cloudsql
                    mountPath: /cloudsql
            volumes:
              - name: cloudsql-credentials
                secret:
                  secretName: cloudsql-credentials
              - name: cloudsql
                emptyDir:
              - name: ssl-certs
                hostPath:
                  path: /etc/ssl/certs
      ---
      apiVersion: v1
      kind: Service
      metadata:
        name: #{pgbouncer_service_name}
        namespace: #{app}
        labels:
          app: #{app}
          tier: database
      spec:
        type: NodePort
        ports:
        - protocol: TCP
          port: 6432
          targetPort: 6432
          nodePort: 0
        selector:
          app: #{app}
          tier: database
          database: #{app}-#{name}
      FOO

      File.write("kubernetes/#{env}/#{app}/pgbouncer-#{name}.yaml", pgbouncer_yaml)
    end
  end
end
