require 'json'
require 'base64'
require 'fileutils'

# Example usages:
module Seira
  class NodePools
    VALID_ACTIONS = %w[help list list-nodes add cordon drain delete].freeze
    SUMMARY = "For managing node pools for a cluster.".freeze

    attr_reader :action, :args, :context, :settings

    def initialize(action:, args:, context:, settings:)
      @action = action
      @args = args
      @context = context
      @settings = settings
    end

    def run
      case action
      when 'help'
        run_help
      when 'list'
        run_list
      when 'list-nodes'
        run_list_nodes
      when 'add'
        run_add
      when 'cordon'
        run_cordon
      when 'drain'
        run_drain
      when 'delete'
        run_delete
      else
        fail "Unknown command encountered"
      end
    end

    private

    def run_help
      puts SUMMARY
      puts "\n\n"
      puts "Possible actions:\n\n"
      puts "list: List the node pools for this cluster: `node-pools list`"
      puts "list-nodes: List the nodes in specified node pool: `node-pools list-nodes <node-pool-name>`"
      puts "add: Create a node pool. First arg is the name to use, and use --copy to specify the existing node pool to copy."
      puts "     `node-pools add <node-pool-name> --copy=<existing-node-pool-name>`"
      puts "cordon: Cordon nodes in specified node pool: `node-pools cordon <node-pool-name>`"
      puts "drain: Drain all pods from specified node pool:  `node-pools drain <node-pool-name>`"
      puts "delete: Delete a node pool. Will force-run cordon and drain, first:  `node-pools delete <node-pool-name>`"
    end

    # TODO: Info about what is running on it?
    # TODO: What information do we get in the json format we could include here?
    def run_list
      puts `gcloud container node-pools list --cluster #{context[:cluster]}`
    end

    def run_list_nodes
      puts nodes_for_pool(args.first)
    end

    def run_add
      new_pool_name = args.shift
      disk_size = nil
      image_type = nil
      machine_type = nil
      service_account = nil
      num_nodes = nil

      args.each do |arg|
        if arg.start_with? '--copy='
          node_pool_name_to_copy = arg.split('=')[1]
          node_pool_to_copy = node_pools.find { |p| p['name'] == node_pool_name_to_copy }

          fail "Could not find node pool with name #{node_pool_name_to_copy} to copy from." if node_pool_to_copy.nil?

          disk_size = node_pool_to_copy['config']['diskSizeGb']
          image_type = node_pool_to_copy['config']['imageType']
          machine_type = node_pool_to_copy['config']['machineType']
          service_account = node_pool_to_copy['serviceAccount']
          num_nodes = nodes_for_pool(node_pool_name_to_copy).count
        else
          puts "Warning: Unrecognized argument '#{arg}'"
        end
      end

      command =
        "gcloud container node-pools create #{new_pool_name} \
        --cluster=#{context[:cluster]} \
        --disk-size=#{disk_size} \
        --image-type=#{image_type} \
        --machine-type=#{machine_type} \
        --num-nodes=#{num_nodes} \
        --service-account=#{service_account}"

      if system(command)
        puts 'New pool created successfully'
      else
        puts 'Failed to create new pool'
        exit(1)
      end
    end

    def run_cordon
      fail_if_lone_node_pool

      node_pool_name = args.first
      nodes = nodes_for_pool(node_pool_name)

      nodes.each do |node|
        unless system("kubectl cordon #{node}")
          puts "Failed to cordon node #{node}"
          exit(1)
        end
      end

      puts "Successfully cordoned node pool #{node_pool_name}. No new workloads will be placed on #{node_pool_name} nodes."
    end

    def run_drain
      fail_if_lone_node_pool

      node_pool_name = args.first
      nodes = nodes_for_pool(node_pool_name)

      nodes.each do |node|
        # --force deletes pods that aren't managed by a ReplicationController, Job, or DaemonSet,
        #   which shouldn't be any besides manually created temp pods
        # --ignore-daemonsets prevents failing due to presence of DaemonSets, which cannot be moved
        #   because they're tied to a specific node
        # --delete-local-data prevents failing due to presence of local data, which cannot be moved
        #   but is bad practice to use for anything that can't be lost
        puts "Draining #{node}"
        unless system("kubectl drain --force --ignore-daemonsets --delete-local-data #{node}")
          puts "Failed to drain node #{node}"
          exit(1)
        end
      end

      puts "Successfully drained all nodes in node pool #{node_pool_name}. No pods are running on #{node_pool_name} nodes."
    end

    def run_delete
      fail_if_lone_node_pool

      node_pool_name = args.first

      puts "Running cordon and drain as a safety measure first. If you haven't run these yet, please do so separately before deleting this node pool."
      run_cordon
      run_drain

      exit(1) unless HighLine.agree "Node pool has successfully been cordoned and drained, and should be safe to delete. Continue deleting node pool #{node_pool_name}?"

      if system("gcloud container node-pools delete #{node_pool_name} --cluster #{context[:cluster]}")
        puts 'Node pool deleted successfully'
      else
        puts 'Failed to delete old pool'
        exit(1)
      end
    end

    # TODO: Represent by a ruby object?
    def node_pools
      JSON.parse(`gcloud container node-pools list --cluster #{context[:cluster]} --format json`)
    end

    def nodes_for_pool(pool_name)
      `kubectl get nodes -l cloud.google.com/gke-nodepool=#{pool_name} -o name`.split("\n")
    end

    def fail_if_lone_node_pool
      return if node_pools.count > 1

      puts "Operation is unsafe to run with only one node pool. Please add a new node pool first to ensure services in cluster can continue running."
      exit(1)
    end
  end
end
