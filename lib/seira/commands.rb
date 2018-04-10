require 'seira/commands/kubectl'
require 'seira/commands/gcloud'

module Seira
  module Commands
    def kubectl(command, context:, clean_output: false, return_output: false)
      Seira::Commands.kubectl(command, context: context, clean_output: clean_output, return_output: return_output)
    end

    def self.kubectl(command, context:, clean_output: false, return_output: false)
      Kubectl.new(command, context: context).invoke(clean_output: clean_output, return_output: return_output)
    end

    def gcloud(command, context:, clean_output: false, format: :boolean)
      Seira::Commands.gcloud(command, context: context, clean_output: clean_output, format: format)
    end

    def self.gcloud(command, context:, clean_output: false, format: :boolean)
      Gcloud.new(command, context: context, clean_output: clean_output, format: format).invoke
    end
  end
end