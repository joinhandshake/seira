module Seira
  class Db
    class Ps
      attr_reader :app, :action, :primary_instance, :instance, :args, :context

      def initialize(app:, action:, args:, context:)
        @app = app
        @action = action
        @args = args
        @context = context

        @primary_instance = Seira::Db.new(app: app, action: action, args: args, context: context).primary_instance
        @instance = args[0] || @primary_instance
      end

      def run
        num = rand
        waiting_marker = "#{num}#{num}"

        root_password = Secrets.new(app: app, action: 'get', args: [], context: context).get("#{primary_instance.tr('-', '_',).upcase}_ROOT_PASSWORD")

        expect_script = <<~BASH
          set timeout 90
          spawn gcloud sql connect #{instance}
          expect "Password for user postgres:"
          send "#{root_password}\\r"
          expect "postgres=>"
          send "#{query(verbose: true, waiting: 'nil')};\\r"
          expect "postgres=>"
        BASH

        unless system("expect <<EOF\n#{expect_script}EOF")
          exit(1)
        end

        # waiting_output = psql.exec(db, waitingQuery)
        # waiting = waiting_output.includes(waiting_marker) ? 'waiting' : 'wait_event IS NOT NULL AS waiting'
      
        #   expect_script = <<~BASH
        #   set timeout 90
        #   spawn gcloud sql connect #{instance}
        #   expect "Password for user postgres:"
        #   send "#{root_password}\\r"
        #   expect "postgres=>"
        #   send "#{waiting_query(num)};\\r"
        #   expect "postgres=>"
        # BASH
      end

      private

      def waiting_query(num)
        """SELECT '#{num}' || '#{num}' WHERE EXISTS (
          SELECT 1 FROM information_schema.columns WHERE table_schema = 'pg_catalog'
            AND table_name = 'pg_stat_activity'
            AND column_name = 'waiting'
        )"""
      end

      def query(verbose: false, waiting:)
        """
        SELECT
         pid,
         state,
         application_name AS source,
         usename AS username,
         age(now(),xact_start) AS running_for,
         xact_start AS transaction_start,
         query
        FROM pg_stat_activity
        WHERE
         query <> '<insufficient privilege>'
         #{verbose ? '' : "AND state <> 'idle'"}
         AND pid <> pg_backend_pid()
         ORDER BY query_start DESC
        """
      end
    end
  end
end
