require 'json'

module Seira
  class Jobs
    VALID_ACTIONS = %w[help list delete logs run].freeze
    SUMMARY = "Manage your application's jobs.".freeze

    attr_reader :app, :action, :args, :job_name, :context

    def initialize(app:, action:, args:, context:)
      @app = app
      @action = action
      @context = context
      @args = args
      @job_name = args[0]
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
      puts `kubectl get jobs --namespace=#{app} -o wide`
    end

    def run_delete
      puts `kubectl delete job #{job_name} --namespace=#{app}`
    end

    def run_logs
      puts `kubectl logs #{job_name} --namespace=#{app} -c #{app}`
    end

    def run_run
      gcp_app = App.new(app: app, action: 'apply', args: [""], context: context)
      
      # Set defaults
      detached = false # Wait for job to finish before continuing.
      no_delete = false # Delete at end

      # Loop through args and process any that aren't just the command to run
      loop do
        arg = args.first
        if arg.nil?
          puts 'Please specify a command to run'
          exit(1)
        end

        break unless arg.start_with? '--'

        if arg == '--detached'
          detached = true
        elsif arg == '--no-delete'
          no_delete = true
        else
          puts "Warning: Unrecognized argument #{arg}"
        end

        args.shift
      end

      if detached && !no_delete
        puts "Cannot delete Job after running if Job is detached, since we don't know when it finishes."
        exit(1)
      end

      # TODO: Configurable CPU and memory by args such as large, small, xlarge.
      command = args.join(' ')
      unique_name = "#{app}-run-#{Random.unique_name}"
      revision = gcp_app.ask_cluster_for_current_revision # TODO: Make more reliable, especially with no web tier
      replacement_hash = {
        'UNIQUE_NAME' => unique_name,
        'REVISION' => revision,
        'COMMAND' => command.split(' ').map { |part| "\"#{part}\"" }.join(", "),
        'CPU_REQUEST' => '200m',
        'CPU_LIMIT' => '500m',
        'MEMORY_REQUEST' => '500Mi',
        'MEMORY_LIMIT' => '1Gi',
      }

      source = "kubernetes/#{context[:cluster]}/#{app}" # TODO: Move to method in app.rb
      Dir.mktmpdir do |destination|
        revision = ENV['REVISION']
        file_name = "run.skip.yaml"

        FileUtils.mkdir_p destination # Create the nested directory
        FileUtils.copy_file "#{source}/#{file_name}", "#{destination}/#{file_name}"

        # TOOD: Move this into a method since it is copied from app.rb
        text = File.read("#{destination}/#{file_name}")
        new_contents = text
        replacement_hash.each do |key, value|
          new_contents.gsub!(key, value)
        end
        File.open("#{destination}/#{file_name}", 'w') { |file| file.write(new_contents) }

        puts "Running 'kubectl apply -f #{destination}'"
        system("kubectl apply -f #{destination}")
      end

      # TODO: See https://kubernetes.io/docs/concepts/workloads/controllers/jobs-run-to-completion/ for deleting old pods. As long as
      # we are logging to papertrail or somewhere, we can delete the job when it is done.

      unless detached
        # Check job status until it's finished
        print 'Waiting for job to complete...'
        loop do
          job = JSON.parse(`kubectl --namespace=#{app} get job #{unique_name} -o json`)
          break if job['status']['active'].nil? && !job['status']['succeeded'].nil?
          print '.'
          sleep 1
        end

        if no_delete
          puts "Job finished. Leaving Job object in cluster, clean up manually when confirmed."
        else
          print "Job finished. Deleting Job from cluster for cleanup."
          system("kubectl delete job #{unique_name} -n #{app}")
        end
      end
    end

    def fetch_pods(filters)
      filter_string = filters.map { |k, v| "#{k}=#{v}" }.join(',')
      JSON.parse(`kubectl get pods --namespace=#{app} -o json --selector=#{filter_string}`)['items']
    end

    def connect_to_pod(name, command = 'bash')
      puts "Connecting to #{name}..."
      system("kubectl exec -ti #{name} --namespace=#{app} -- #{command}")
    end
  end
end
