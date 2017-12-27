module Seira
  class Db
    class Create
      attr_reader :app, :action, :args, :context

      attr_reader :name, :version, :cpu, :memory, :storage, :replica_for, :make_highly_available
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
        write_pgbouncer_yaml

        puts "To use this database, deploy the pgbouncer config file that was created and use the ENV that was set."
        puts "To make this database the primary, promote it using the CLI and update the DATABASE_URL."
      end

      private

      def run_create_command
        # The 'beta' is needed for HA and other beta features
        create_command = "gcloud beta sql instances create #{name}"

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
            @replica_for = arg.split('=')[1] # TODO: Read secret to get it automatically
          elsif arg.start_with? '--highly-available'
            @make_highly_available = true
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

        puts "Running: #{create_command}"

        # Create the sql instance with the specified/default parameters
        if system(create_command)
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
        env_name = name.tr('-', '_').upcase

        # If setting as primary, update relevant secrets. Only primaries have root passwords.
        if replica_for.nil?
          create_pgbouncer_secret(db_user: 'proxyuser', db_password: proxyuser_password)
          Secrets.new(app: app, action: 'set', args: ["#{env_name}_ROOT_PASSWORD=#{root_password}"], context: context).run
          write_database_env(key: "DATABASE_URL", db_user: 'proxyuser', db_password: proxyuser_password)
          write_database_env(key: "#{env_name}_DB_URL", db_user: 'proxyuser', db_password: proxyuser_password)
        else
          # When creating a replica, we cannot manage users on the replica. We must manage the users on the primary, which the replica
          # inherits. For now we will use the same credentials that the primary uses.
          primary_uri = URI.parse(Secrets.new(app: app, action: 'get', args: [], context: context).get('DATABASE_URL'))
          primary_user = primary_uri.user
          primary_password = primary_uri.password
          create_pgbouncer_secret(db_user: primary_user, db_password: primary_password)
          write_database_env(key: "#{env_name}_DB_URL", db_user: primary_user, db_password: primary_password)
        end
      end

      def create_pgbouncer_secret(db_user:, db_password:)
        puts `kubectl create secret generic #{pgbouncer_secret_name} --namespace #{app} --from-literal=DB_USER=#{db_user} --from-literal=DB_PASSWORD=#{db_password}`
      end

      def write_database_env(key:, db_user:, db_password:)
        Secrets.new(app: app, action: 'set', args: ["#{key}=postgres://#{db_user}:#{db_password}@#{pgbouncer_service_name}:6432"], context: context).run
      end

      def pgbouncer_secret_name
        "#{name}-pgbouncer-secrets"
      end

      def pgbouncer_configs_name
        "#{name}-pgbouncer-configs"
      end

      def pgbouncer_service_name
        "#{name}-pgbouncer-service"
      end

      def pgbouncer_tier
        name.gsub("handshake-", "")
      end

      def write_pgbouncer_yaml
        # TODO: Clean this up by moving into a proper templated yaml file
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
    tier: #{pgbouncer_tier}
    database: #{name}
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
        tier: #{pgbouncer_tier}
        database: #{name}
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
            - -instances=#{context[:project]}:#{context[:default_zone]}:#{name}=tcp:5432
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
    tier: #{pgbouncer_tier}
spec:
  type: NodePort
  ports:
  - protocol: TCP
    port: 6432
    targetPort: 6432
    nodePort: 0
  selector:
    app: #{app}
    tier: #{pgbouncer_tier}
    database: #{name}
FOO

        File.write("kubernetes/#{context[:cluster]}/#{app}/pgbouncer-#{name.gsub("#{app}-", '')}.yaml", pgbouncer_yaml)
      end
    end
  end
end
