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

    def applications
      settings['seira']['applications'].map { |app| app['name'] }
    end

    def config_for_app(app_name)
      settings['seira']['applications'].find { |app| app['name'] == app_name }
    end

    def valid_cluster_names
      settings['seira']['clusters'].keys
    end

    def clusters
      settings['seira']['clusters']
    end

    def log_link_format
      settings['seira']['log_link_format']
    end

    def full_cluster_name_for_shorthand(shorthand)
      return shorthand if valid_cluster_names.include?(shorthand)

      # Try iterating through each cluster to find the relevant alias
      clusters.each do |cluster_name, cluster_metadata|
        next if cluster_metadata['aliases'].nil? || cluster_metadata['aliases'].empty?
        return cluster_name if cluster_metadata['aliases'].include?(shorthand)
      end

      nil
    end

    def project_for_cluster(cluster)
      settings['seira']['clusters'][cluster]['project']
    end

    private

    def parse_settings
      YAML.load_file(config_path)
    end
  end
end
