require 'securerandom'

module Seira
  class Db
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
      # We allow overriding the version, so you could specify a mysql version but much of the
      # below assumes postgres for now
      version = 'POSTGRES_9_6'
      cpu = 1 # Number of CPUs
      memory = 4 # GB
      storage = 10 # GB
      set_as_primary = false

      name = "#{app}-#{Seira::Random.unique_name}"

      create_command = "gcloud sql instances create #{name}"

      args.each do |arg|
        if arg.start_with? '--version='
          version = arg.split('=')[1]
        elsif arg.start_with? '--cpu='
          cpu = arg.split('=')[1]
        elsif arg.start_with? '--memory='
          memory = arg.split('=')[1]
        elsif arg.start_with? '--storage='
          storage = arg.split('=')[1]
        elsif arg.start_with? '--set-as-primary='
          set_as_primary = %w[true yes t y].include?(arg.split('=')[1])
        elsif /^--[\w\-]+=.+$/.match? arg
          create_command += " #{arg}"
        else
          puts "Warning: Unrecognized argument '#{arg}'"
        end
      end

      create_command += " --database-version=#{version}"
      create_command += " --cpu=#{cpu}"
      create_command += " --memory=#{memory}"
      create_command += " --storage-size=#{storage}"

      # Create the sql instance with the specified/default parameters
      if system(create_command)
        puts "Successfully created sql instance #{name}"
      else
        puts "Failed to create sql instance"
        exit(1)
      end

      # Set the root user's password to something secure
      root_password = SecureRandom.base64(32)
      if system("gcloud sql users set-password postgres '' --instance=#{name} --password=#{root_password}")
        puts "Set root password to #{root_password}"
      else
        puts "Failed to set root password"
        exit(1)
      end

      # Create proxyuser with secure password
      proxyuser_password = SecureRandom.base64(32)
      if system("gcloud sql users create proxyuser '' --instance=#{name} --password=#{proxyuser_password}")
        puts "Created proxyuser with password #{proxyuser_password}"
      else
        puts "Failed to create proxyuser"
        exit(1)
      end

      # Connect to the instance and remove some of the default group memberships and permissions
      # from proxyuser, leaving it with only what it needs to be able to do
      expect_script = <<~BASH
        set timeout 90
        spawn gcloud sql connect #{name}
        expect "Password for user postgres:"
        send "#{root_password}\\r"
        expect "postgres=>"
        send "REVOKE cloudsqlsuperuser FROM proxyuser;\\r"
        expect "postgres=>"
        send "ALTER ROLE proxyuser NOCREATEDB NOCREATEROLE;\\r"
        expect "postgres=>"
      BASH
      if system("expect <<EOF\n#{expect_script}EOF")
        puts "Successfully removed unnecessary permissions from proxyuser"
      else
        puts "Failed to remove unnecessary permissions from proxyuser"
        exit(1)
      end

      if set_as_primary
        Secrets.new(app: app, action: 'create-pgbouncer-secret', args: ['proxyuser', proxyuser_password], context: context).run
        Secrets.new(app: app, action: 'set', args: ["DATABASE_URL=postgres://proxyuser:#{proxyuser_password}@#{app}-pgbouncer-service:6432"], context: context).run
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
