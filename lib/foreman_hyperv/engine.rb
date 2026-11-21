# frozen_string_literal: true

module ForemanHyperv
  class Engine < ::Rails::Engine
    engine_name 'foreman_hyperv'
    #config.autoload_paths += Dir["#{config.root}/app/models/concerns"]

    initializer 'foreman_hyperv.register_plugin', :before => :finisher_hook do |app|
      app.reloader.to_prepare do
        Foreman::Plugin.register :foreman_hyperv do
          requires_foreman '>= 3.14'
          register_gettext

          compute_resource ForemanHyperv::Hyperv

          # PLG-5a: hyperv_node_overrides joins the writable CR attributes so
          # the API and UI can carry the node→endpoint override map.
          parameter_filter ComputeResource, :url, :user, :password, :hyperv_node_overrides
        end
      end
    end

    # Add any db migrations. Without this the app's own maintenance check sees
    # the plugin's pending migrations through the plugin registry, while
    # foreman-rake db:migrate — which walks app.config.paths — never finds
    # them, and the install is stuck: the pattern is verbatim from
    # foreman_remote_execution's engine on the same Foreman.
    initializer 'foreman_hyperv.load_app_instance_data' do |app|
      ForemanHyperv::Engine.paths['db/migrate'].existent.each do |path|
        app.config.paths['db/migrate'] << path
      end
    end

    assets_to_precompile =
      Dir.chdir(root) do
        Dir['app/assets/{javascripts,stylesheets}/**/*'].map do |f|
          f.split(File::SEPARATOR, 4).last
        end
      end

    initializer 'foreman_hyperv.assets.precompile' do |app|
      app.config.assets.precompile += assets_to_precompile
    end

    initializer 'foreman_hyperv.filter_parameters' do |app|
      app.config.filter_parameters += []
    end

    initializer 'foreman_hyperv.configure_assets', group: :assets do
      SETTINGS[:foreman_hyperv] = { assets: { precompile: assets_to_precompile } }
    end

    initializer 'foreman_hyperv.add_rabl_view_path' do
      Rabl.configure do |config|
        config.view_paths << ForemanHyperv::Engine.root.join('app', 'views')
      end
    end

    config.to_prepare do
      require 'fog/hyperv'

      require 'fog/hyperv/compute/models/server'
      Fog::Hyperv::Compute::Server.prepend ::FogExtensions::Hyperv::Server

      require 'fog/hyperv/compute/models/network_adapter'
      Fog::Hyperv::Compute::NetworkAdapter.prepend ::FogExtensions::Hyperv::NetworkAdapter

      require 'fog/hyperv/compute/models/hard_drive'
      Fog::Hyperv::Compute::HardDrive.prepend ::FogExtensions::Hyperv::HardDrive

      Host::Managed.prepend ::ForemanHyperv::HostManagedExtensions
    end
    #
    # initializer 'foreman_hyperv.register_gettext', after: :load_config_initializers do
    #   locale_dir = File.join(File.expand_path('../..', __dir__), 'locale')
    #   locale_domain = 'foreman_hyperv'
    #   Foreman::Gettext::Support.add_text_domain locale_domain, locale_dir
    # end
  end
end
