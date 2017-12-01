require 'json'

module Seira
  class Pods
    VALID_ACTIONS = %w[list delete logs top run].freeze

    attr_reader :app, :action, :args, :pod_name, :context

    def initialize(app:, action:, args:, context:)
      @app = app
      @action = action
      @context = context
      @args = args
      @pod_name = args[0]
    end

    def run
      # TODO: Some options: 'top', 'kill', 'delete', 'logs'
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
      target_pod_name = pod_name || fetch_pods(app: app, tier: 'web').sample&.dig('metadata', 'name')

      if target_pod_name
        puts "Connecting to {target_pod_name}..."
        system("kubectl exec -ti #{target_pod_name} --namespace=#{app} -- bash")
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
      template_pod = fetch_pods(app: app, tier: 'web').first
      if template_pod.nil?
        puts "Unable to find #{tier} tier pod to copy config from"
        exit(1)
      end

      # Use that template pod's configuration to create a Job
      temp_name = "#{app}-temp-#{Random.unique_name}"
      spec = template_pod['spec']
      job = {
        apiVersion: 'batch/v1',
        kind: 'Job',
        spec: {
          template: {
            metadata: {
              name: temp_name
            },
            spec: spec
          }
        },
        metadata: {
          name: temp_name
        }
      }
      spec['restartPolicy'] = 'Never'
      container = spec['containers'].find { |c| c['name'] == container_name }
      if container.nil?
        puts "Could not find container #{container_name} in tier #{tier} to run command in"
        exit(1)
      end
      container[:command] = [
        '/bin/bash',
        '-c',
        command
      ]
      puts "Running command as job #{temp_name}"
      unless system("kubectl --namespace=#{app} create -f - <<JSON\n#{job.to_json}\nJSON")
        puts 'Command failed to run'
        exit(1)
      end

      # The job is kicked off; get the pod it spawned
      pod = fetch_pods('job-name' => temp_name).first
      pod_name = pod['metadata']['name']

      # Check pod status until the container we want is ready
      print 'Waiting for job to start...'
      loop do
        status = pod.dig('status', 'containerStatuses')&.find { |c| c['name'] == container_name }
        break if status && status['ready']
        terminated_status = status&.dig('state', 'terminated')
        if terminated_status
          if terminated_status['message']
            puts "Job failed: #{terminated_status['message']}"
          elsif terminated_status['reason'] != 'Completed'
            puts "Job failed: #{terminated_status['reason']}"
          end
          break
        end
        print '.'
        sleep 1
        pod = JSON.parse(`kubectl --namespace=#{app} get pods/#{pod_name} -o json`)
      end
      print "\n"

      # Show the logs
      system("kubectl --namespace=#{app} logs --follow #{pod_name} --container=#{container_name}")

      unless system("kubectl --namespace=#{app} delete job #{temp_name}")
        puts 'Warning: Failed to clean up job'
      end
      fetch_pods('job-name' => temp_name).each do |p|
        unless system("kubectl --namespace=#{app} delete pod #{p['metadata']['name']}")
          puts "Warning: failed to clean up pod #{p['metadata']['name']}"
        end
      end
    end

    def fetch_pods(filters)
      filter_string = filters.map { |k, v| "#{k}=#{v}" }.join(',')
      JSON.parse(`kubectl get pods --namespace=#{app} -o json --selector=#{filter_string}`)['items']
    end
  end
end
