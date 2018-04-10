require 'json'
require 'base64'
require 'fileutils'

# Example usages:
module Seira
  class Cluster
    include Seira::Commands

    VALID_ACTIONS = %w[help bootstrap upgrade-master].freeze
    SUMMARY = "For managing whole clusters.".freeze

    attr_reader :action, :args, :context, :settings

    def initialize(action:, args:, context:, settings:)
      @action = action
      @args = args
      @context = context
      @settings = settings
    end

    def run
      case action
      when 'help'
        run_help
      when 'bootstrap'
        run_bootstrap
      when 'upgrade-master'
        run_upgrade_master
      else
        fail "Unknown command encountered"
      end
    end

    def switch(target_cluster:, verbose: false)
      unless target_cluster && target_cluster != "" && settings.valid_cluster_names.include?(target_cluster)
        puts "Please specify environment as first param to any seira command"
        puts "Environment should be one of #{settings.valid_cluster_names}"
        exit(1)
      end

      # The context in kubectl are a bit more difficult to name. List by name only and search for the right one using a simple string match
      cluster_metadata = settings.clusters[target_cluster]

      puts("Switching to gcloud config of '#{target_cluster}' and kubernetes cluster of '#{cluster_metadata['cluster']}'") if verbose
      exit(1) unless system("gcloud config configurations activate #{target_cluster}")
      exit(1) unless system("kubectl config use-context #{cluster_metadata['cluster']}")

      # If we haven't exited by now, it was successful
      true
    end

    def self.current_cluster
      Seira::Commands.kubectl("config current-context", context: :none, return_output: true).chomp.strip
    end

    def self.current_project
      Seira::Commands.gcloud("config get-value project", context: :none, return_output: true).chomp.strip
    end

    def current
      puts current_project
      puts current_cluster
    end

    private

    # Intended for use when spinning up a whole new cluster. It stores two main secrets
    # in the default space that are intended to be copied into individual namespaces when
    # new apps are built.
    def run_bootstrap
      dockercfg_location = args[0]
      cloudsql_credentials_location = args[1]

      if dockercfg_location.nil? || dockercfg_location == ''
        puts 'Please specify the dockercfg json key location as first param.'
        exit(1)
      end

      if cloudsql_credentials_location.nil? || cloudsql_credentials_location == ''
        puts 'Please specify the cloudsql_credentials_location json key location as second param.'
        exit(1)
      end

      puts `kubectl create secret docker-registry gcr-secret --docker-username=_json_key --docker-password="$(cat #{dockercfg_location})" --docker-server=https://gcr.io --docker-email=doesnotmatter@example.com`
      puts `kubectl create secret generic cloudsql-credentials --namespace default --from-file=credentials.json=#{cloudsql_credentials_location}`
    end

    def run_upgrade_master
      cluster = context[:cluster]
      new_version = args.first

      # Take a single argument, which is the version to upgrade to
      if new_version.nil?
        puts 'Please specify version to upgrade to'
        exit(1)
      end

      # Ensure the specified version is supported by GKE
      server_config = gcloud("container get-server-config", format: :json, context: context)
      valid_versions = server_config['validMasterVersions']
      unless valid_versions.include? new_version
        puts "Version #{new_version} is unsupported. Supported versions are:"
        puts valid_versions
        exit(1)
      end

      cluster_config = JSON.parse(gcloud("container clusters describe #{cluster}", format: :json, context: context))

      # Update the master node first
      exit(1) unless Highline.agree("Are you sure you want to upgrade cluster #{cluster} master to version #{new_version}? Services should continue to run fine, but the cluster control plane will be offline.")

      puts 'Updating master (this may take a while)'
      if cluster_config['currentMasterVersion'] == new_version
        # Master has already been updated; this step is not needed
        puts 'Already up to date!'
      elsif gcloud("container clusters upgrade #{cluster} --cluster-version=#{new_version} --master", format: :boolean, context: context)
        puts 'Master updated successfully!'
      else
        puts 'Failed to update master.'
        exit(1)
      end
    end
  end
end
