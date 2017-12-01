require 'json'

module Seira
  class Pods
    VALID_ACTIONS = %w[list delete logs top run connect].freeze

    attr_reader :app, :action, :args, :pod_name, :context

    def initialize(app:, action:, args:, context:)
      @app = app
      @action = action
      @context = context
      @args = args
      @pod_name = args[0]
    end

    def run
      case action
      when 'list'
        run_list
      when 'delete'
        run_delete
      when 'logs'
        run_logs
      when 'top'
        run_top
      when 'connect'
        run_connect
      when 'run'
        run_run
      else
        fail "Unknown command encountered"
      end
    end

    private

    def run_list
      puts `kubectl get pods --namespace=#{app} -o wide`
    end

    def run_delete
      puts `kubectl delete pod #{pod_name} --namespace=#{app}`
    end

    def run_logs
      puts `kubectl logs #{pod_name} --namespace=#{app} -c #{app}`
    end

    def run_top
      puts `kubectl top pod #{pod_name} --namespace=#{app} --containers`
    end

    def run_connect
      # If a pod name is specified, connect to that pod; otherwise pick a random web pod
      target_pod_name = pod_name || fetch_pods(app: app, tier: 'web').sample&.dig('metadata', 'name')

      if target_pod_name
        connect_to_pod(target_pod_name)
      else
        puts "Could not find web pod to connect to"
      end
    end

    def run_run
      # Set defaults
      tier = 'web'
      container_name = app

      # Loop through args and process any that aren't just the command to run
      loop do
        arg = args.first
        if arg.nil?
          puts 'Please specify a command to run'
          exit(1)
        end
        break unless arg.start_with? '--'
        if arg.start_with? '--tier='
          tier = arg.split('=')[1]
        else
          puts "Warning: Unrecognized argument #{arg}"
        end
        args.shift
      end

      # Any remaining args are the command to run
      command = args.join(' ')

      # Find a 'template' pod from the proper tier
      template_pod = fetch_pods(app: app, tier: 'web').first
      if template_pod.nil?
        puts "Unable to find #{tier} tier pod to copy config from"
        exit(1)
      end

      # Use that template pod's configuration to create a new temporary pod
      temp_name = "#{app}-temp-#{Random.unique_name}"
      spec = template_pod['spec']
      temp_pod = {
        apiVersion: template_pod['apiVersion'],
        kind: 'Pod',
        spec: spec,
        metadata: {
          name: temp_name
        }
      }
      spec['restartPolicy'] = 'Never'

      puts "Creating temporary pod #{temp_name}"
      unless system("kubectl --namespace=#{app} create -f - <<JSON\n#{temp_pod.to_json}\nJSON")
        puts 'Failed to create pod'
        exit(1)
      end

      # Check pod status until the container we want is ready
      print 'Waiting for pod to start...'
      loop do
        pod = JSON.parse(`kubectl --namespace=#{app} get pods/#{temp_name} -o json`)
        break if pod['status']['phase'] == 'Running'
        print '.'
        sleep 1
      end
      print "\n"

      # Connect to the pod, running the specified command
      connect_to_pod(temp_name, command)

      # Clean up
      unless system("kubectl --namespace=#{app} delete pod #{temp_name}")
        puts "Warning: failed to clean up pod"
      end
    end

    def fetch_pods(filters)
      filter_string = filters.map { |k, v| "#{k}=#{v}" }.join(',')
      JSON.parse(`kubectl get pods --namespace=#{app} -o json --selector=#{filter_string}`)['items']
    end

    def connect_to_pod(name, command = 'bash')
      puts "Connecting to #{name}..."
      unless system("kubectl exec -ti #{name} --namespace=#{app} -- #{command}")
        puts 'Failed to connect'
        exit(1)
      end
    end
  end
end
