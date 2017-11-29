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
      version = 'POSTGRES_9_6'
      cpu = 1
      memory = 4
      storage = 10

      name = "#{app}-#{Seira::Random.unique_name}"

      command = "gcloud sql instances create #{name}"

      args.each do |arg|
        if arg.start_with? '--version='
          version = arg.split('=')[1]
        elsif arg.start_with? '--cpu='
          cpu = arg.split('=')[1]
        elsif arg.start_with? '--memory='
          memory = arg.split('=')[1]
        elsif arg.start_with? '--storage='
          storage = arg.split('=')[1]
        elsif /^--[\w\-]+=.+$/.match? arg
          command += " #{arg}"
        else
          puts "Warning: Unrecognized argument '#{arg}'"
        end
      end

      command += " --database-version=#{version}"
      command += " --cpu=#{cpu}"
      command += " --memory=#{memory}"
      command += " --storage-size=#{storage}"

      if system(command)
        puts "Successfully created sql instance #{name}"
      else
        puts "Failed to create sql instance"
        exit(1)
      end
    end

    def run_delete
      name = "#{app}-#{args[0]}"
      if system("gcloud sql instances delete #{name}")
        puts "Successfully deleted sql instance #{name}"
      else
        puts "Failed to delete sql instance #{name}"
      end
    end

    def run_list
      puts(`gcloud sql instances list --uri`.split("\n").map { |uri| uri.split('/').last }.select { |name| name.start_with? "#{app}-" })
    end
  end
end
