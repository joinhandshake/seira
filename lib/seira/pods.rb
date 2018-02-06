require 'json'

module Seira
  class Pods
    VALID_ACTIONS = %w[help list delete logs top run connect].freeze
    SUMMARY = "Manage your application's pods.".freeze

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
      when 'help'
        run_help
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

    def run_help
      puts SUMMARY
      puts "\n\n"
      puts "TODO"
    end

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
      target_pod_name = pod_name || Helpers.fetch_pods(app: app, filters: { tier: 'web' }).sample&.dig('metadata', 'name')

      if target_pod_name
        connect_to_pod(target_pod_name)
      else
        puts "Could not find web pod to connect to"
      end
    end

    def run_run
      # Set defaults
      tier = 'web'
      clear_commands = false
      detached = false
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
        elsif arg == '--clear-commands'
          clear_commands = true
        elsif arg == '--detached'
          detached = true
        elsif arg.start_with? '--container='
          container_name = arg.split('=')[1]
        else
          puts "Warning: Unrecognized argument #{arg}"
        end
        args.shift
      end

      # Any remaining args are the command to run
      command = args.join(' ')

      # Find a 'template' pod from the proper tier
      template_pod = Helpers.fetch_pods(app: app, filters: { tier: tier }).first
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
      if clear_commands
        spec['containers'].each do |container|
          container['command'] = ['bash', '-c', 'tail -f /dev/null']
        end
      end

      if detached
        target_container = spec['containers'].find { |container| container['name'] == container_name }
        if target_container.nil?
          puts "Could not find container '#{container_name}' to run command in"
          exit(1)
        end
        target_container['command'] = ['bash', '-c', command]
      end

      puts "Creating temporary pod #{temp_name}"
      unless system("kubectl --namespace=#{app} create -f - <<JSON\n#{temp_pod.to_json}\nJSON")
        puts 'Failed to create pod'
        exit(1)
      end

      unless detached
        # Check pod status until it's ready to connect to
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
          puts "Warning: failed to clean up pod #{temp_name}"
        end
      end
    end

    def connect_to_pod(name, command = 'bash')
      puts "Connecting to #{name}..."
      system("kubectl exec -ti #{name} --namespace=#{app} -- #{command}")
    end
  end
end
