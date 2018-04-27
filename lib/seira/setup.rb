require 'net/http'
require 'json'

module Seira
  class Setup
    SUMMARY = "Set up your local CLI with the right project and cluster configuration.".freeze

    attr_reader :target, :args, :settings

    def initialize(target:, args:, settings:)
      @target = target
      @args = args
      @settings = settings
    end

    # This script should be all that's needed to fully set up gcloud and kubectl cli, fully configured,
    # on a development machine.
    def run
      ensure_software_installed

      if target == 'status'
        run_status
        exit(0)
      elsif target == 'all'
        puts "We will now set up gcloud and kubectl for each project. We use a distinct GCP Project for each environment, which are specified in .seira.yml."
        settings.valid_cluster_names.each do |cluster|
          setup_cluster(cluster)
        end
      elsif settings.valid_cluster_names.include?(target)
        puts "We will now set up gcloud and kubectl for #{target}"
        setup_cluster(target)
      else
        puts "Please specify a valid cluster name or 'all'. Got #{target}"
        exit(1)
      end

      puts "You have now configured all of your configurations. Please note that 'gcloud' and 'kubectl' are two separate command line tools."
      puts "gcloud: For manipulating GCP entities such as sql databases and kubernetes clusters themselves"
      puts "kubectl: For working within a kubernetes cluster, such as listing pods and deployment statuses"
      puts "Always remember to update both by using 'seira <cluster>', such as 'seira staging'."
      puts "Except for special circumstances, you should be able to always use 'seira' tool and avoid `gcloud` and `kubectl` directly."
      puts "All set!"
    end

    private

    def use_service_account_auth?
      args.include?('--service-account')
    end

    def setup_cluster(cluster_name)
      cluster_metadata = settings.clusters[cluster_name]

      if system("gcloud config configurations describe #{cluster_name}")
        puts "Configuration already exists for #{cluster_name}..."
      else
        puts "Creating configuration for this cluster and activating it..."
        system("gcloud config configurations create #{cluster_name}")
      end

      system("gcloud config configurations activate #{cluster_name}")

      # For automation and scripting, us a service account. For personal CLI use google auth based
      # workflow which is much easier.
      if use_service_account_auth?
        puts "First, set up a service account in the #{cluster_metadata['project']} project and download the credentials for it. You may do so by accessing the below link. Save the file in a safe location."
        puts "https://console.cloud.google.com/iam-admin/serviceaccounts/project?project=#{cluster_metadata['project']}&organizationId=#{settings.organization_id}"
        puts "Then, set up an IAM user that it will inherit the permissions for."

        puts "Please enter the path of your JSON key:"
        filename = STDIN.gets
        puts "Activating service account..."
        system("gcloud auth activate-service-account --key-file #{filename}")
      else
        puts "Authenticating in order to set the auth for project #{cluster_name}. You will be directed to a google login page."
        system("gcloud auth login")
      end

      system("gcloud config set project #{cluster_metadata['project']}")
      system("gcloud config set compute/zone #{settings.default_zone}")
      puts "Your new gcloud setup for #{cluster_name}:"
      system("gcloud config configurations describe #{cluster_name}")

      puts "Configuring kubectl for interactions with this project's kubernetes cluster"
      system("gcloud container clusters get-credentials #{cluster_name} --project #{cluster_metadata['project']}")
      puts "Your kubectl is set up with:"
      system("kubectl config current-context")
    end

    def ensure_software_installed
      puts "Making sure gcloud is installed..."
      unless system('gcloud --version &> /dev/null')
        puts "Installing gcloud..."
        system('curl https://sdk.cloud.google.com | bash')
        system('exec -l $SHELL')
        system('gcloud init')
      end

      puts "Making sure kubectl is installed..."
      unless system('kubectl version &> /dev/null')
        puts "Installing kubectl..."
        system('gcloud components install kubectl')
      end

      puts "Making sure kubernetes-helm is installed..."
      # Only ask for client version since server config may not yet be configured,
      # and in some versions of Helm it hanged.
      unless system('helm version --client &> /dev/null')
        puts "Installing helm..."
        system('brew install kubernetes-helm')
      end
    end

    def run_status
      puts "Your gcloud CLI auths (which can be used for many projects):"
      system("gcloud auth list")
      puts "Your gcloud CLI configurations (which allow for switching between GCP projects):"
      system("gcloud config configurations list")
      puts "Your kubectl contexts (which allow for switching between clusters):"
      system("kubectl config view -o jsonpath='{.contexts[*].name}'")

      puts "Seira is configured using .seira.yml in the root folder."
    end
  end
end
