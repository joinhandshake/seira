require 'json'
require 'base64'

module Seira
  class Memcached
    VALID_ACTIONS = %w[list status credentials create delete].freeze

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

    def run_list
      list = `helm list`.split("\n")
      filtered_list = list.select { |item| item.start_with?("#{app}-memcached") }
      filtered_list.each do |item|
        puts item
      end
    end

    def run_status
      puts `helm status #{app}-memcached-#{args[0]}`
    end

    def run_create
      # Fairly beefy default compute because it's cheap and the longer we can defer upgrading the
      # better. Go even higher for production apps.
      # TODO: Enable metrics
      values = {
        resources: {
          requests: {
            cpu: '1', # roughly 1 vCPU in both AWS and GCP terms
            memory: '5Gi' # memcached is in-memory - give it a lot
          }
        }
      }

      args.each do |arg|
        puts "Applying arg #{arg} to values"
        if arg.start_with?('--memory=')
          values[:resources][:requests][:memory] = arg.split('=')[1]
        elsif arg.start_with?('--cpu=')
          values[:resources][:requests][:cpu] = arg.split('=')[1]
        end
      end

      file_name = write_config(values)
      unique_name = Seira::Random.unique_name
      name = "#{app}-memcached-#{unique_name}"
      puts `helm install --namespace #{app} --name #{name} --wait -f #{file_name} stable/memcached`

      File.delete(file_name)

      puts "To get status: 'seira #{context[:cluster]} #{app} memcached status #{unique_name}'"
      puts "To get credentials for storing in app secrets: 'siera #{context[:cluster]} #{app} memcached credentials #{unique_name}'"
      puts "Service URI for this memcached instance: 'memcached://#{name}:11211'."
    end

    def run_delete
      to_delete = "#{app}-memcached-#{args[0]}"

      exit(1) unless HighLine.agree("Are you sure you want to delete #{to_delete}? If any apps are using this memcached instance, they will break.")

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

    def write_config(values)
      file_name = "tmp/temp-memcached-config-#{Seira::Cluster.current_cluster}-#{app}.json"
      File.open(file_name, "wb") do |f|
        f.write(values.to_json)
      end
      file_name
    end
  end
end
