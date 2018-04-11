require 'json'

module Seira
  class Jobs
    include Seira::Commands

    VALID_ACTIONS = %w[help list delete run].freeze
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
      kubectl("get jobs -o wide", context: context)
    end

    def run_delete
      kubectl("delete job #{job_name}", context: context)
    end

    def run_run
      gcp_app = App.new(app: app, action: 'apply', args: [""], context: context)

      # Set defaults
      async = false # Wait for job to finish before continuing.
      no_delete = false # Delete at end

      # Loop through args and process any that aren't just the command to run
      loop do
        arg = args.first
        if arg.nil?
          puts 'Please specify a command to run'
          exit(1)
        end

        break unless arg.start_with? '--'

        if arg == '--async'
          async = true
        elsif arg == '--no-delete'
          no_delete = true
        else
          puts "Warning: Unrecognized argument #{arg}"
        end

        args.shift
      end

      if async && !no_delete
        puts "Cannot delete Job after running if Job is async, since we don't know when it finishes."
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
        file_name = "template.yaml"

        FileUtils.mkdir_p destination # Create the nested directory
        FileUtils.copy_file "#{source}/jobs/#{file_name}", "#{destination}/#{file_name}"

        # TOOD: Move this into a method since it is copied from app.rb
        text = File.read("#{destination}/#{file_name}")
        new_contents = text
        replacement_hash.each do |key, value|
          new_contents.gsub!(key, value)
        end
        File.open("#{destination}/#{file_name}", 'w') { |file| file.write(new_contents) }

        kubectl("apply -f #{destination}", context: context)
        log_link = Helpers.log_link(context: context, query: unique_name)
        puts "View logs at: #{log_link}" unless log_link.nil?
      end

      unless async
        # Check job status until it's finished
        print 'Waiting for job to complete...'
        job_spec = nil
        loop do
          job_spec = JSON.parse(kubectl("get job #{unique_name} -o json", context: context, return_output: true, clean_output: true))
          break if !job_spec['status']['succeeded'].nil? || !job_spec['status']['failed'].nil?
          print '.'
          sleep 3
        end

        status =
          if !job_spec['status']['succeeded'].nil?
            "succeeded"
          elsif !job_spec['status']['failed'].nil?
            "failed"
          else
            "unknown"
          end

        if no_delete
          puts "Job finished with status #{status}. Leaving Job object in cluster, clean up manually when confirmed."
        else
          print "Job finished with status #{status}. Deleting Job from cluster for cleanup."
          kubectl("delete job #{unique_name}", context: context)
        end
      end
    end
  end
end
