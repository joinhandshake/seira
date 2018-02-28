require 'json'
require 'highline/import'
require 'colorize'
require 'tmpdir'

require "seira/version"
require 'helpers'
require 'seira/app'
require 'seira/cluster'
require 'seira/memcached'
require 'seira/pods'
require 'seira/jobs'
require 'seira/proxy'
require 'seira/random'
require 'seira/db'
require 'seira/redis'
require 'seira/secrets'
require 'seira/settings'
require 'seira/setup'

# A base runner class that does base checks and then delegates the actual
# work for the command to a class in lib/seira folder.
module Seira
  class Runner
    CATEGORIES = {
      'secrets' => Seira::Secrets,
      'pods' => Seira::Pods,
      'jobs' => Seira::Jobs,
      'db' => Seira::Db,
      'redis' => Seira::Redis,
      'memcached' => Seira::Memcached,
      'app' => Seira::App,
      'cluster' => Seira::Cluster,
      'proxy' => Seira::Proxy,
      'setup' => Seira::Setup
    }.freeze

    attr_reader :project, :cluster, :app, :category, :action, :args
    attr_reader :settings

    # Pop from beginning repeatedly for the first 4 main args, and then take the remaining back to original order for
    # the remaining args
    def initialize
      @settings = Seira::Settings.new

      reversed_args = ARGV.reverse.map(&:chomp)

      # The cluster and proxy command are not specific to any app, so that
      # arg is not in the ARGV array and should be skipped over
      if ARGV[0] == 'help'
        @category = reversed_args.pop
      elsif ARGV[1] == 'cluster'
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

      unless category == 'setup'
        @project = @settings.project_for_cluster(@cluster)
      end
    end

    def run
      if category == 'help'
        run_base_help
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
        default_zone: settings.default_zone
      }
    end

    def base_validations
      # The first arg must always be the cluster. This ensures commands are not run by
      # accident on the wrong kubernetes cluster or gcloud project.
      exit(1) unless Seira::Cluster.new(action: nil, args: nil, context: nil, settings: settings).switch(target_cluster: cluster, verbose: false)
      exit(0) if simple_cluster_change?
    end

    def perform_action_validation(klass:, action:)
      return true if simple_cluster_change?

      unless klass == Seira::Cluster || settings.applications.include?(app)
        puts "Invalid app name specified"
        exit(1)
      end

      unless klass::VALID_ACTIONS.include?(action)
        puts "Invalid action specified. Valid actions are: #{klass::VALID_ACTIONS.join(', ')}"
        exit(1)
      end
    end

    def simple_cluster_change?
      app.nil? && category.nil? # Special case where user is simply changing environments
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
