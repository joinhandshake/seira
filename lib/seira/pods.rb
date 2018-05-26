require 'json'

module Seira
  class Pods
    include Seira::Commands

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
      kubectl("get pods -o wide", context: context)
    end

    def run_delete
      kubectl("delete pod #{pod_name}", context: context)
    end

    def run_logs
      kubectl("logs #{pod_name} -c #{app}")
    end

    def run_top
      kubectl("top pod #{pod_name} --containers", context: context)
    end

    def run_connect
      tier = nil
      pod_name = nil
      dedicated = false
      command = 'sh'

      args.each do |arg|
        if arg.start_with? '--tier='
          tier = arg.split('=')[1]
        elsif arg.start_with? '--pod='
          pod_name = arg.split('=')[1]
        elsif arg.start_with? '--command='
          command = arg.split('=')[1..-1].join('=')
        elsif arg == '--dedicated'
          dedicated = true
        else
          puts "Warning: Unrecognized argument #{arg}"
        end
      end

      # If a pod name is specified, find the pod with that name
      existing_pod = Helpers.fetch_pod(pod_name, context: context) unless pod_name.to_s.empty?

      # Use existing pod if found and not --dedicated
      # Otherwise, connect to a random pod from the specified tier or the 'terminal' tier if unspecified
      target_pod = if existing_pod && dedicated
                     puts "Cannot create new dedicated pod with name: #{pod_name}"
                     puts "A pod with this name already exists"
                     exit(1)
                   elsif existing_pod
                     existing_pod
                   else
                     Helpers.fetch_pods(context: context, filters: { tier: tier || 'terminal' }).sample
                   end

      if dedicated
        new_pod = if pod_name.nil?
                    create_dedicated_pod(target_pod)
                  else
                    create_dedicated_pod(target_pod, pod_name)
                  end

        connect_to_pod(new_pod, command)
        clean_up_pod(new_pod)
      elsif target_pod.nil?
        puts 'Could not find pod to connect to'
        exit(1)
      else
        # If we don't need a dedicated pod, it's way easier - just connect to the already running one
        connect_to_pod(target_pod.dig('metadata', 'name'), command)
      end
    end

    # Create a dedicated temp pod to run in
    # This is useful if you would like to have a persistent connection that doesn't get killed
    # when someone updates the terminal deployment, or if you want to avoid noisy neighbors
    # connected to the same pod.
    def create_dedicated_pod(target_pod, pod_name = "temp-#{Random.unique_name}")
      spec = target_pod['spec']
      temp_pod = {
        apiVersion: target_pod['apiVersion'],
        kind: 'Pod',
        spec: spec,
        metadata: {
          name: pod_name,
          annotations: {
            owner: Helpers.shell_username
          }
        }
      }
      # Don't restart the pod when it dies
      spec['restartPolicy'] = 'Never'
      # Overwrite container commands with something that times out, so if the client disconnects
      # there's a limited amount of time that the temp pod is still taking up resources
      # Note that this will break a pods which depends on containers running real commands, but
      # for a simple terminal pod it's fine
      spec['containers'].each do |container|
        container['command'] = %w[sleep 86400] # 86400 seconds = 24 hours
      end

      puts 'Creating dedicated pod...'
      unless system("kubectl --namespace=#{app} create -f - <<JSON\n#{temp_pod.to_json}\nJSON")
        puts 'Failed to create dedicated pod'
        exit(1)
      end

      print 'Waiting for dedicated pod to start...'
      loop do
        pod = JSON.parse(kubectl("get pods/#{pod_name} -o json", context: context, return_output: true))
        break if pod['status']['phase'] == 'Running'
        print '.'
        sleep 1
      end
      print "\n"

      pod_name
    end

    # Clean up pod so it isn't taking up resources. Usually only for dedicated pods
    def clean_up_pod(pod_name)
      unless kubectl("delete pods/#{pod_name}", context: context)
        puts 'Failed to delete temp pod'
      end
    end

    def connect_to_pod(name, command = 'sh')
      puts "Connecting to #{name}..."
      system("kubectl exec -ti #{name} --namespace=#{app} -- #{command}")
    end
  end
end
