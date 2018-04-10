require 'seira/commands/kubectl'

module Seira
  module Commands
    def kubectl(command, context:, clean_output: false, return_output: false)
      Seira::Commands.kubectl(command, context: context, clean_output: clean_output, return_output: return_output)
    end

    def self.kubectl(command, context:, clean_output: false, return_output: false)
      Kubectl.new(command, context: context).invoke(clean_output: clean_output, return_output: return_output)
    end

    def gcloud(command, context:, clean_output: false, return_output: false)
      Seira::Commands.gcloud(command, context: context, clean_output: clean_output, return_output: return_output)
    end

    def self.gcloud(command, context:, clean_output: false, return_output: false)
      Gcloud.new(command, context: context).invoke(clean_output: clean_output, return_output: return_output)
    end
  end
end