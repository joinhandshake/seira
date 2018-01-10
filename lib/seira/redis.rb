require 'json'
require 'base64'

module Seira
  class Redis
    VALID_ACTIONS = %w[help list status credentials create delete].freeze
    SUMMARY = "Manage your Helm Redis instances.".freeze

    attr_reader :app, :action, :args, :context

    def initialize(app:, action:, args:, context:)
      @app = app
      @action = action
      @args = args
      @context = context
    end

    # TODO: logs, upgrades?, backups, restores, CLI connection
    def run
      case action
      when 'help'
        run_help
      when 'list'
        run_list
      when 'status'
        run_status
      when 'credentials'
        run_credentials
      when 'create'
        run_create
      when 'delete'
        run_delete
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

    def run_list
      puts existing_instances
    end

    def run_status
      puts `helm status #{app}-redis-#{args[0]}`
    end

    def run_create
      # Fairly beefy default compute because it's cheap and the longer we can defer upgrading the
      # better. Go even higher for production apps.
      # TODO: Enable metrics
      values = {
        persistence: {
          size: '1Gi'
        },
        resources: {
          requests: {
            cpu: '50m',
            memory: '50Mi'
          }
        }
      }

      # Redis is single-threaded, thus only one CPU is needed? Primary/replica
      # is needed for further throughput
      args.each do |arg|
        puts "Applying arg #{arg} to values"
        if arg.start_with?('--memory=')
          values[:resources][:requests][:memory] = arg.split('=')[1]
        elsif arg.start_with?('--volume=')
          values[:persistence][:volume] = arg.split('=')[1]
        elsif arg.start_with?('--cpu=')
          values[:resources][:requests][:cpu] = arg.split('=')[1]
        elsif arg.start_with?('--size=')
          size = arg.split('=')[1]
          case size
          when '1'
            values[:resources][:requests][:memory] = '50Mi'
            values[:persistence][:size] = '1Gi'
            values[:resources][:requests][:cpu] = '50m'
          when '2'
            values[:resources][:requests][:memory] = '100Mi'
            values[:persistence][:size] = '1Gi'
            values[:resources][:requests][:cpu] = '100m'
          when '3'
            values[:resources][:requests][:memory] = '250Mi'
            values[:persistence][:size] = '1Gi'
            values[:resources][:requests][:cpu] = '200m'
          when '4'
            values[:resources][:requests][:memory] = '500Mi'
            values[:persistence][:size] = '1Gi'
            values[:resources][:requests][:cpu] = '500m'
          when '5'
            values[:resources][:requests][:memory] = '1Gi'
            values[:persistence][:size] = '5Gi'
            values[:resources][:requests][:cpu] = '1'
          when '6'
            values[:resources][:requests][:memory] = '2Gi'
            values[:persistence][:size] = '5Gi'
            values[:resources][:requests][:cpu] = '1'
          when '7'
            values[:resources][:requests][:memory] = '5Gi'
            values[:persistence][:size] = '5Gi'
            values[:resources][:requests][:cpu] = '1'
          when '8'
            values[:resources][:requests][:memory] = '10Gi'
            values[:persistence][:size] = '20Gi'
            values[:resources][:requests][:cpu] = '1'
          when '9'
            values[:resources][:requests][:memory] = '20Gi'
            values[:persistence][:size] = '40Gi'
            values[:resources][:requests][:cpu] = '1'
          else
            fail "There is no size option '#{size}'"
          end
        end
      end

      Dir.mktmpdir do |dir|
        file_name = write_config(dir: dir, values: values)
        unique_name = Seira::Random.unique_name(existing_instances)
        name = "#{app}-redis-#{unique_name}"
        puts `helm install --namespace #{app} --name #{name} --wait -f #{file_name} stable/redis`
      end

      puts "To get status: 'seira #{context[:cluster]} #{app} redis status #{unique_name}'"
      puts "To get credentials for storing in app secrets: 'seira #{context[:cluster]} #{app} redis credentials #{unique_name}'"
      puts "Service URI for this Redis instance: 'redis://:<password goes here>@#{name}-redis:6379/0'."
    end

    def run_delete
      to_delete = "#{app}-redis-#{args[0]}"

      exit(1) unless HighLine.agree("Are you sure you want to delete #{to_delete}? If any apps are using this redis instance, they will break.")

      if system("helm delete #{to_delete}")
        puts "Successfully deleted #{to_delete}. Mistake and seeing errors now? You can rollback easily. Below is last 5 revisions of the now deleted resource."
        history = `helm history --max 5 #{to_delete}`
        puts history
        last_revision = history.split("\n").last.split(" ").map(&:strip)[0]
        puts "helm rollback #{to_delete} #{last_revision}"
        puts "Docs: https://github.com/kubernetes/helm/blob/master/docs/helm/helm_rollback.md"
      else
        puts "Delete failed"
      end
    end

    def write_config(dir:, values:)
      file_name = "#{dir}/temp-redis-config-#{Seira::Cluster.current_cluster}-#{app}.json"
      File.open(file_name, "wb") do |f|
        f.write(values.to_json)
      end
      file_name
    end

    def existing_instances
      list = `helm list`.split("\n").select { |item| item.start_with?("#{app}-redis") }.map { |name| name.gsub(/^#{app}-redis-/, '') }
    end
  end
end
