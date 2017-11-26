require 'json'
require 'base64'
require 'fileutils'

# Example usages:
# seira staging specs app bootstrap
module Seira
  class App
    VALID_ACTIONS = %w[bootstrap apply upgrade restart].freeze

    attr_reader :app, :action, :args, :context

    def initialize(app:, action:, args:, context:)
      @app = app
      @action = action
      @args = args
      @context = context
    end

    def run
      case action
      when 'bootstrap'
        run_bootstrap
      when 'apply'
        run_apply
      when 'upgrade'
        run_upgrade
      when 'restart'
        run_restart
      else
        fail "Unknown command encountered"
      end
    end

    def run_restart
      # TODO
    end

    private

    def run_bootstrap
      bootstrap_main_secret
      bootstrap_cloudsql_secret
      bootstrap_gcr_secret

      puts "Successfully installed"
    end

    # Kube vanilla based upgrade
    def run_apply
      destination = "tmp/#{context[:cluster]}/#{app}"
      revision = ENV['REVISION']

      if revision.nil?
        current_image = `kubectl get deployment --namespace=#{app} -l app=#{app},tier=web -o=jsonpath='{$.items[:1].spec.template.spec.containers[:1].image}'`.strip.chomp
        current_revision = current_image.split(':').last
        exit(1) unless HighLine.agree("No REVISION specified. Use current deployment revision '#{current_revision}'?")
        revision = current_revision
      end
      
      replacement_hash = { 'REVISION' => revision }

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
  end
end
