require 'net/http'
require 'json'

module Seira
  class Setup
    SUMMARY = "Set up your local CLI with the right project and cluster configuration.".freeze

    attr_reader :arg, :settings

    def initialize(arg:, settings:)
      @arg = arg
      @settings = settings
    end

    # This script should be all that's needed to fully set up gcloud and kubectl cli, fully configured,
    # on a development machine.
    def run
      ensure_software_installed

      if arg == 'all'
        puts "We will now set up gcloud and kubectl for each project. We use a distinct GCP Project for each environment, which are specified in .seira.yml."
        settings.valid_cluster_names.each do |cluster|
          setup_cluster(cluster)
        end
      elsif settings.valid_cluster_names.include?(arg)
        puts "We will now set up gcloud and kubectl for #{arg}"
        setup_cluster(arg)
      else
        puts "Please specify a valid cluster name or 'all'. Got #{arg}"
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

    def setup_cluster(cluster_name)
      cluster_metadata = settings.clusters[cluster_name]

      if system("gcloud config configurations describe #{cluster_name}")
        puts "Configuration already exists for #{cluster_name}..."
      else
        puts "Creating configuration for this cluster and activating it..."
        system("gcloud config configurations create #{cluster_name}")
      end

      system("gcloud config configurations activate #{cluster_name}")
      puts "Authenticating in order to set the auth for project #{cluster_name}. You will be directed to a google login page."
      system("gcloud auth login")
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
      unless system('helm version &> /dev/null')
        puts "Installing helm..."
        system('brew install kubernetes-helm')
      end
    end
  end
end
