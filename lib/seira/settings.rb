require 'json'
require 'yaml'

module Seira
  class Settings
    DEFAULT_CONFIG_PATH = '.seira.yml'.freeze
    
    attr_reader :config_path

    def initialize(config_path: DEFAULT_CONFIG_PATH)
      @config_path = config_path
    end

    def settings
      return @_settings if defined?(@_settings)
      @_settings = parse_settings
    end

    def organization_id
      settings['seira']['organization_id']
    end

    def default_zone
      settings['seira']['default_zone']
    end

    def valid_apps
      settings['seira']['valid_apps']
    end

    def valid_cluster_names
      settings['seira']['clusters'].keys
    end

    def clusters
      settings['seira']['clusters']
    end

    def full_cluster_name_for_shorthand(shorthand)
      return shorthand if valid_cluster_names.include?(shorthand)

      # Try iterating through each cluster to find the relevant alias
      clusters.each do |cluster_name, cluster_metadata|
        next if cluster_metadata['aliases'].empty?
        return cluster_name if cluster_metadata['aliases'].include?(shorthand)
      end

      nil
    end

    private

    def parse_settings
      raw_settings = YAML.load_file(config_path)
      puts raw_settings.inspect
      raw_settings
    end
  end
end
