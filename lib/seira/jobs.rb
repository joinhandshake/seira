require 'json'

module Seira
  class Jobs
    include Seira::Commands

    VALID_ACTIONS = %w[help list delete run].freeze
    SUMMARY = "Manage your application's jobs.".freeze
    RESOURCE_SIZES = {
      '1' => {
        'CPU_REQUEST' => '200m',
        'CPU_LIMIT' => '500m',
        'MEMORY_REQUEST' => '500Mi',
        'MEMORY_LIMIT' => '1Gi',
      },
      '2' => {
        'CPU_REQUEST' => '1',
        'CPU_LIMIT' => '2',
        'MEMORY_REQUEST' => '2Gi',
        'MEMORY_LIMIT' => '4Gi',
      },
      '3' => {
        'CPU_REQUEST' => '4',
        'CPU_LIMIT' => '6',
        'MEMORY_REQUEST' => '10Gi',
        'MEMORY_LIMIT' => '15Gi',
      }
    }.freeze

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
      resource_hash = RESOURCE_SIZES['1']

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
          no_delete = true
        elsif arg == '--no-delete'
          no_delete = true
        elsif arg.start_with?('--size=')
          size = arg.split('=')[1]
          resource_hash = RESOURCE_SIZES[size]
        else
          puts "Warning: Unrecognized argument #{arg}"
        end

        args.shift
      end

      existing_job_names = kubectl("get jobs --output=jsonpath={.items..metadata.name}", context: context, clean_output: true, return_output: true).split(" ").map(&:strip).map { |name| name.gsub(/^#{app}-run-/, '') }
      command = args.join(' ')
      unique_name = "#{app}-run-#{Random.unique_name(existing_job_names)}"
      revision = gcp_app.ask_cluster_for_current_revision # TODO: Make more reliable, especially with no web tier
      replacement_hash = {
        'UNIQUE_NAME' => unique_name,
        'REVISION' => revision,
        'JOB_PARALLELISM' => ENV['JOB_PARALLELISM'],
        'COMMAND' => %("sh", "-c", "#{command}")
      }.merge(resource_hash)

      source = "kubernetes/#{context[:cluster]}/#{app}" # TODO: Move to method in app.rb
      Dir.mktmpdir do |destination|
        file_name = discover_job_template_file_name(source)

        FileUtils.mkdir_p destination # Create the nested directory
        FileUtils.copy_file "#{source}/jobs/#{file_name}", "#{destination}/#{file_name}"

        # TOOD: Move this into a method since it is copied from app.rb
        text = File.read("#{destination}/#{file_name}")

        # First run it through ERB if it should be
        if file_name.end_with?('.erb')
          locals = {}.merge(replacement_hash)
          renderer = Seira::Util::ResourceRenderer.new(template: text, context: context, locals: locals)
          text = renderer.render
        end

        new_contents = text
        replacement_hash.each do |key, value|
          new_contents.gsub!(key, value)
        end

        target_name = file_name.gsub('.erb', '')

        File.open("#{destination}/#{target_name}", 'w') { |file| file.write(new_contents) }

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

        # If the job did not succeed, exit nonzero so calling scripts know something went wrong
        exit(1) unless status == "succeeded"
      end
    end

    def discover_job_template_file_name(source)
      if File.exist?("#{source}/jobs/template.yaml.erb")
        "template.yaml.erb"
      else
        "template.yaml"
      end
    end
  end
end
