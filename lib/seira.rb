require 'json'
require 'highline/import'
require 'colorize'
require 'tmpdir'

require 'seira/commands'

require "seira/version"
require 'helpers'
require 'seira/app'
require 'seira/config'
require 'seira/cluster'
require 'seira/pods'
require 'seira/jobs'
require 'seira/proxy'
require 'seira/random'
require 'seira/db'
require 'seira/secrets'
require 'seira/settings'
require 'seira/setup'
require 'seira/node_pools'
require 'seira/util/resource_renderer'

# A base runner class that does base checks and then delegates the actual
# work for the command to a class in lib/seira folder.
module Seira
  class Runner
    include Seira::Commands

    CATEGORIES = {
      'secrets' => Seira::Secrets,
      'config' => Seira::Config,
      'pods' => Seira::Pods,
      'jobs' => Seira::Jobs,
      'db' => Seira::Db,
      'app' => Seira::App,
      'cluster' => Seira::Cluster,
      'proxy' => Seira::Proxy,
      'setup' => Seira::Setup,
      'node-pools' => Seira::NodePools
    }.freeze

    attr_reader :project, :cluster, :app, :category, :action, :args
    attr_reader :settings

    # Pop from beginning repeatedly for the first 4 main args, and then take the remaining back to original order for
    # the remaining args
    def initialize
      @settings = Seira::Settings.new

      reversed_args = ARGV.reverse.map(&:chomp)

      # The cluster, node-pools and proxy command are not specific to any app, so that
      # arg is not in the ARGV array and should be skipped over
      if ARGV[0] == 'help'
        @category = reversed_args.pop
      elsif ARGV[0] == 'version'
        @category = reversed_args.pop
      elsif ARGV[1] == 'cluster'
        cluster = reversed_args.pop
        @category = reversed_args.pop
        @action = reversed_args.pop
        @args = reversed_args.reverse
      elsif ARGV[1] == 'node-pools'
        cluster = reversed_args.pop
        @category = reversed_args.pop
        @action = reversed_args.pop
        @args = reversed_args.reverse
      elsif ARGV[1] == 'proxy'
        cluster = reversed_args.pop
        @category = reversed_args.pop
      elsif ARGV[0] == 'setup'
        @category = reversed_args.pop
        cluster = reversed_args.pop
        @args = reversed_args.reverse
      else
        cluster = reversed_args.pop
        @app = reversed_args.pop
        @category = reversed_args.pop
        @action = reversed_args.pop
        @args = reversed_args.reverse
      end

      @cluster =
        if category == 'setup'
          cluster
        else
          @settings.full_cluster_name_for_shorthand(cluster)
        end

      # If cluster is nil, we'll show an error message later on.
      unless @cluster.nil?
        unless category == 'setup'
          @project = @settings.project_for_cluster(@cluster)
        end
      end
    end

    def run
      if category == 'help'
        run_base_help
        exit(0)
      elsif category == 'version'
        puts "Seira version: #{Seira::VERSION}"
        exit(0)
      elsif category == 'setup'
        Seira::Setup.new(target: cluster, args: args, settings: settings).run
        exit(0)
      end

      base_validations

      command_class = CATEGORIES[category]

      unless command_class
        puts "Unknown command specified. Usage: 'seira <cluster> <app> <category> <action> <args..>'."
        puts "Valid categories are: #{CATEGORIES.keys.join(', ')}"
        exit(1)
      end

      if category == 'cluster'
        perform_action_validation(klass: command_class, action: action)
        command_class.new(action: action, args: args, context: passed_context, settings: settings).run
      elsif category == 'node-pools'
        perform_action_validation(klass: command_class, action: action)
        command_class.new(action: action, args: args, context: passed_context, settings: settings).run
      elsif category == 'proxy'
        command_class.new.run
      else
        perform_action_validation(klass: command_class, action: action)
        command_class.new(app: app, action: action, args: args, context: passed_context).run
      end
    end

    private

    def passed_context
      {
        cluster: cluster,
        project: project,
        settings: settings,
        region: settings.region_for_cluster(cluster),
        zone: settings.zone_for_cluster(cluster),
        app: app,
        action: action,
        args: args
      }
    end

    def base_validations
      # gcloud and kubectl is required, hard error if not installed
      unless system("gcloud version > /dev/null 2>&1")
        puts "Gcloud library not installed properly. Please install `gcloud` before using seira.".red
        exit(1)
      end

      unless system("kubectl version --client > /dev/null 2>&1")
        puts "Kubectl library not installed properly. Please install `kubectl` before using seira.".red
        exit(1)
      end

      # The first arg must always be the cluster. This ensures commands are not run by
      # accident on the wrong kubernetes cluster or gcloud project.
      exit(1) unless Seira::Cluster.new(action: nil, args: nil, context: nil, settings: settings).switch(target_cluster: cluster, verbose: false)
      exit(0) if simple_cluster_change?
    end

    def perform_action_validation(klass:, action:)
      return true if simple_cluster_change?

      unless klass == Seira::Cluster || klass == Seira::NodePools || settings.applications.include?(app)
        puts "Invalid app name specified"
        exit(1)
      end

      unless klass::VALID_ACTIONS.include?(action)
        puts "Invalid action specified. Valid actions are: #{klass::VALID_ACTIONS.join(', ')}"
        exit(1)
      end
    end

    def simple_cluster_change?
      app.nil? && category.nil? # Special case where user is simply changing clusters
    end

    def run_base_help
      puts 'Seira is a library for managing Kubernetes as a PaaS.'
      puts 'All commands take the following form: `seira <cluster-name> <app-name> <category> <action> <args...>`'
      puts 'For example, `seira staging foo-app secrets list`'
      puts "Possible categories: \n\n"
      CATEGORIES.each do |key, klass|
        puts "#{key}: #{klass::SUMMARY}"
      end
      puts "\nTo get more help for a specific category, run `seira <cluster-name> <app-name> <category> help` command"
    end
  end
end
