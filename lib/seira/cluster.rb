require 'json'
require 'base64'
require 'fileutils'

# Example usages:
module Seira
  class Cluster
    VALID_ACTIONS = %w[help bootstrap upgrade].freeze
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
      when 'upgrade'
        run_upgrade
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
      `kubectl config current-context`.chomp.strip
    end

    def current
      puts `gcloud config get-value project`
      puts `kubectl config current-context`
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

      # puts `kubectl create secret generic gcr-secret --namespace default --from-file=.dockercfg=#{dockercfg_location}`
      puts `kubectl create secret docker-registry gcr-secret --docker-username=_json_key --docker-password="$(cat #{dockercfg_location})" --docker-server=https://gcr.io --docker-email=doesnotmatter@example.com`
      puts `kubectl create secret generic cloudsql-credentials --namespace default --from-file=credentials.json=#{cloudsql_credentials_location}`
    end

    def run_upgrade
      cluster = context[:cluster]
      new_version = args[0]
      if new_version.nil?
        puts 'must specify version to upgrade to'
        exit(1)
      end

      server_config = JSON.parse(`gcloud container get-server-config --format json`)
      valid_versions = server_config['validMasterVersions']
      unless valid_versions.include? new_version
        puts "Version #{new_version} is unsupported. Supported versions are:"
        puts valid_versions
        exit(1)
      end

      cluster_config = JSON.parse(`gcloud container clusters describe #{cluster} --format json`)

      puts 'updating master'
      if cluster_config['currentMasterVersion'] == new_version
        puts 'already up to date'
      elsif system("gcloud container clusters upgrade #{cluster} --cluster-version=#{new_version} --master")
        puts 'master updated successfully'
      else
        puts 'failed to update master'
        exit(1)
      end

      pools = JSON.parse(`gcloud container node-pools list --cluster #{cluster} --format json`)
      if pools.length == 2
        old_pool = pools.find { |p| p['version'] != new_version }
        new_pool = pools.find { |p| p['version'] == new_version }
        if old_pool.nil? || new_pool.nil?
          puts 'Unsupported node pool setup: could not find old and new pool'
          exit(1)
        end
      elsif pools.length == 1
        old_pool = pools.first
      else
        puts 'Unsupported node pool setup: unexpected number of pools'
        exit(1)
      end
      old_nodes = `kubectl get nodes -l cloud.google.com/gke-nodepool=#{old_pool['name']} -o name`.split("\n")

      if new_pool.nil?
        new_pool_name = old_pool['name'] == 'blue' ? 'green' : 'blue'

        puts 'creating new node pool'
        command =
          "gcloud container node-pools create #{new_pool_name} \
          --cluster=#{cluster} \
          --disk-size=#{old_pool['config']['diskSizeGb']} \
          --image-type=#{old_pool['config']['imageType']} \
          --machine-type=#{old_pool['config']['machineType']} \
          --num-nodes=#{old_nodes.count} \
          --service-account=#{old_pool['serviceAccount']}"
        # TODO: support autoscaling if old pool has it turned on
        if system(command)
          puts 'new pool created successfully'
        else
          puts 'failed to create new pool'
          exit(1)
        end
      end

      puts 'cordoning old nodes'
      old_nodes.each do |node|
        unless system("kubectl cordon #{node}")
          puts "failed to cordon node #{node}"
          exit(1)
        end
      end

      puts 'draining old nodes'
      old_nodes.each do |node|
        unless system("kubectl drain --force --ignore-daemonsets --delete-local-data #{node}")
          puts "failed to drain node #{node}"
          exit(1)
        end
      end

      puts 'deleting old node pool'
      if system("gcloud container node-pools delete #{old_pool['name']} --cluster #{cluster}")
        puts 'old pool deleted successfully'
      else
        puts 'failed to delete old pool'
        exit(1)
      end

      puts 'upgrade complete!'
    end
  end
end
