module Seira
  class Proxy
    SUMMARY = "Open up the proxy UI for a given cluster.".freeze

    def initialize
    end

    def run
      begin
        system("kubectl proxy")
      rescue
      end
    end
  end
end
