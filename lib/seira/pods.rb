module Seira
  class Pods
    VALID_ACTIONS = %w[list delete logs top run].freeze

    attr_reader :app, :action, :key, :value, :context

    def initialize(app:, action:, args:, context:)
      @app = app
      @action = action
      @context = context
      @key = args[0]
      @value = args[1]
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
      when 'run'
        run_run
      else
        fail "Unknown command encountered"
      end
    end

    private

    def run_list
      puts list_pods
    end

    def run_delete
      puts `kubectl delete pod #{@key} --namespace=#{@app}`
    end

    def run_logs
      puts `kubectl logs #{@key} --namespace=#{@app} -c #{@app}`
    end

    def run_top
      puts `kubectl top pod #{@key} --namespace=#{@app} --containers`
    end

    def run_run
      pod_list = list_pods.split("\n")
      target_pod_type = "#{@app}-web"
      target_pod_options = pod_list.select { |pod| pod.include?(target_pod_type) }

      if target_pod_options.count > 0
        target_pod = target_pod_options[0]
        pod_name = target_pod.split(" ")[0]
        puts pod_name
        system("kubectl exec -ti #{pod_name} --namespace=#{@app} -- bash")
      else
        puts "Could not find web with name #{target_pod_type} to attach to"
      end
    end

    def list_pods
      `kubectl get pods --namespace=#{@app} -o wide`
    end
  end
end
