module Seira
  class Proxy
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
