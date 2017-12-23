require 'json'
require 'base64'
require 'fileutils'

# Example usages:
# seira staging specs app bootstrap
module Seira
  class App
    VALID_ACTIONS = %w[help bootstrap apply restart scale].freeze
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
      else
        fail "Unknown command encountered"
      end
    end

    def run_help
      puts SUMMARY
      puts "\n\n"
      puts "Possible actions:\n\n"
      puts "bootstrap: Create new app with main secret, cloudsql secret, and gcr secret in the new namespace."
      puts "apply: Apply the configuration in kubernetes/<cluster-name>/<app-name> using REVISION environment variable to find/replace REVISION in the YAML."
      puts "restart: TODO."
      puts "scale: Scales the given tier deployment to the specified number of instances."
    end

    def run_restart
      run_apply(restart: true)
    end

    private

    def run_bootstrap
      bootstrap_main_secret
      bootstrap_cloudsql_secret
      bootstrap_gcr_secret

      puts "Successfully installed"
    end

    # Kube vanilla based upgrade
    def run_apply(restart: false)
      destination = "tmp/#{context[:cluster]}/#{app}"
      revision = ENV['REVISION']

      if revision.nil?
        current_image = `kubectl get deployment --namespace=#{app} -l app=#{app},tier=web -o=jsonpath='{$.items[:1].spec.template.spec.containers[:1].image}'`.strip.chomp
        current_revision = current_image.split(':').last
        exit(1) unless HighLine.agree("No REVISION specified. Use current deployment revision '#{current_revision}'?")
        revision = current_revision
      end

      replacement_hash = { 'REVISION' => revision }

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

      puts "Running 'kubectl apply -f #{destination}'"
      system("kubectl apply -f #{destination}")
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
        system("kubectl scale --namespace=#{app} --replicas=#{replicas} deployments/#{config['metadata']['name']}")
      end
    end

    def bootstrap_main_secret
      puts "Creating main secret and namespace..."
      main_secret_name = Seira::Secrets.new(app: app, action: action, args: args, context: context).main_secret_name

      # 'internal' is a unique cluster/project "cluster". It always means production in terms of rails app.
      rails_env =
        if context[:cluster] == 'internal'
          'production'
        else
          context[:cluster]
        end

      puts `kubectl create secret generic #{main_secret_name} --namespace #{app} --from-literal=RAILS_ENV=#{rails_env} --from-literal=RACK_ENV=#{rails_env}`
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
      puts "Copying source yaml from #{source} to #{destination}"
      FileUtils::mkdir_p destination # Create the nested directory
      FileUtils.copy_entry source, destination

      # Iterate through each yaml file and find/replace and save
      puts "Iterating #{destination} files find/replace revision information"
      Dir.foreach(destination) do |item|
        next if item == '.' || item == '..'

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
        next if ['.', '..'].include? filename
        YAML.load_stream(File.read(File.join(directory, filename)))
      end.compact
    end
  end
end
