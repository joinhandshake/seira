module Seira
  class Proxy
    include Seira::Commands

    SUMMARY = "Open up the proxy UI for a given cluster.".freeze

    def initialize
    end

    def run
      begin
        kubectl("proxy", context: :none)
      rescue
      end
    end
  end
end
