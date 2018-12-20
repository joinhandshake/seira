module Seira
  class Db
    class AlterProxyuserRoles
      include Seira::Commands

      attr_reader :name, :root_password

      def initialize(app:, action:, args:, context:)
        if args.length != 2
          puts 'Specify db name and root password as the positional arguments'
          exit(1)
        end

        @name = args[0]
        @root_password = args[1]
      end

      def run
        # Connect to the instance and remove some of the default group memberships and permissions
        # from proxyuser, leaving it with only what it needs to be able to do
        expect_script = <<~BASH
          set timeout 90
          spawn gcloud sql connect #{name}
          expect "Password for user postgres:"
          send "#{root_password}\\r"
          expect "postgres=>"
          send "ALTER ROLE proxyuser NOCREATEDB NOCREATEROLE;\\r"
          expect "postgres=>"
        BASH
        if system("expect <<EOF\n#{expect_script}EOF")
          puts "Successfully removed unnecessary permissions from proxyuser"
        else
          puts "Failed to remove unnecessary permissions from proxyuser."
          puts "You may need to whitelist the correct IP in the gcloud UI."
          puts "You can get the correct IP from https://www.whatismyip.com/"
          puts "Make sure to remove it from the whitelist after successfully running db alter-proxyuser-roles"
          exit(1)
        end
      end
    end
  end
end
