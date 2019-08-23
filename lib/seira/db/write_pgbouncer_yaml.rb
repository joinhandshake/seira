module Seira
  class Db
    class WritePgbouncerYaml
      include Seira::Commands

      attr_reader :app, :name

      def initialize(app:, action:, args:, context:)
        if args.length != 1
          puts 'Specify db name as positional argument'
          exit(1)
        end

        @app = app
        @name = args[0]
      end

      def run
        write_pgbouncer_yaml
      end

      private

      def pgbouncer_secret_name
        "#{name}-pgbouncer-secrets"
      end

      def pgbouncer_service_name
        "#{name}-pgbouncer-service"
      end

      def pgbouncer_tier
        name.gsub("#{app}-", "")
      end

      def write_pgbouncer_yaml
        # TODO: Clean this up by moving into a proper templated yaml file
        pgbouncer_yaml = <<-FOO
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: #{name}-pgbouncer
  namespace: #{app}
  labels:
    app: #{app}
    tier: #{pgbouncer_tier}
    database: #{name}
spec:
  replicas: 2
  selector:
    matchLabels:
      app: #{app}
      tier: #{pgbouncer_tier}
      database: #{name}
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
        - image: handshake/pgbouncer:0.2.0
          name: pgbouncer
          ports:
            - containerPort: 6432
              protocol: TCP
          envFrom:
            - secretRef:
                name: #{pgbouncer_secret_name}
          env:
            - name: "PGPORT"
              value: "6432"
            - name: "PGDATABASE"
              value: "#{name}"
            - name: "DB_HOST"
              value: "#{ips[:private]}" # private IP for #{name}
            - name: "DB_PORT"
              value: "5432"
            - name: "LISTEN_PORT"
              value: "6432"
            - name: "LISTEN_ADDRESS"
              value: "*"
            - name: "TCP_KEEPALIVE"
              value: "1"
            - name: "TCP_KEEPCNT"
              value: "5"
            - name: "TCP_KEEPIDLE"
              value: "300" # see: https://git.io/vi0Aj
            - name: "TCP_KEEPINTVL"
              value: "300"
            - name: "LOG_DISCONNECTIONS"
              value: "0" # spammy, not needed
            - name: "MAX_CLIENT_CONN"
              value: "1000"
            - name: "MIN_POOL_SIZE"
              value: "20" # This and DEFAULT should be roughly cpu cores * 2. Don't set too high.
            - name: "DEFAULT_POOL_SIZE"
              value: "20"
            - name: "MAX_DB_CONNECTIONS"
              value: "20"
            - name: "POOL_MODE"
              value: "transaction"
          readinessProbe:
            exec:
              command: ["psql", "-c", "SELECT 1;"]
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
              memory: 300Mi
          lifecycle:
            preStop:
              exec:
                command: ["/bin/sh", "-c", "killall -INT pgbouncer && sleep 20"]
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
  type: ClusterIP
  ports:
    - protocol: TCP
      port: 6432
      targetPort: 6432
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
  