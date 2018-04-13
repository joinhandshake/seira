require 'json'
require 'base64'
require 'fileutils'

# Example usages:
# seira staging specs app bootstrap
module Seira
  class App
    include Seira::Commands

    VALID_ACTIONS = %w[help bootstrap apply restart scale revision].freeze
    SUMMARY = "Bootstrap, scale, configure, restart, your apps.".freeze

    attr_reader :app, :action, :args, :context

    def initialize(app:, action:, args:, context:)
      @app = app
      @action = action
      @args = args
      @context = context
    end

    def run
      case action
      when 'help'
        run_help
      when 'bootstrap'
        run_bootstrap
      when 'apply'
        run_apply
      when 'restart'
        run_restart
      when 'scale'
        run_scale
      when 'revision'
        run_revision
      else
        fail "Unknown command encountered"
      end
    end

    def run_help
      puts SUMMARY
      puts "\n\n"
      puts "Possible actions:\n\n"
      puts "bootstrap: Create new app with main secret, cloudsql secret, and gcr secret in the new namespace."
      puts "apply: Apply the configuration in kubernetes/<cluster-name>/<app-name> using first argument or REVISION environment variable to find/replace REVISION in the YAML."
      puts "restart: Forces a rolling deploy for any deployment making use of RESTARTED_AT_VALUE in the deployment."
      puts "scale: Scales the given tier deployment to the specified number of instances."
    end

    def run_restart
      run_apply(restart: true)
    end

    def ask_cluster_for_current_revision
      tier = context[:settings].config_for_app(app)['golden_tier'] || 'web'
      current_image = kubectl("get deployment -l app=#{app},tier=#{tier} -o=jsonpath='{$.items[:1].spec.template.spec.containers[:1].image}'", context: context, return_output: true).strip.chomp
      current_revision = current_image.split(':').last
      current_revision
    end

    private

    def run_bootstrap
      # TODO: Verify that 00-namespace exists
      # TODO: Do conformance test on the yaml files before running anything, including that 00-namespace.yaml exists and has right name
      # Create namespace before anything else
      kubectl("apply -f kubernetes/#{context[:cluster]}/#{app}/00-namespace.yaml", context: context)
      bootstrap_main_secret
      bootstrap_cloudsql_secret
      bootstrap_gcr_secret

      puts "Successfully installed"
    end

    # Kube vanilla based upgrade
    def run_apply(restart: false)
      async = false
      revision = nil
      deployment = :all

      args.each do |arg|
        if arg == '--async'
          async = true
        elsif arg.start_with? '--deployment='
          deployment = arg.split('=')[1]
        elsif revision.nil?
          revision = arg
        else
          puts "Warning: unrecognized argument #{arg}"
        end
      end

      Dir.mktmpdir do |dir|
        destination = "#{dir}/#{context[:cluster]}/#{app}"
        revision ||= ENV['REVISION']

        if revision.nil?
          current_revision = ask_cluster_for_current_revision
          exit(1) unless HighLine.agree("No REVISION specified. Use current deployment revision '#{current_revision}'?")
          revision = current_revision
        end

        replacement_hash = {
          'REVISION' => revision,
          'RESTARTED_AT_VALUE' => "Initial Deploy for #{revision}"
        }

        if restart
          replacement_hash['RESTARTED_AT_VALUE'] = Time.now.to_s
        end

        replacement_hash.each do |k, v|
          next unless v.nil? || v == ''
          puts "Found nil or blank value for replacement hash key #{k}. Aborting!"
          exit(1)
        end

        find_and_replace_revision(
          source: "kubernetes/#{context[:cluster]}/#{app}",
          destination: destination,
          replacement_hash: replacement_hash
        )

        to_apply = destination
        to_apply += "/#{deployment}.yaml" unless deployment == :all
        kubectl("apply -f #{to_apply}", context: context)

        unless async
          puts "Monitoring rollout status..."
          # Wait for rollout of all deployments to complete (running `kubectl rollout status` in parallel via xargs)
          rollout_wait_command =
            if deployment == :all
              "kubectl get deployments -n #{app} -o name | xargs -n1 -P10 kubectl rollout status -n #{app}"
            else
              "kubectl rollout status -n #{app} deployments/#{app}-#{deployment}"
            end
          exit 1 unless system(rollout_wait_command)
        end
      end
    end

    def run_scale
      scales = key_value_map.dup
      configs = load_configs

      if scales.key? 'all'
        configs.each do |config|
          next unless config['kind'] == 'Deployment'
          scales[config['metadata']['labels']['tier']] ||= scales['all']
        end
        scales.delete 'all'
      end

      scales.each do |tier, replicas|
        config = configs.find { |c| c['kind'] == 'Deployment' && c['metadata']['labels']['tier'] == tier }
        if config.nil?
          puts "Warning: could not find config for tier #{tier}"
          next
        end
        replicas = config['spec']['replicas'] if replicas == 'default'
        puts "scaling #{tier} to #{replicas}"
        kubectl("scale --replicas=#{replicas} deployments/#{config['metadata']['name']}", context: context)
      end
    end

    def run_revision
      puts ask_cluster_for_current_revision
    end

    def bootstrap_main_secret
      puts "Creating main secret and namespace..."
      main_secret_name = Seira::Secrets.new(app: app, action: action, args: args, context: context).main_secret_name

      # 'internal' is a unique cluster/project "cluster". It always means production in terms of rails app.
      rails_env = Helpers.rails_env(context: context)

      kubectl("create secret generic #{main_secret_name} --from-literal=RAILS_ENV=#{rails_env} --from-literal=RACK_ENV=#{rails_env}", context: context)
    end

    # We use a secret in our container to use a service account to connect to our cloudsql databases. The secret in 'default'
    # namespace can't be used in this namespace, so copy it over to our namespace.
    def bootstrap_gcr_secret
      secrets = Seira::Secrets.new(app: app, action: action, args: args, context: context)
      secrets.copy_secret_across_namespace(key: 'gcr-secret', from: 'default', to: app)
    end

    # We use a secret in our container to use a service account to connect to our docker registry. The secret in 'default'
    # namespace can't be used in this namespace, so copy it over to our namespace.
    def bootstrap_cloudsql_secret
      secrets = Seira::Secrets.new(app: app, action: action, args: args, context: context)
      secrets.copy_secret_across_namespace(key: 'cloudsql-credentials', from: 'default', to: app)
    end

    def find_and_replace_revision(source:, destination:, replacement_hash:)
      puts "Copying source yaml from #{source} to temp folder"
      FileUtils.mkdir_p destination # Create the nested directory
      FileUtils.rm_rf("#{destination}/.", secure: true) # Clean out old files from the tmp folder
      FileUtils.copy_entry source, destination
      # Anything in jobs directory is not intended to be applied when deploying
      # the app, but rather ran when needed as Job objects. Force to avoid exception if DNE.
      FileUtils.rm_rf("#{destination}/jobs/") if File.directory?("#{destination}/jobs/")

      # Iterate through each yaml file and find/replace and save
      puts "Iterating temp folder files find/replace revision information"
      Dir.foreach(destination) do |item|
        next if item == '.' || item == '..'

        # If we have run into a directory item, skip it
        next if File.directory?("#{destination}/#{item}")

        # Skip any manifest file that has "seira-skip.yaml" at the end. Common use case is for Job definitions
        # to be used in "seira staging <app> jobs run"
        next if item.end_with?("seira-skip.yaml")

        text = File.read("#{destination}/#{item}")

        new_contents = text
        replacement_hash.each do |key, value|
          new_contents.gsub!(key, value)
        end

        # To write changes to the file, use:
        File.open("#{destination}/#{item}", 'w') { |file| file.write(new_contents) }
      end
    end

    # TODO(josh): factor out and share this method with similar commands (e.g. `secrets set`)
    def key_value_map
      args.map do |arg|
        equals_index = arg.index('=')
        [arg[0..equals_index - 1], arg[equals_index + 1..-1]]
      end.to_h
    end

    def load_configs
      directory = "kubernetes/#{context[:cluster]}/#{app}/"
      Dir.new(directory).flat_map do |filename|
        next if File.directory?(File.join(directory, filename))
        YAML.load_stream(File.read(File.join(directory, filename)))
      end.compact
    end
  end
end
