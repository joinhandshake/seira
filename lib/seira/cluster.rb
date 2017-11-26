#!/usr/bin/env ruby

require 'dotenv/load'
require 'json'
require "base64"
require 'fileutils'

# Example usages:
module Seira
  class Cluster
    VALID_ACTIONS = %w[bootstrap].freeze

    attr_reader :action, :args, :context, :settings

    def initialize(action:, args:, context:, settings:)
      @action = action
      @args = args
      @context = context
      @settings = settings
    end

    def run
      case action
      when 'bootstrap'
        run_bootstrap
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
  end
end
