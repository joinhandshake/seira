module Seira
  class Sql
    VALID_ACTIONS = %w[create delete list].freeze

    attr_reader :app, :action, :args, :context

    def initialize(app:, action:, args:, context:)
      @app = app
      @action = action
      @args = args
      @context = context
    end

    def run
      case action
      when 'create'
        run_create
      when 'delete'
        run_delete
      when 'list'
        run_list
      else
        fail "Unknown command encountered"
      end
    end

    private

    def run_create
      name = "#{app}-#{Seira::Random.unique_name}"
      command = "gcloud sql instances create #{name}"
    end

    def run_delete
    end

    def run_list
      puts(`gcloud sql instances list --uri`.split("\n").map { |uri| uri.split('/').last }.select { |name| name.start_with? "#{app}-" })
    end
  end
end
