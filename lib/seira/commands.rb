require 'commands/kubectl'

module Seira
  module Commands
    def kubectl(command, context:)
      Kubectl.new(command, context: context).invoke
    end
  end
end