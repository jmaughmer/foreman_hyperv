# frozen_string_literal: true

module ForemanHyperv
  class Engine < ::Rails::Engine
    engine_name 'foreman_hyperv'
    # config.autoload_paths += Dir["#{config.root}/app/models/concerns"]

    initializer 'foreman_hyperv.register_plugin', :before => :finisher_hook do |app|
      app.reloader.to_prepare do
        Foreman::Plugin.register :foreman_hyperv do
          requires_foreman '>= 3.14'
          register_gettext

          compute_resource ForemanHyperv::Hyperv

          # PLG-5a: hyperv_node_overrides joins the writable CR attributes so
          # the API and UI can carry the node→endpoint override map.
          # PLG-5b: hyperv_ca_trust_path joins them too — the CA file the
          # hardened per-node compositions verify against.
          # PLG-32: hyperv_ssl_verify joins them — the deliberate, per-resource
          # opt-out of certificate verification on an https endpoint.
          # PLG-34: hyperv_keepalive joins them — the per-resource opt-in to
          # the scheduled warm-the-hops tick.
          parameter_filter ComputeResource, :url, :user, :password, :hyperv_node_overrides,
                           :hyperv_ca_trust_path, :hyperv_ssl_verify, :hyperv_keepalive

          # PLG-34: ONE global interval for every enabled resource (the
          # per-cluster column stays a plain on/off — per-cluster intervals
          # mostly invite tuning drift). The reader in
          # ForemanHyperv::Keepalive clamps whatever this holds into 60–3600.
          # PLG-34b B1: the default is 60 — measured warmth decay in a real
          # lab lands below the human-readable band well inside 300 s
          # (Pass 70), so the beat has to be shorter than the decay. B1
          # changes the DEFAULT only: an already-stored value (an untouched
          # 300 or a deliberate one) is never rewritten.
          settings do
            category(:hyperv, N_('Hyper-V')) do
              setting(:hyperv_keepalive_interval_seconds,
                      type: :integer,
                      default: 60,
                      full_name: N_('Hyper-V keepalive interval'),
                      description: N_('Seconds between keepalive ticks for Hyperv compute ' \
                                      'resources that have keepalive enabled. The effective ' \
                                      'value is clamped to 60-3600. One beat per interval runs ' \
                                      'across all Foreman processes (a Postgres advisory-lock ' \
                                      'election). A tick replays one page load of endpoint ' \
                                      'reads so the next human load is warm.'))
              # bootdisk PR-3: the two roots the pull endpoint rides (plan v10
              # Decision 2). DEFAULT BLANK — an unset pair is the documented
              # dormant state the store refuses with (iso_* steps answer
              # before writing a byte), so enabling the shelf is a deliberate
              # operator act: set both roots AND install the shipped Apache
              # snippet (config/apache/foreman-bootdisk-pull.conf; the
              # installer purges the drop-in dirs — measured 2026-11-24 — so
              # the copy is an explicit act, re-applied after every installer
              # run). Nothing reads these at boot: the store resolves them
              # per operation, so a fresh install boots and migrates before
              # any of this exists (the PLG-34 initializer lesson). Named
              # hyperv_bootdisk_*, not bootdisk_*: settings share ONE flat
              # namespace, foreman_bootdisk already owns bootdisk_* (24.1.0
              # registers bootdisk_ipxe_dir through bootdisk_allowed_types —
              # measured), a future upstream collision would crash boot on a
              # duplicate registration, and the plugin's own convention is the
              # hyperv_ prefix (hyperv_keepalive_interval_seconds).
              setting(:hyperv_bootdisk_pull_root,
                      type: :string,
                      default: '',
                      full_name: N_('Hyper-V boot disk pull root'),
                      description: N_('Directory Apache serves at /bootdisk-pull for Hyper-V hosts ' \
                                      'to pull generated boot disk ISOs over HTTP (created 0711, ' \
                                      'owner foreman, when missing). Must match the Alias target of ' \
                                      'the foreman-bootdisk-pull.conf snippet — iso_upload checks the ' \
                                      'installed drop-in against this value and refuses before ' \
                                      'staging on a mismatch — and the installer removes that ' \
                                      'drop-in, so re-copy it after every installer run. Blank keeps ' \
                                      'boot disk transfers dormant: iso_upload refuses before ' \
                                      'staging.'))
              setting(:hyperv_bootdisk_staging_root,
                      type: :string,
                      default: '',
                      full_name: N_('Hyper-V boot disk staging root'),
                      description: N_('Private directory beside the pull root holding in-flight ' \
                                      'copies and sidecars (created 0700, owner foreman, when ' \
                                      'missing; never served by Apache). Blank keeps boot disk ' \
                                      'transfers dormant: iso_upload refuses before staging.'))
            end
          end
        end
      end
    end

    # PLG-34: start the keepalive scheduler. One named thread per booted
    # process, in-process. PLG-34b: the beat itself runs through a Postgres
    # advisory-lock ELECTION bucketed by interval epoch, so across all N
    # Foreman processes exactly one thread dials per interval (losers poll
    # the next bucket at 1 s; lock loss self-heals; non-Postgres every
    # thread beats). Keepalive.start! is a no-op in the test environment
    # and under rake, so tests and migrations stay deterministic and silent.
    # config.after_initialize (not a named
    # initializer) is deliberate: engine initializers run before the app's
    # autoload is resolvable (a NameError booted the app down the first
    # time); the after_initialize hook runs after the finisher, when the
    # engine's models load like any other.
    config.after_initialize do
      ForemanHyperv::Keepalive.start!
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
      # bootdisk PR-5: the Host::Managed-side seam — Decision 1's payload-
      # staleness guard. It rides beside HostManagedExtensions because the
      # opt-in word (Hyperv#capabilities) is what makes provision_method
      # 'bootdisk' savable at all, and this is the validation that protects
      # the flow that word opens.
      Host::Managed.prepend ::ForemanHyperv::BootdiskSeam
    end
    #
    # initializer 'foreman_hyperv.register_gettext', after: :load_config_initializers do
    #   locale_dir = File.join(File.expand_path('../..', __dir__), 'locale')
    #   locale_domain = 'foreman_hyperv'
    #   Foreman::Gettext::Support.add_text_domain locale_domain, locale_dir
    # end
  end
end
