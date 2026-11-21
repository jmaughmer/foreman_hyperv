# frozen_string_literal: true

module ForemanHyperv
  class Hyperv < ::ComputeResource
    include ComputeResourceCaching

    # The enablement condition, quoted verbatim from the reviewed plan at every
    # site that refuses one of these operations, so the operator who reads the
    # flash sees the same contract the reviewers did: the refusal lifts by a
    # merged PR once named lab rows have landed, never by configuration.
    # Each is one run of adjacent string literals joined by explicit line
    # continuations: a multiline literal list ending in `+ CONST` silently
    # drops its leading fragments on the parser this plugin is built with
    # (measured on Ruby 3.0.7), and a refusal whose sentence arrives truncated
    # quotes the reviewed plan wrongly. No shared REFUSAL_SENTENCE either, so
    # no literal-plus-constant concatenation anywhere here.
    # PLG-15b opened the create path for stand-alone machines only; a create
    # that asks for a cluster is still refused exactly as PLG-15 refused it,
    # and the cluster path lifts with PLG-15c — by a merged PR, with the same
    # enablement contract quoted, never by configuration.
    CLUSTER_CREATE_REFUSAL = 'Creating a virtual machine in a cluster is refused in every Hyper-V ' \
                             'compute resource in this plugin version; the cluster create path lifts ' \
                             'with PLG-15c by a merged PR, never by configuration. All disk removals ' \
                             'and VM destroys on cluster compute resources are refused in code until ' \
                             'FOG-10, PLG-15b and PLG-21b have merged and (m) and its (k″) rows have ' \
                             'landed; removal based solely on an absent role additionally requires a ' \
                             'named method that proves node-set completeness; enablement is a code ' \
                             'PR, not a configuration.'

    # PLG-15b's stand-alone gate refuses on every unknown, so the message says
    # what the gate asks and what an unknown costs; it is not a lock to be
    # configured away — the reads are made again on every create.
    STANDALONE_CREATE_REFUSAL = 'Creating a virtual machine on this Hyper-V compute resource is ' \
                                'refused: the endpoint did not read as a stand-alone Hyper-V host on ' \
                                'this attempt — the cluster membership read, the cluster-service ' \
                                'registry marker, or the cluster database file marker did not answer ' \
                                'as not found. Nothing was asked of the host and nothing was created. ' \
                                'A host that reads as clustered, or that cannot be read at all, stays ' \
                                'refused; this lifts by a merged PR, never by configuration.'

    DESTROY_REFUSAL = 'Destroying virtual machines is refused in every Hyper-V compute resource in this ' \
                      'plugin version. All disk removals and VM destroys on cluster compute resources ' \
                      'are refused in code until FOG-10, PLG-15b and PLG-21b have merged and (m) and ' \
                      'its (k″) rows have landed; removal based solely on an absent role additionally ' \
                      'requires a named method that proves node-set completeness; enablement is a code ' \
                      'PR, not a configuration.'

    DISK_REFUSAL = 'Removing disks from a virtual machine is refused in every Hyper-V compute resource ' \
                   'in this plugin version. All disk removals and VM destroys on cluster compute ' \
                   'resources are refused in code until FOG-10, PLG-15b and PLG-21b have merged and ' \
                   '(m) and its (k″) rows have landed; removal based solely on an absent role ' \
                   'additionally requires a named method that proves node-set completeness; ' \
                   'enablement is a code PR, not a configuration.'

    # PLG-21a: a fog write over WinRM is INDETERMINATE once the request has been
    # sent — the measured behaviour at the pinned fog is a successful
    # Add-ClusterVirtualMachineRole raising Fog::JSON::DecodeError on the empty
    # reply — so the only proof of success is a post-write read of the role,
    # keyed on the machine's id, taken as a cluster read on the compute
    # resource's own endpoint (an answer from any node was measured: the cluster
    # service replies for the whole cluster). Absent, empty or partial after
    # these attempts is indeterminate, and indeterminate means touch nothing.
    # The per-attempt cap is the WinRM operation timeout; this is the wait
    # between attempts.
    ROLE_READBACK_ATTEMPTS = 3
    ROLE_READBACK_INTERVAL = 30

    # Both templates take their values as Foreman::Exception params, which the
    # class sprints exactly once when it renders: a value that carries a percent
    # sign can never break the render, and every value passes through
    # strand_param anyway. The class name is always bare words; the first line is
    # fog's own text and is carried sanitized, with `readback-empty` for the
    # case where the write itself did not raise.
    ROLE_STRAND_FAILURE = 'Placing the virtual machine %<uuid>s in the cluster did not provably succeed ' \
                          '(the request reached the cluster, its outcome is unknown): %<error_class>s — ' \
                          '%<first_line>s. The machine at %<path>s named %<name>s has been left exactly as ' \
                          'it is: nothing was stopped, deleted or un-clustered, because tearing down a ' \
                          'machine the cluster may already own destroys the wrong thing. The strand is ' \
                          'in the log for an operator to resolve by hand.'

    ROLE_STRAND_EMPTY = 'Placing the virtual machine %<uuid>s in the cluster did not provably succeed ' \
                        '(the request reached the cluster, its outcome is unknown): readback-empty. ' \
                        'The machine at %<path>s named %<name>s has been left exactly as it is: nothing ' \
                        'was stopped, deleted or un-clustered, because tearing down a machine the ' \
                        'cluster may already own destroys the wrong thing. The strand is in the log ' \
                        'for an operator to resolve by hand.'

    # Hyper-V names a machine's cluster role after the machine; the prefix is
    # what a readback falls back to when the role's VM-id property is not
    # populated (see add_cluster_role_proven).
    ROLE_NAME_PREFIX = 'Virtual Machine '

    # PLG-15b arm (a): the cluster membership read is one minimal-property WQL
    # query against the cluster's own namespace — the same fog run_wql path
    # supports_clusters? uses (which appends the `/*` grammar itself), pinned
    # by red test to this exact query string and namespace.
    CLUSTER_MEMBERSHIP_QUERY = 'SELECT Name FROM MSCluster_Cluster'
    CLUSTER_MEMBERSHIP_NAMESPACE = 'root/mscluster'

    # The two wire answers that read, through this exact query path, as
    # "not clustered", both measured on the lab node through the fog wire:
    # WSMAN 1359 (the cluster WMI provider has nothing to answer with on a
    # machine not joined to a cluster — nested ProviderFault, WsmWmiPl.dll)
    # and WMI 2150858778 (the MSCluster_* classes themselves are absent —
    # the failover-cluster feature is not installed). Anything else — the
    # auth and transport failures that say nothing about membership
    # included — is indeterminate (N3).
    WIRE_CODE_CLUSTER_UNAVAILABLE = 1359
    WIRE_CODE_FEATURE_ABSENT = 2_150_858_778

    # B2's dual configured-marker, with the primitive each is read with
    # (measured paths, hyperv-e-results §52 and the d16b rows). The primitive
    # is NAMED = OPEN/READ, never a metadata or existence check: the registry
    # key is opened and its values enumerated (Get-ItemProperty, whose
    # measured missing-key answer is ItemNotFoundException), and the file is
    # opened and its first line read (Get-Content — Get-Item would answer
    # from the directory entry and never open a file an ACL denies to us,
    # which is exactly what row (v) has to be able to see fail).
    MARKER_READS = {
      params_registry: {
        cmdlet: 'Get-ItemProperty',
        path: 'HKLM:\SYSTEM\CurrentControlSet\Services\ClusSvc\Parameters'
      }.freeze,
      clusdb_file: {
        cmdlet: 'Get-Content',
        args: '-TotalCount 1',
        path: 'C:\Windows\Cluster\CLUSDB'
      }.freeze
    }.freeze

    # The self rung's refusal (N6): a target that is not the endpoint's own
    # machine is per-node territory, and per-node addressing is PLG-5a's.
    # Failing closed here is the pre-registered shipping state, not a bug.
    SELF_RUNG_REFUSAL = 'Creating a virtual machine on a computer other than this compute ' \
                        'resource’s own endpoint is refused until per-node addressing lands: the ' \
                        'name the endpoint gives itself did not match the machine’s computer name. ' \
                        'Nothing was asked of the host and nothing was created.'

    # B6: a cluster reading the ledger could not hold is a reading no future
    # decision may lean on, so the write failing is itself a refusal.
    SIGHTING_WRITE_REFUSAL = 'Refusing to act on this cluster reading because the sightings record ' \
                             'could not be written: the ledger is what keeps a later destroy from ' \
                             'trusting a host that once answered as a cluster, and an unreadable ' \
                             'ledger is not a safe one. Nothing was asked of the host and nothing ' \
                             'was created.'

    validates :url, :user, :password, presence: true
    after_validation :validate_connectivity unless Rails.env.test?

    def self.provider_friendly_name
      'Hyper-V'
    end

    def to_label
      "#{name} (#{provider_friendly_name})"
    end

    def self.available?
      Fog::Compute.providers.include?(:hyperv)
    end

    def self.model_name
      ComputeResource.model_name
    end

    def supports_update?
      true
    end

    def editable_network_interfaces?
      true
    end

    def capabilities
      [:build]
    end

    def test_connection(options = {})
      validate_connectivity(options)
    end

    def validate_connectivity(_options = {})
      return unless connection_properties_valid?
      return false if errors.any?

      error = connection_error
      errors.add(:base, error) if error
    end

    # Fog's valid? reads a Msvm_ComputerSystem instance, which any authenticated
    # user may query: it reports success for hosts the account can not manage,
    # and before fog-hyperv 0.2.2 (unreleased) it never returned true for a
    # remote host at all. Get-VMHost is the call the rest of the provider needs
    # anyway, so validating with it also proves the account can manage Hyper-V.
    #
    # @return [String, nil] the reason the connection can not be used
    def connection_error
      client.hosts.first ? nil : _('%{url} did not return a Hyper-V host') % { url: url }
    rescue StandardError => e
      e.message
    end

    def connection_valid?
      return false if url.blank? || user.blank? || password.blank?

      connection_error.nil?
    end

    def connection_properties_valid?
      errors[:url].empty? && errors[:user].empty? && errors[:password].empty?
    end

    def caching_enabled
      true
    end

    def provided_attributes
      super.merge(mac: :mac)
    end

    # TODO
    def max_cpu_count(host = nil)
      (host || hypervisor).logical_processor_count
    end

    def max_memory(host = nil)
      (host || hypervisor).memory_capacity
    end

    def available_hypervisors
      client.hosts.load(
        cache.cache(hypervisors_cache_key) do
          cluster_backed_hosts(endpoint_cluster).map(&:attributes)
        end
      )
    end
    alias hosts available_hypervisors

    # The public accessor the VM form and the API use. Routed through
    # cluster_named, which compares a cached listing in Ruby: fog's
    # clusters.get(name) interpolated the name into a Get-Cluster filter, so
    # this was the one public method a view-permission parameter could push
    # into the builder by itself. A name that is not a member now answers nil
    # — the form falls back to the resource's own hosts — where it used to
    # raise Fog::Errors::NotFound and error the page.
    def cluster(name)
      cluster_named(name)
    end

    def clusters
      client.clusters.load(
        cache.cache(:clusters) do
          _clusters.map(&:attributes)
        end
      )
    end

    # Mirror available_networks above: core renders the clusters endpoint from
    # vSphere flavoured fields the Hyper-V cluster model does not have.
    ApiCluster = Struct.new(:name, :id, :full_path, :datacenter, :num_host)

    def available_clusters
      clusters.map do |cluster|
        ApiCluster.new(cluster.name, cluster.id, nil, nil, cluster_node_count(cluster))
      end
    end

    def hypervisor
      client.hosts.new(
        cache.cache(hypervisor_cache_key) do
          client.hosts.first.attributes
        end
      )
    end

    def associated_host(vm)
      associate_by("mac", vm.network_adapters.map(&:mac))
    end

    delegate :servers, to: :client

    def switches(host)
      host ||= hosts.first
      client.switches.load(
        cache.cache(switches_cache_key(host)) do
          host.switches.all.map(&:attributes)
        end
      )
    end

    # Core's api/v2/compute_resources/available_networks.rabl renders a flat
    # collection of VMware/libvirt flavoured network objects. Hyper-V exposes
    # virtual switches instead of fog networks, and the switch models are
    # bound to a live connection, so map them into plain structs.
    ApiNetwork = Struct.new(:name, :id, :datacenter, :virtualswitch, :vlanid)

    # Core renders this from one flat list of network objects. With a cluster named
    # the choices are the switches its nodes have, which is not one host's list: a
    # virtual switch exists per node, and the same name on two nodes is two switches
    # with two GUIDs. A machine is connected by name, so names are what this lists —
    # all of them, including a name one node is missing, because dropping it silently
    # would leave the user wondering where the switch they built went. What is missing
    # where is logged; picking such a name for a machine that lands on the node
    # without it stays a creation error, which is the honest place to say it.
    def available_networks(cluster_id = nil)
      cluster = cluster_named(cluster_id)
      return api_networks(switches(nil)) if cluster.nil?

      hosts = cluster_backed_hosts(cluster)
      return api_networks(switches(nil)) if hosts.empty?

      switches_by_host = hosts.each_with_object({}) do |host, acc|
        acc[host.name] = begin
          switches(host)
        rescue StandardError => e
          Rails.logger.warn "Hyper-V switches for #{host.name} could not be read: #{e.message.lines.first}"
          []
        end
      end
      first_by_name = {}
      switches_by_host.each_value { |list| list.each { |sw| first_by_name[sw.name] ||= sw } }
      shared = switches_by_host.values.map { |list| list.map(&:name) }.reduce(&:&)
      (first_by_name.keys - shared).each do |name|
        without = switches_by_host.reject { |_host, list| list.any? { |sw| sw.name == name } }.keys
        Rails.logger.warn "Hyper-V switch #{name} is missing from #{without.join(', ')} in cluster #{cluster.name}"
      end

      first_by_name.values.map { |sw| ApiNetwork.new(sw.name, sw.id, nil, sw.name, nil) }
    end

    # Core's base #available_storage_domains answers "Not implemented for Hyper-V",
    # which the API returns as a 500 for a question that has an honest answer: a
    # stand-alone Hyper-V host has no datastores. A clustered one has its Cluster
    # Shared Volumes, and those are what a machine's disks go on, so this returns
    # them once there is a cluster to ask. An empty list rather than an exception
    # means the UI says "no datastores" and the API says 200 with [], which is the
    # truth about this host.
    #
    # The fields are core's rabl's (available_storage_domains.rabl reads name, id,
    # capacity, freespace, uncommitted) rather than Hyper-V's own names.
    ApiStorageDomain = Struct.new(:name, :id, :capacity, :freespace, :uncommitted)

    def available_storage_domains(cluster_id = nil)
      return [] if cluster_id.blank?

      # Looked up in the cached cluster list rather than asked for by name: on a host
      # with no cluster, asking fog for one raises, and a stale cluster id in a URL is
      # not a reason to find out whether it does.
      cluster = clusters.detect { |c| c.id == cluster_id || c.name == cluster_id }
      return [] unless cluster&.respond_to?(:shared_volumes)

      cluster.shared_volumes.map do |volume|
        ApiStorageDomain.new(volume.name, volume.volume_path,
                             volume.shared_volume&.[](:size),
                             volume.shared_volume&.[](:free_space), nil)
      end
    end

    # The deprecated /available_storage_domains/:name route asks for one by name with
    # no cluster named to look in, so it looks in all of them.
    def storage_domain(name)
      clusters.flat_map { |cluster| available_storage_domains(cluster.id) }
              .detect { |domain| domain.id == name || domain.name == name }
    end

    # Hyper-V has no zones — the word names another provider's layout (core aliases
    # it to EC2 availability zones) — and core's base raises "Not implemented for
    # Hyper-V", which the API serves as a 500 for a question whose honest answer is
    # that there are none. Same reasoning as available_storage_domains above. The
    # other endpoints core leaves unimplemented (folders, resource pools, storage
    # pods, flavors, security groups) are left as they are: nothing on the Hyper-V
    # path asks them, and each deserves its own answer rather than a blanket [].
    def available_zones
      []
    end

    def new_vm(attr = {})
      # Before super: core's new_vm mass-assigns this whole hash onto the fog
      # model, and the fog_extensions cluster_name= setter asks the host during
      # assignment. Nothing of the user's has reached fog by the time these two
      # lines finish, and nothing hostile gets past them.
      ForemanHyperv::InputValidation.validate_hash!(attr, context: :vm)
      validate_placement!(attr)
      apply_firmware_attributes(attr)
      attr.delete :id

      # logger.debug "New VM with arguments;\n#{attr}"
      vm = super
      iface_nested_attrs = nested_attributes_for :interfaces, attr[:interfaces_attributes]
      vm.network_adapters = iface_nested_attrs.map do |attr|
        attr.delete :id
        Fog::Hyperv::Compute::NetworkAdapter.new(service: vm.service, vm: vm).tap do |nic|
          attr.select { |_, v| v.present? }.each do |k, v|
            nic.send(:"#{k}=", v)
          end
        end
      end
      volume_nested_attrs = nested_attributes_for :volumes, attr[:volumes_attributes]
      vm.hard_drives = volume_nested_attrs.map do |attr|
        attr.delete :id
        Fog::Hyperv::Compute::HardDrive.new(service: vm.service, vm: vm).tap do |hdd|
          attr.select { |_, v| v.present? }.each do |k, v|
            hdd.send(:"#{k}=", v)
          end
        end
      end
      vm.id = nil
      vm
    end

    def create_vm(attr = {})
      # PLG-15's first act survives PLG-15b's unlock: input validation runs
      # before anything else, so a hostile hash hears about the string, not
      # just about the refusal.
      ForemanHyperv::InputValidation.validate_hash!(attr, context: :vm)
      attr = attr.to_hash.deep_symbolize_keys if attr.respond_to?(:to_hash)

      # PLG-15b: the create path answers stand-alone now. A create that asks
      # for a cluster is refused exactly as PLG-15 refused it — the cluster
      # create path lifts with PLG-15c — and the refusal lands before any read
      # of the endpoint. A create that asks for no cluster still has to pass
      # the stand-alone gate below, which refuses on every unknown.
      raise ForemanHyperv::OperationRefused, CLUSTER_CREATE_REFUSAL if attr[:cluster_name].present?
      raise ForemanHyperv::OperationRefused, STANDALONE_CREATE_REFUSAL unless create_allowed?

      attr = vm_instance_defaults.merge(attr)
      attr.delete :computer_name if attr[:computer_name].blank?
      start = Foreman::Cast.to_bool(attr.delete(:start))

      apply_firmware_attributes(attr)

      validate_vm(attr, new: true)
      validate_interfaces(attr)
      validate_volumes(attr)

      # logger.debug "Creating VM with arguments; #{attr}"
      cluster = cluster_named(attr[:cluster_name])
      storage = placement_storage(cluster, attr)

      vm = client.servers.new(
        name: attr[:name],
        computer_name: attr[:computer_name].presence || hypervisor.name,
        generation: attr[:generation],
        dynamic_memory_enabled: Foreman::Cast.to_bool(attr[:dynamic_memory_enabled]),
        memory_startup: attr[:memory_startup].to_i,
        memory_minimum: attr[:memory_minimum].to_i,
        memory_maximum: attr[:memory_maximum].to_i,
        processor_count: attr[:processor_count].to_i,
        notes: attr[:notes]
      )
      # N6 self rung: this machine is being built through this resource's own
      # client — the one configured with this endpoint — so its computer name
      # has to be the name the endpoint gives itself (Get-VMHost), compared
      # case-insensitively. A name that is not that name is per-node
      # addressing, which is PLG-5a's, and until that lands the target stays
      # refused. servers.new has built a model and sent nothing, so this
      # raise tears nothing down.
      raise ForemanHyperv::OperationRefused, SELF_RUNG_REFUSAL unless self_rung?(vm)

      vm.create(
        # TODO: should be :VHD if image build - when image build support exists
        boot_device: attr[:boot_device].present? ? attr[:boot_device].to_sym : :NetworkAdapter,
        path: storage&.id || hypervisor.virtual_machine_path
      )
      # The node's own disk path is the wrong drive for a clustered machine: every
      # node has to be able to read the VHDXs, so they go under the shared volume
      # the config was placed on, in a folder named for the machine.
      vm.placement_path = [storage.id, vm.name].join('\\') if storage

      if vm.generation == :UEFI
        vm.secure_boot_enabled = attr[:secure_boot_enabled]
        if attr[:tpm_enabled] == '1'
          security = vm.security
          security.change_key_protector :new
          security.tpm_enabled = true
          security.save
        end
      end

      create_interfaces(vm, attr)
      create_volumes(vm, attr)

      # The role goes on last, once the machine and its disks are where every node
      # can reach them — Add-ClusterVirtualMachineRole will not take a machine whose
      # storage is on a local path. It runs while the machine is off, which it still
      # is at this point, and before the start below.
      #
      # A machine placed into a cluster is clustered by default: on shared storage
      # with no role it fails over as nothing at all, and leaving that out should be
      # the explicit choice (an HA checkbox per VM is the plan for the form; until
      # it exists, ha_enabled answers "no" and nothing else does).
      if cluster && clusterize?(attr)
        # PLG-21a: the Add's own exception proves nothing once it has been sent,
        # so success is proven here by reading the role back, and anything short
        # of finding it raises StrandIndeterminate — which the rescue below
        # answers by touching nothing. role_added stays false until the readback
        # has actually found the role.
        role_added = add_cluster_role_proven(vm)
      end

      vm.start if start
      vm
    rescue StrandIndeterminate
      # Neither success nor failure is established: the machine may already be a
      # cluster-owned role (stop and disk deletes then fight the cluster over
      # the files — TEST-RESULTS finding 22) or may never have reached it. Every
      # teardown would be a guess, so there is none. The strand record went out
      # with the exception's own raise.
      logger.warn 'Cluster role add ended indeterminate: the virtual machine, its disks and any role ' \
                  "at #{strand_param(vm&.path)} were left untouched"
      raise
    rescue StandardError
      if vm&.persisted?
        # PLG-15b rollback, scoped to what this transaction created: the drives
        # are DETACHED, not deleted (the VHDX files stay — a delete would be
        # fog's Remove-Item path, which stays refused here), and the machine is
        # removed with Remove-VM only, not with its underlying store (the
        # config folder stays too). The folder and file deletes belong to the
        # enablement PR's decisions, never to a rollback guess. remove_cluster_role
        # stays for the day the cluster create path lands (PLG-15c): with the
        # cluster create refused and the indeterminate class handed to the
        # StrandIndeterminate rescue above, role_added is false on every path
        # that reaches this rescue today.
        remove_cluster_role(vm) if role_added
        vm.stop
        vm.hard_drives.each { |hdd| hdd.destroy(underlying: false) }
        vm.destroy(false)
      end

      raise
    end

    def save_vm(uuid, web_attr)
      ForemanHyperv::InputValidation.validate_id!(uuid)
      attr = web_attr.deep_symbolize_keys
      ForemanHyperv::InputValidation.validate_hash!(attr, context: :vm)
      # Disk removals are refused everywhere this version runs, checked on the
      # submitted form before anything is fetched: the fog call that answers
      # hard_drives.get(id) interpolates the id, and the destroy behind it is
      # the Remove-Item path the wildcard campaign measured.
      refuse_disk_removal!(attr)
      # Placement strings the edit form round-trips (computer_name, cluster_name
      # and per-volume datastore) must still be members of what the hypervisor
      # reports, character allowlist first, membership read unfiltered.
      validate_placement!(attr)
      attr.delete :start

      validate_vm(attr)
      validate_interfaces(attr)
      validate_volumes(attr)

      vm = find_vm_by_uuid(uuid)
      # logger.debug "Updating VM #{vm} with arguments; #{attr}"

      vm.processor_count = attr[:processor_count].to_i
      vm.notes = attr[:notes].presence
      vm.dynamic_memory_enabled = Foreman::Cast.to_bool(attr[:dynamic_memory_enabled])
      if vm.dynamic_memory_enabled
        vm.memory_minimum = attr[:memory_minimum].to_i
        vm.memory_maximum = attr[:memory_maximum].to_i
      end
      if vm.generation == :UEFI && attr[:tpm_enabled].present?
        security = vm.security
        security.tpm_enabled = attr[:tpm_enabled] == '1'
        if security.tpm_enabled && security.key_protector.nil?
          security.change_key_protector :new
        end
        security.save
      end
      if attr[:foreman_firmware].present?
        # The generation of an existing VM can not be changed, only its secure boot setting
        apply_firmware_attributes(attr, set_generation: false)
        vm.secure_boot_enabled = attr[:secure_boot_enabled]
      end

      update_interfaces(vm, attr)
      update_volumes(vm, attr)

      vm.save if vm.dirty?
      vm
    end

    # Core's find_vm_by_uuid asks the endpoint for the machine, and Get-VM answers
    # for the machines registered on the machine it ran on and nothing else. That is
    # enough on a stand-alone host; on a cluster it goes stale the moment a role
    # moves — the machine is the same GUID, it is just on another node now, and the
    # endpoint can no longer see it. Every action on a machine starts with this
    # lookup, so when the endpoint's answer fails, ask the cluster which node owns
    # the machine and ask that node. Whatever the endpoint says stands.
    def find_vm_by_uuid(uuid)
      # The URL VM id is a view-permission surface, and fog's Servers#get sends
      # any non-GUID identifier down its name path — straight into the builder
      # sink. GUID-only, before super, before the cluster-owner lookup.
      ForemanHyperv::InputValidation.validate_id!(uuid)
      super
    rescue ActiveRecord::RecordNotFound, Fog::Errors::NotFound, Fog::Hyperv::Errors::PSError => e
      vm = vm_from_cluster_owner(uuid)
      raise e unless vm

      vm
    end

    def destroy_vm(uuid)
      # Refused outright (PLG-15) — and the id is checked first so a hostile id
      # raises rather than arriving below, where the rescue turns NotFound into
      # a successful delete: reporting a refused destroy as success would drop
      # the host record and orphan the machine. UnsafeIdentifier and
      # OperationRefused are outside that rescue by class.
      ForemanHyperv::InputValidation.validate_id!(uuid)
      raise ForemanHyperv::OperationRefused, DESTROY_REFUSAL unless destroy_allowed?

      vm = find_vm_by_uuid(uuid)
      # A role keeps its claim on the machine's config and disks after the node
      # itself has stopped caring: take it out first, or the cluster is left holding
      # a role for a machine that is gone. (Whether Remove alone takes a running role
      # offline, or the role wants a Stop first, is the lab's to confirm — vm.stop
      # below covers the power state either way.)
      remove_cluster_role(vm) if vm.respond_to?(:clustered?) && vm.clustered?
      vm.stop turn_off: true
      vm.hard_drives.each { |hdd| hdd.destroy(underlying: true) }
      # TODO: Remove the empty VM folder
      vm.destroy(vm.path.end_with?(vm.name))
    rescue ActiveRecord::RecordNotFound, Fog::Errors::NotFound
      # if the VM does not exists, we don't really care.
      true
    end

    def update_required?(old_attrs, new_attrs)
      new_attrs.deep_symbolize_keys[:volumes_attributes]&.each_value do |hdd|
        if hdd[:id].present? && hdd[:_delete] == '1'
          Rails.logger.debug 'Scheduling compute instance update because a volume was removed'
          return true
        elsif hdd[:id].blank? && hdd[:_delete] != '1'
          Rails.logger.debug 'Scheduling compute instance update because a new volume was added'
          return true
        end
      end
      new_attrs.deep_symbolize_keys[:interfaces_attributes]&.each_value do |iface|
        if iface[:id].present? && iface[:_destroy] == '1'
          Rails.logger.debug 'Scheduling compute instance update because an interface was removed'
          return true
        elsif iface[:id].blank? && iface[:_destroy] != '1'
          Rails.logger.debug 'Scheduling compute instance update because a new interface was added'
          return true
        end
      end

      deep_update_required = proc do |path, old, new|
        old.merge(new) do |k, old_v, new_v|
          k_path = path + [k]
          if %i[allowed_vlan_ids secondary_vlan_ids].include?(k)
            tmp = Fog::Hyperv::Compute::NetworkAdapter.new

            old_v = Fog::Hyperv::Compute::NetworkAdapterVlan.render_vlan_list(tmp.send(:parse_vlan_list, old_v.to_s))
            new_v = Fog::Hyperv::Compute::NetworkAdapterVlan.render_vlan_list(tmp.send(:parse_vlan_list, new_v.to_s))
          end

          if old_v.is_a?(Hash) && new_v.is_a?(Hash)
            deep_update_required.call(k_path, old_v, new_v)
          elsif old_v.to_s != new_v.to_s
            Rails.logger.debug do
              "Scheduling compute instance update because #{k_path.join('.')} changed it's value from '#{old_v}' (#{old_v.class}) to '#{new_v}' (#{new_v.class})"
            end
            return true
          end
          new_v
        end
      end
      deep_update_required.call([], old_attrs.deep_symbolize_keys, new_attrs.deep_symbolize_keys)

      false
    end

    # def console(uuid)
    #   vm = find_vm_by_uuid(uuid)
    #
    #   {
    #     type: 'rdp',
    #     host: vm.computer.fully_qualified_domain_name,
    #   }
    # end

    def new_interface(attr = {})
      ForemanHyperv::InputValidation.validate_hash!(attr, context: :nic)
      Fog::Hyperv::Compute::NetworkAdapter.new attr
    end

    def new_volume(attr = {})
      ForemanHyperv::InputValidation.validate_hash!(attr, context: :hdd)
      basename = attr.delete(:basename) { 'Disk' }
      size = attr.delete(:size)

      vhd = client.vhds.new({ basename: basename, size: size }.compact)
      Fog::Hyperv::Compute::HardDrive.new vhd: vhd, **attr
    end

    # No caller in this plugin, and the fog model's mass-assign is raw, so this
    # is validated rather than deleted: a core form or API surface that grows a
    # cdrom path today would otherwise walk straight past every guard the other
    # seven sites have.
    def new_cdrom(attr = {})
      ForemanHyperv::InputValidation.validate_hash!(attr, context: :dvd)
      Fog::Hyperv::Compute::DvdDrive.new attr
    end

    def vm_instance_defaults
      super.merge(
        generation: 2,
        memory_startup: 1024.megabytes,
        processor_count: 1,
        interfaces: [new_interface]
      )
    end

    def vm_compute_attributes(vm)
      attr = super.slice(
        :computer_name, :name, :generation,
        :dynamic_memory_enabled,
        :memory_maximum, :memory_minimum, :memory_startup,
        :notes, :processor_count
      )
      attr[:foreman_firmware] = vm.foreman_firmware_type
      attr[:tpm_enabled] = vm.tpm_enabled

      attr
    end

    def set_vm_volumes_attributes(vm, vm_attrs)
      volumes = vm.hard_drives || []
      vm_attrs[:volumes_attributes] = volumes.each_with_index.to_h do |volume, index|
        [index.to_s, volume.compute_attributes]
      end
      vm_attrs
    end

    def set_vm_interfaces_attributes(vm, vm_attrs)
      interfaces = vm.interfaces || []
      vm_attrs[:interfaces_attributes] = interfaces.each_with_index.to_h do |interface, index|
        interface_attrs = {
          mac: interface.mac,
          compute_attributes: interface.compute_attributes
        }
        [index.to_s, interface_attrs]
      end
      vm_attrs
    end

    protected

    def client
      @client ||= Fog::Compute.new(
        provider: :HyperV,
        hyperv_endpoint: url,
        hyperv_username: user,
        hyperv_password: password
      )
    end

    private

    # PLG-15's refusal switchboard, opened one path at a time by reviewed PRs.
    # PLG-15b opens creates for stand-alone machines only (below); destroys
    # and disk removals stay refused everywhere — the stand-alone destroy is
    # PLG-15c's and the cluster paths stay locked behind the canonical
    # enablement sentence the refusal messages quote. Lifting a guard is a
    # merged PR whose gate those messages name, never a setting. They read as
    # predicates rather than bare raises so the code below each guard stays
    # live for the reader: it is the path that runs the day a guard flips,
    # not dead text.
    #
    # The stand-alone create gate (PLG-15b): arm (a) must answer not-clustered
    # on the endpoint, and BOTH configured markers must answer the not-found
    # exception — not-found-only, B2, concordant or not. Every unknown refuses:
    # a clustered reading, an unreadable classifier, a present marker, a
    # denied read, an unparsable token. The gate makes its reads again on
    # every create; there is nothing to configure.
    def create_allowed?
      case cluster_membership_state
      when :not_clustered
        nil
      when :clustered
        logger.warn 'Refusing to create a virtual machine: the endpoint answered a cluster membership row'
        return false
      else
        logger.warn 'Refusing to create a virtual machine: the cluster membership read did not answer'
        return false
      end

      MARKER_READS.each_key do |marker|
        state = marker_state(marker)
        next if state == :absent

        logger.warn "Refusing to create a virtual machine: the #{marker} marker read answered #{state}"
        return false
      end
      true
    end

    def destroy_allowed?
      false
    end

    def disk_removal_allowed?
      false
    end

    # Where a machine (or a disk of one) is asked to go, checked against what
    # the hypervisor itself named — never by asking the hypervisor about the
    # string. computer_name must be the endpoint host, the name the host gives
    # itself, or a name on the cluster's unfiltered Get-ClusterNode list;
    # cluster_name must be a member of the cached cluster listing; a volume's
    # datastore must be one of that cluster's shared volumes. The character
    # allowlist already ran (InputValidation is the first act at every site),
    # so the strings reaching the fog reads below are ours, not the user's, and
    # every read is unfiltered — a membership read IS a fog call, and it is the
    # one the user's string never enters.
    #
    # Fail closed: a membership read that does not answer refuses the
    # operation. Falling back to "probably fine" is how a machine gets placed
    # somewhere nobody checked.
    def validate_placement!(attr)
      # Form hashes arrive with string keys and API hashes with symbols; the
      # membership reads below are keyed by symbol either way.
      attr = attr.to_hash.deep_symbolize_keys if attr.respond_to?(:to_hash)

      computer = attr[:computer_name].presence
      if computer && placement_target_names.none? { |host| host == computer.to_s.downcase }
        raise ForemanHyperv::OperationRefused,
              'Refusing to place a machine on a computer this compute resource has not seen its own ' \
              'host or cluster report; nothing was asked of the host with that name'
      end

      cluster_name = attr[:cluster_name].presence
      if cluster_name && cluster_named(cluster_name).nil?
        raise ForemanHyperv::OperationRefused,
              'Refusing to place a machine in a cluster this compute resource has not read from its ' \
              'endpoint; nothing was asked of the host with that name'
      end

      asked_volumes = nested_attributes_for(:volumes, attr[:volumes_attributes]).filter_map { |vol| vol[:datastore] }
      return if asked_volumes.empty?

      cluster = cluster_name ? cluster_named(cluster_name) : endpoint_cluster
      domains = cluster ? available_storage_domains(cluster.id) : []
      asked_volumes.each do |asked|
        next if domains.any? { |domain| domain.name == asked || domain.id == asked }

        raise ForemanHyperv::OperationRefused,
              'Refusing to place a disk on a shared volume this compute resource has not read from ' \
              'its cluster; nothing was asked of the host with that name'
      end
    end

    # The node names a machine may be placed on: the configured endpoint, the
    # name the host gives itself, and every node of the cluster it belongs to.
    # Read fresh rather than cached — placement is exactly the decision a stale
    # list gets wrong — and a failed read is a refusal, not an empty set.
    def placement_target_names
      names = []
      begin
        names << URI.parse(url.to_s).host
        names << hypervisor.name
        if (cluster = endpoint_cluster)
          names.concat(cluster.nodes.map(&:name))
        end
      rescue StandardError => e
        # The fog error's own text can echo the remote command line, so it is
        # logged as its class only and never quoted back to the user.
        logger.warn "Refusing to read placement targets: the membership read answered #{e.class}"
        raise ForemanHyperv::OperationRefused,
              'Refusing to choose a placement target while the hypervisor could not report its own nodes'
      end
      names.compact.map { |host| host.to_s.downcase }
    end

    # Disk removals are refused on every Hyper-V compute resource, checked on
    # the submitted hash so the refusal lands before any lookup — and carrying
    # the canonical enablement sentence in the message.
    def refuse_disk_removal!(attr)
      return if disk_removal_allowed?

      volumes = nested_attributes_for(:volumes, attr[:volumes_attributes])
      return if volumes.none? { |vol| vol[:_delete].to_s == '1' }

      raise ForemanHyperv::OperationRefused, DISK_REFUSAL
    end

    # --- PLG-15b: the stand-alone create gate -----------------------------------

    # arm (a): one minimal-property WQL read of the cluster itself, on the
    # compute resource's own endpoint, through fog's run_wql (which appends
    # the namespace's `/*` grammar itself — passing the wildcard in here would
    # double it, a shape measured to raise "invalid namespace" instead of
    # answering). A row means membership; the two measured wire faults mean
    # the opposite; everything else — auth failures, transport errors, a
    # provider that answers with no row at all — says nothing, and N3 makes
    # everything that says nothing indeterminate. A positive reading is a
    # cluster sighting (B6): it goes into the insert-only ledger before this
    # method answers, and a ledger that cannot take the row is a refusal.
    def cluster_membership_state
      unless client.respond_to?(:run_wql)
        logger.warn 'The cluster membership read could not run: this fog exposes no WQL query path'
        return :indeterminate
      end

      rows = client.run_wql(CLUSTER_MEMBERSHIP_QUERY, _namespace: CLUSTER_MEMBERSHIP_NAMESPACE)
      if rows.is_a?(Hash) && rows[:name].to_s.strip.present?
        record_cluster_sighting(cluster_name: rows[:name].to_s.strip)
        :clustered
      else
        # The measured not-joined machine raises 1359 rather than answering an
        # empty row set; a provider that answers with nothing, or with a row
        # that carries no name, is a shape that has not been measured.
        :indeterminate
      end
    rescue ForemanHyperv::OperationRefused
      # The ledger's own refusal (write-fail, B6) is a decision, not an
      # unreadable wire: it travels up as itself instead of being folded into
      # the indeterminate class that says "the read did not answer".
      raise
    rescue StandardError => e
      arm_a_consistent_wire_error?(e) ? :not_clustered : :indeterminate
    end

    # The two faults that read as not-clustered through this exact query path,
    # as exceptions (WinRMWSManFault 1359, WinRMWMIError 2150858778) or as the
    # same reading one layer up — a fog PSError whose captured streams quote
    # one of the two wire codes is the machine's answer arriving as a command
    # failure rather than a transport exception, and it is the same answer.
    # Any other error, PSError included, is not an answer about membership.
    def arm_a_consistent_wire_error?(error)
      if defined?(::WinRM) && error.is_a?(::WinRM::WinRMWSManFault) &&
         error.fault_code.to_i == WIRE_CODE_CLUSTER_UNAVAILABLE
        return true
      end

      if defined?(::WinRM) && error.is_a?(::WinRM::WinRMWMIError) &&
         error.error_code.to_i == WIRE_CODE_FEATURE_ABSENT
        return true
      end

      return false unless error.is_a?(Fog::Hyperv::Errors::PSError)

      streams = "#{error.message}\n#{error.stderr}"
      streams.include?("WSMAN ERROR CODE: #{WIRE_CODE_CLUSTER_UNAVAILABLE}") ||
        streams.include?("WMI ERROR CODE: #{WIRE_CODE_FEATURE_ABSENT}")
    end

    # B2's dual-marker read, executed entirely server-side as one fog command.
    # The ONLY branch that may answer absent is the not-found exception the
    # named primitive raises for a missing path (N3: fog's single PSError and
    # its nil-on-empty-stdout replies make plugin-side discrimination from an
    # exit code impossible, so the machine's answer arrives as one JSON token
    # written by typed catches). The full exception class name rides the token
    # so the row-(v) arms can assert the exact per-marker shape the F3 table
    # names. present and absent are the only answers the gate acts on; denied
    # — a read the machine refused, of any class the F3 table expects under a
    # deny — and unreadable (every other exception) read as indeterminate, and
    # so does anything short of a well-formed token, empty stdout included.
    def marker_state(marker)
      out = client.run_cmd(marker_read_script(marker), _skip_json: true)
      reply = out.stdout.to_s.strip
      return :indeterminate if reply.empty? || reply.length > 1_024

      token = Fog::JSON.decode(reply)
      return :indeterminate unless token.is_a?(Hash)

      result = token['result'].to_s
      logger.debug "The #{marker} marker read answered #{result} (#{sanitize_text(token['type'].to_s)})"
      %w[present absent].include?(result) ? result.to_sym : :indeterminate
    rescue StandardError => e
      # fog raising at all — transport, auth, parse — says nothing (N3).
      logger.warn "The #{marker} marker read did not answer: #{e.class}"
      :indeterminate
    end

    # The script the marker read runs. Only the two constants in MARKER_READS
    # are interpolated — no user input is anywhere near it, and the whole read
    # is one command: open/read, five typed catches, one JSON line.
    def marker_read_script(marker)
      read = MARKER_READS.fetch(marker)
      probe = [read[:cmdlet], "-LiteralPath '#{read[:path]}'", read[:args], '-ErrorAction Stop'].compact.join(' ')
      <<~MARKER_READ
        $ForemanHypervMarkerRead = try {
          $null = #{probe}
          [pscustomobject]@{ result = 'present'; type = $null }
        } catch [System.Management.Automation.ItemNotFoundException] {
          [pscustomobject]@{ result = 'absent'; type = $_.Exception.GetType().FullName }
        } catch [System.Security.SecurityException] {
          [pscustomobject]@{ result = 'denied'; type = $_.Exception.GetType().FullName }
        } catch [System.UnauthorizedAccessException] {
          [pscustomobject]@{ result = 'denied'; type = $_.Exception.GetType().FullName }
        } catch [System.IO.IOException] {
          [pscustomobject]@{ result = 'denied'; type = $_.Exception.GetType().FullName }
        } catch {
          [pscustomobject]@{ result = 'unreadable'; type = $_.Exception.GetType().FullName }
        }
        $ForemanHypervMarkerRead | ConvertTo-Json -Compress
      MARKER_READ
    end

    # N6's self rung: the endpoint's own Get-VMHost name against the machine's
    # computer name, case-insensitively. A name that does not match — or an
    # endpoint that cannot name itself — is refused: per-node addressing is
    # PLG-5a's, and "fail-closed until PLG-5a" lives here until that PR lands
    # (the pre-registered shipping state, not an oversight).
    def self_rung?(vm)
      asked = vm&.computer_name.to_s.strip
      return false if asked.empty?

      host_name = hypervisor.name.to_s.strip
      return false if host_name.empty?

      asked.casecmp(host_name).zero?
    rescue StandardError => e
      logger.warn "The endpoint could not name itself for the create self-check: #{e.class}"
      false
    end

    # --- B6: the insert-only sightings ledger -------------------------------------

    # The endpoint host in the shape the ledger stores: the configured
    # endpoint's host, trimmed and downcased — the identity a later destroy
    # gate reads by. An endpoint that does not parse to a host is not a
    # host the ledger can hold a row for.
    def endpoint_host_name
      URI.parse(url.to_s).host.to_s.strip.downcase.presence
    rescue URI::Error
      nil
    end

    def record_cluster_sighting(cluster_name:)
      persist_cluster_sighting(kind: 'sighting', cluster_name: cluster_name)
    end

    # The write-fail rule (B6): every cluster-row sighting appends, and a
    # ledger that will not take the row means the reading cannot be recorded —
    # so the reading is refused, not trusted and not silently dropped. Values
    # go through the same sanitizers the strand log record uses: cluster and
    # machine names are machine-sourced text.
    def persist_cluster_sighting(kind:, vm_uuid: nil, vm_name: nil, cluster_name: nil, reason: nil)
      host = endpoint_host_name
      raise ForemanHyperv::OperationRefused, SIGHTING_WRITE_REFUSAL if host.nil?

      ForemanHyperv::ClusterSighting.create!(
        endpoint_host: host,
        kind: kind,
        vm_uuid: strand_param(vm_uuid).presence,
        vm_name: strand_param(vm_name).presence,
        cluster_name: sanitize_text(cluster_name.to_s).presence,
        reason: sanitize_text(reason.to_s).presence
      )
    rescue ActiveRecord::ActiveRecordError => e
      logger.error "The sightings ledger refused a #{kind} record and the reading goes with it: #{e.class}"
      raise ForemanHyperv::OperationRefused, SIGHTING_WRITE_REFUSAL
    end

    def _clusters
      return [] if client.respond_to?(:supports_clusters?) && !client.supports_clusters?

      client.clusters.all
    rescue StandardError
      []
    end

    # The cluster an endpoint belongs to, or nil for a stand-alone host — and for a
    # fog too old to have read a cluster's node list, which is the same nothing as far
    # as a caller is concerned.
    def endpoint_cluster
      return nil unless client.respond_to?(:supports_clusters?) && client.respond_to?(:cluster_nodes)
      return nil unless client.supports_clusters?

      clusters.first
    rescue StandardError
      nil
    end

    def cluster_named(identifier)
      return nil if identifier.blank?

      clusters.detect { |cluster| cluster.id == identifier || cluster.name == identifier }
    end

    # The hosts a placement choice is made between: the endpoint on its own, or every
    # node of the cluster when it belongs to one. Get-VMHost answers for the machine it
    # ran on and nothing else, so a cluster's other nodes come from the cluster's node
    # list and their details from each node in turn. A node that answers the cluster
    # but not WinRM stays in the list with only its name: the machine form leans on
    # this listing, and one node being down is a thing to report, not a reason to hide
    # the node or to fail the page.
    def cluster_backed_hosts(cluster = nil)
      return client.hosts.all unless cluster

      cluster.nodes.each_with_object([]) do |node, hosts|
        hosts << begin
          node.host
        rescue StandardError => e
          Rails.logger.warn "Hyper-V node #{node.name} is in cluster #{cluster.name} but not reachable over WinRM: #{e.message.lines.first}"
          node_only = client.hosts.new(name: node.name)
          # A node that answers the cluster but not WinRM is where the plugin learns a
          # node has gone quiet, so what it cached for that node while it answered goes
          # with it: a switch list read through an outage is a placement guess, and the
          # first read after the node comes back asks the node instead of serving that
          # list out its remaining lifetime. Nowhere else can this be noticed — a
          # cached switch list means the node is never asked, and a failed read means
          # there was nothing cached to drop.
          invalidate_hyperv_cache(switches_cache_key(node_only))
          node_only
        end
      end
    end

    # vSphere's clusters endpoint reports a size as a node count; for Hyper-V that is
    # Get-ClusterNode's list. Nil when fog cannot read it, because zero reads as an
    # empty cluster, which is a different claim from an unreadable one.
    def cluster_node_count(cluster)
      return nil unless cluster.respond_to?(:nodes)

      cluster.nodes.count
    rescue StandardError
      nil
    end

    def api_networks(list)
      list.map { |switch| ApiNetwork.new(switch.name, switch.id, nil, switch.name, nil) }
    end

    # How long this resource's listings are held. Core's own three hours suits a
    # stand-alone host: its node list and virtual switches change when an
    # administrator changes them, and each of those reads costs seconds of WinRM. A
    # cluster has no such quiet — nodes join, drain and stop answering without
    # touching the Foreman record, and Hyper-V gives out no event to listen for — so
    # its answers do not get to live as long. Five minutes puts a node that joined the
    # cluster into the next page load rather than hours away, and costs one re-read of
    # the cluster per page load.
    CLUSTER_CACHE_EXPIRY = 5.minutes

    # Core's cache object, built with the lifetime this endpoint deserves. The cluster
    # question is asked of fog rather than of the listings, because what is being
    # decided here is how long those listings live: reading them would ask the cache
    # object that is still being built.
    def cache
      @cache ||= if cluster_endpoint?
                   ComputeResourceCache.new(self, cache_duration: CLUSTER_CACHE_EXPIRY)
                 else
                   ComputeResourceCache.new(self)
                 end
    end

    # Whether the endpoint answers as a cluster, asked once and remembered: fog asks
    # the host every time, and every cache key would otherwise ask with it.
    def cluster_endpoint?
      return @cluster_endpoint if instance_variable_defined?(:@cluster_endpoint)

      @cluster_endpoint = client.respond_to?(:supports_clusters?) && client.supports_clusters?
    rescue StandardError => e
      Rails.logger.warn "Hyper-V cluster support for #{name} could not be read: #{e.message.lines.first}"
      @cluster_endpoint = false
    end

    # Which shape the cached listings hold: a stand-alone host's answers, or a named
    # cluster's. A cluster forming around an endpoint changes the cluster and not the
    # Foreman record, so nothing flushes the caches; naming the keys for the shape
    # means a resource that has started listing nodes cannot be served the stand-alone
    # answer it wrote when it was not. Parameterised because a deployment may be
    # running a cache store whose keys take no spaces.
    def hyperv_cache_scope
      cluster = endpoint_cluster
      return 'standalone' if cluster.nil?

      cluster.name.to_s.parameterize.presence || 'cluster'
    end

    def hypervisors_cache_key
      :"#{hyperv_cache_scope}-hypervisors"
    end

    def hypervisor_cache_key
      :"#{hyperv_cache_scope}-hypervisor"
    end

    def switches_cache_key(host)
      :"#{host.name.to_s.parameterize.presence || host.name}-switches"
    end

    # Drops a cached answer that has been shown wrong, so the next read asks the host
    # again rather than repeating a stale answer until core's expiry — or until someone
    # notices and saves the resource, which is the other way core's cache scope rolls.
    def invalidate_hyperv_cache(*keys)
      keys.compact.uniq.each do |key|
        Rails.logger.info "Dropping the cached Hyper-V answer for #{key} on #{name}"
        cache.delete(key)
      end
    end

    # The node list is the cached answer the cluster can prove wrong: a role is owned
    # by a node of this cluster by definition, so an owner the list does not name means
    # the cluster has a node Foreman has not been told about. The names are read from
    # the cache alone — checking against a fresh host read would answer the question
    # with the thing being checked. The hypervisor key is deliberately not touched: it
    # holds the endpoint node's own attributes, which a role moving to another node says
    # nothing about.
    def drop_hypervisor_list_unless_named(node_name)
      return if node_name.blank?

      key = hypervisors_cache_key
      cached = cache.read(key)
      return if cached.blank?

      names = Array(cached).map { |attrs| attrs[:name] || attrs['name'] }.compact.map(&:downcase)
      invalidate_hyperv_cache(key) unless names.include?(node_name.to_s.downcase)
    rescue StandardError => e
      Rails.logger.warn "The cached Hyper-V node list for #{name} could not be inspected: #{e.message.lines.first}"
    end

    # The shared volume a clustered machine's config and disks go on: the one its
    # volumes asked for (the volumes of a machine share one folder, so the first
    # one named wins), or the cluster's first volume when nothing was named. Raising
    # on a volume that is not there — silently placing onto a different one than the
    # user asked for is how machines end up on the wrong storage.
    def placement_storage(cluster, attr)
      return nil unless cluster

      domains = available_storage_domains(cluster.id)
      raise Foreman::Exception, "Cluster #{cluster.name} has no shared volumes to place a virtual machine on" if domains.empty?

      asked = nested_attributes_for(:volumes, attr[:volumes_attributes]).map { |vol| vol[:datastore] }.compact.first
      return domains.first unless asked

      domains.detect { |domain| domain.name == asked || domain.id == asked } ||
        raise(Foreman::Exception, "Cluster #{cluster.name} has no shared volume named #{asked}")
    end

    # A machine placed into a cluster is clustered by default; the planned HA
    # checkbox is the way to opt out, and until the form has one, only ha_enabled=0
    # (API and hammer) says so.
    def clusterize?(attr)
      attr[:ha_enabled].to_s != '0'
    end

    # PLG-21a. Put the machine into the cluster and PROVE it: fog writes over
    # WinRM are indeterminate once the request has been sent — measured at the
    # pinned fog, a successful Add raises Fog::JSON::DecodeError on its empty
    # reply — so the write's silence is not success and its exception is not
    # failure. Only finding the role by the machine's id in a readback answers
    # yes. The read is a cluster read on the compute resource's own endpoint
    # (any node's cluster service answers for the whole cluster — measured), not
    # a per-node call, so it needs no node targeting. Anything else — fog's
    # exception, a raising readback, or absent/partial roles after
    # ROLE_READBACK_ATTEMPTS tries — is indeterminate: the strand record goes to
    # the log, and StrandIndeterminate stops the caller from tearing anything
    # down. The fog call being absent (fog too old to add roles) still raises
    # BEFORE anything is sent, which keeps its deterministic rollback.
    def add_cluster_role_proven(vm)
      unless client.respond_to?(:add_cluster_virtual_machine_role)
        raise Foreman::Exception, 'Placing a virtual machine in a cluster needs a fog-hyperv that can add cluster roles'
      end

      send_error = nil
      begin
        # Everything from here on is post-send: after this line every exception
        # class — including fog's decode error on a success — is indeterminate
        # and belongs to the readback, not to a rollback.
        client.add_cluster_virtual_machine_role(id: vm.id, computer_name: vm.computer_name)
      rescue StandardError => e
        send_error = e
      end

      ROLE_READBACK_ATTEMPTS.times do |attempt|
        if attempt.positive?
          # The per-attempt cap is the WinRM operation timeout; this is the gap
          # between attempts, so a slow-but-committing Add is still caught.
          sleep ROLE_READBACK_INTERVAL
        end

        found, readback_error = readback_finds_role?(vm)
        return true if found

        # Keep the first readback failure: with no send error it is the one the
        # strand record quotes; with a send error the send tells the story.
        send_error ||= readback_error
      end

      record_role_strand(vm, send_error)
      # The params go to the constructor (Foreman::Exception#initialize takes
      # message plus params); passing them as raise's third argument would make
      # Ruby read them as a backtrace.
      raise StrandIndeterminate.new(strand_message_template(send_error), strand_message_params(vm, send_error))
    end

    # One pass of the proof. A role counts as found when it carries the
    # machine's id (case-insensitively: fog's own collection filters -VMId
    # case-insensitively too), or when the id property is empty — the field is
    # reported on ClusterGroup but not documented, so it may be missing on real
    # hosts — and the role's documented name is this machine's. Anything that
    # matches neither is not this machine's role: an absent answer here is a
    # clean "no", which is still not a proof either way.
    def readback_finds_role?(vm)
      roles = Array(client.cluster_virtual_machine_roles.all(vm_id: vm.id)).flatten.compact
      wanted_role_name = "#{ROLE_NAME_PREFIX}#{vm.name}"
      found = roles.any? do |role|
        role_id = role.respond_to?(:virtual_machine_id) ? role.virtual_machine_id : nil
        if role_id.presence
          role_id.to_s.casecmp(vm.id.to_s).zero?
        else
          role.name.to_s.casecmp(wanted_role_name).zero?
        end
      end
      [found, nil]
    rescue StandardError => e
      # A readback that cannot answer is not an absent readback: the attempt
      # counts, but the strand record quotes this as its reason.
      [false, e]
    end

    # The strand record (B6): what was asked for, where it was left, and why the
    # plugin will not guess — in the log for the operator in front of the console,
    # and in the sightings ledger (kind strand, PLG-21b's migration) for every
    # later decision that must not forget this machine. The ledger write is
    # best-effort in one specific sense: if it fails, the touch-nothing contract
    # still holds, because the StrandIndeterminate raise that follows is the
    # refusal with or without the row — but the failed write is said out loud,
    # because an operator who later trusts the ledger needs to know this strand
    # only made it to the log.
    def record_role_strand(vm, error)
      logger.warn format(
        'Hyper-V cluster role strand: virtual machine %<uuid>s (name %<name>s) at %<path>s was asked ' \
        'to join the cluster and the outcome is unproven (%<reason>s). Left untouched: machine, disks, ' \
        'role. An operator must reconcile it by hand.',
        uuid: strand_param(vm&.id), name: strand_param(vm&.name), path: strand_param(vm&.path),
        reason: strand_reason(error)
      )
      persist_cluster_sighting(kind: 'strand', vm_uuid: vm&.id, vm_name: vm&.name, reason: strand_reason(error))
    rescue StandardError => e
      logger.error "The strand ledger record could not be written (the log record above is all there is): #{e.class}"
    end

    # Either the send's own first line, or the fact that no readback ever
    # answered. Both go through the sanitizer, so neither can carry a percent
    # sign or a control character into the log line.
    def strand_reason(error)
      return 'readback-empty' unless error

      "#{strand_param(error.class.name)}: #{sanitize_text(error.message.to_s.lines.first)}"
    end

    # The template and params are handed to Foreman::Exception, which sprintfs
    # them once at render time — the values never become part of the template,
    # so a percent sign in one of them cannot break the render.
    def strand_message_template(error)
      error ? ROLE_STRAND_FAILURE : ROLE_STRAND_EMPTY
    end

    def strand_message_params(vm, error)
      base = {
        uuid: strand_param(vm&.id),
        path: strand_param(vm&.path),
        name: strand_param(vm&.name)
      }
      if error
        base[:error_class] = strand_param(error.class.name)
        base[:first_line] = sanitize_text(error.message.to_s.lines.first)
      end
      base
    end

    # Identifiers the plugin itself holds (a GUID from fog, a fog-reported path,
    # a validated name) kept safe for a sprintf target: no percent sign, no
    # control characters, bounded length.
    def strand_param(value)
      value.to_s.gsub(/[^[:print:]]/, '').delete('%').truncate(200)
    end

    # fog's own text, made safe the same way. Kept to one line and 200
    # characters: this is a quotation for operators, not a transcript.
    def sanitize_text(text)
      text.to_s.gsub(/[^[:print:]]/, '').delete('%').truncate(200)
    end

    # Takes the clustered role off a machine, leaving the machine itself alone. A
    # role the cluster will not give up stops the teardown rather than continuing
    # under it: deleting a machine whose role still points at its files leaves the
    # cluster holding a claim on storage that no longer describes anything, which is
    # worse to clean up than a machine that refused to delete.
    def remove_cluster_role(vm)
      return unless client.respond_to?(:remove_cluster_virtual_machine_role)

      node = vm.respond_to?(:owner_node) ? vm.owner_node : vm.computer_name
      client.remove_cluster_virtual_machine_role(id: vm.id, computer_name: node)
    rescue StandardError => e
      # A fog failure's own text can carry the remote command line, including
      # percent signs, and Foreman::Exception sprintfs its message again when
      # it renders: the class is quoted, the text is not.
      logger.warn "The Hyper-V cluster would not release the role: #{e.class}"
      raise Foreman::Exception, 'Refusing to delete a clustered virtual machine while the cluster still holds its role'
    end

    # The machine as the node that owns it right now sees it, or nil when no cluster
    # role claims it — the whole point being the case where the endpoint no longer
    # answers for it.
    def vm_from_cluster_owner(uuid)
      # Checked before the StandardError rescue below can fold it into nil: a
      # hostile id must raise, not answer "no owner", and this read takes the
      # id to fog, so GUID-only here as well (find_vm_by_uuid already refuses
      # it; this is the same gate at the second door).
      ForemanHyperv::InputValidation.validate_id!(uuid)
      return nil unless client.respond_to?(:cluster_virtual_machine_roles) &&
                        client.respond_to?(:supports_clusters?) && client.supports_clusters?

      role = [client.cluster_virtual_machine_roles.all(vm_id: uuid)].flatten.compact.first
      return nil unless role&.owner_node

      logger.info "Virtual machine #{uuid} is owned by cluster node #{role.owner_node}, reading it from there"
      drop_hypervisor_list_unless_named(role.owner_node)
      client.servers.get(uuid, computer_name: role.owner_node)
    rescue StandardError => e
      raise if e.is_a?(ForemanHyperv::UnsafeIdentifier)

      logger.warn "Clustered lookup of virtual machine #{uuid} failed: #{e.message.lines.first}"
      nil
    end

    def validate_vm(attr, new: false)
      # logger.debug "Validate VM #{attr.inspect}"
      raise Foreman::Exception, 'VM lacks generation' if new && attr[:generation].blank?
      raise Foreman::Exception, 'VM lacks memory' unless attr[:memory_startup].to_i.positive?
      raise Foreman::Exception, 'VM lacks CPUs' unless attr[:processor_count].to_i.positive?

      return unless Foreman::Cast.to_bool(attr[:dynamic_memory_enabled])
      raise Foreman::Exception, 'VM lacks memory minimum' unless attr[:memory_minimum].to_i.positive?
      raise Foreman::Exception, 'VM lacks memory maximum' unless attr[:memory_maximum].to_i.positive?
    end

    # Hyper-V has no firmware setting of its own: generation 1 VMs boot from BIOS,
    # generation 2 VMs from UEFI. Let Foreman resolve the firmware that was selected
    # for the host (including the PXE loader based 'automatic' firmware) and turn it
    # into the generation the VM has to be created with, along with the secure boot
    # settings that belong to the firmware.
    def apply_firmware_attributes(attr, set_generation: true)
      firmware_type = attr.delete(:firmware_type).to_s
      attr.merge!(process_firmware_attributes(attr[:foreman_firmware], firmware_type, attr[:provision_method]))

      # The generation is only set when a firmware was actually chosen, hosts that
      # carry no firmware at all keep the default generation.
      return attr if !set_generation || attr[:foreman_firmware].blank?

      firmware = resolve_automatic_firmware(attr[:firmware], firmware_type)
      attr[:generation] = firmware == 'bios' ? 1 : 2
      attr
    end

    def generate_secure_boot_settings(firmware)
      return {} unless firmware.to_s.include?('efi')

      {
        secure_boot_enabled: firmware.to_s.end_with?('secure_boot')
      }
    end

    def validate_interfaces(attr)
      interfaces = nested_attributes_for :interfaces, attr[:interfaces_attributes]
      interfaces.reject! { |iface| iface[:_destroy] == '1' }
      # logger.debug "Validate NIC #{interfaces.inspect}"
      interfaces.each do |iface|
        compute = iface[:compute_attributes] || iface
        case compute[:vlan_operation_mode].to_s
        when 'Untagged'
          # No VLAN settings to verify
        when 'Access'
          raise Foreman::Exception, 'Interface is missing access VLAN' unless compute[:access_vlan_id].to_i.positive?
        when 'Trunk'
          raise Foreman::Exception, 'Interface is missing native VLAN' unless compute[:native_vlan_id].to_i.positive?
          raise Foreman::Exception, 'Interface is missing allowed VLANs' if compute[:allowed_vlan_ids].blank?
        when 'Private'
          raise Foreman::Exception, 'Interface is missing primary VLAN' unless compute[:primary_vlan_id].to_i.positive?

          case compute[:vlan_private_mode].to_s
          when 'Promiscuous'
            if compute[:secondary_vlan_ids].blank?
              raise Foreman::Exception,
                    'Interface is missing secondary VLANs'
            end
          else
            unless compute[:secondary_vlan_id].to_i.positive?
              raise Foreman::Exception,
                    'Interface is missing secondary VLAN'
            end
          end
        else
          raise Foreman::Exception, 'Interface has unknown VLAN mode'
        end
      end
    end

    def create_interfaces(vm, attr)
      interfaces = nested_attributes_for :interfaces, attr[:interfaces_attributes]
      logger.debug "Creating interfaces with: #{interfaces}"

      first_provisioned = false
      interfaces.each do |iface|
        # The VM is pre-created with one NIC regardless of given creation options, so configure that one first
        nic = vm.network_adapters.first unless first_provisioned
        first_provisioned = true

        nic ||= vm.network_adapters.new
        iface.except(:identity, :ip, :ip6).each do |k, v|
          nic.send(:"#{k}=", v.presence)
        end
        # nic.is_legacy = Foreman::Cast.to_bool(iface[:is_legacy]) if vm.generation == :BIOS && iface[:is_legacy].present?
        # logger.debug "Creating interface with #{iface.inspect} - #{nic.inspect}\n#{nic.vlan_setting.inspect}"
        nic.save
      end

      unless vm.network_adapters.all(_return_fields: %i[dynamic_mac_address_enabled]).any?(&:dynamic_mac_address_enabled)
        return
      end

      # Populate all non-populated MAC addresses
      vm.start
      vm.stop turn_off: true

      vm.network_adapters.reload.each do |nic|
        nic.dynamic_mac_address_enabled = false
        nic.save if nic.dirty?
      end
    end

    def update_interfaces(vm, attr)
      interfaces = nested_attributes_for :interfaces, attr[:interfaces_attributes]
      logger.debug "Updating interfaces with: #{interfaces}"

      interfaces.each do |interface|
        compute = interface[:compute_attributes]
        if compute[:identity].present?
          nic = vm.network_adapters.get compute[:identity]
          if interface[:_destroy] == '1'
            nic.destroy
          else
            compute.each do |k, v|
              nic.send(:"#{k}=", v.presence)
            end
            nic.mac ||= interface[:mac].presence
            nic.save
          end
        elsif interface[:_destroy] != '1'
          nic = vm.network_adapters.new
          compute.each do |k, v|
            nic.send(:"#{k}=", v.presence)
          end
          nic.mac ||= interface[:mac].presence
          nic.save
        end
      end
    end

    def validate_volumes(attr)
      volumes = nested_attributes_for :volumes, attr[:volumes_attributes]
      volumes.reject! { |vol| vol[:_delete] == '1' }
      # logger.debug "Validate Volume #{volumes.inspect}"
      volumes.each do |vol|
        raise Foreman::Exception, 'Volume lacks name' if vol[:basename].blank?
        raise Foreman::Exception, 'Volume name should not include a file extension' if vol[:basename] =~ /\.vhd[sx]?$/
        raise Foreman::Exception, 'Volume lacks size' unless vol[:size_bytes].to_i.positive?
      end
      return unless volumes.group_by { |vol| vol[:basename].downcase }.any? { |_k, v| v.many? }

      raise Foreman::Exception, 'Volume names need to be unique'
    end

    def create_volumes(vm, attr)
      volumes = nested_attributes_for :volumes, attr[:volumes_attributes]
      logger.debug "Creating volumes with: #{volumes}"
      volumes.each do |vol|
        vhd = vm.vhds.create basename: vol[:basename], size: vol[:size_bytes].to_i
        vm.hard_drives.create vhd: vhd
      end
    end

    def update_volumes(vm, attr)
      volumes = nested_attributes_for :volumes, attr[:volumes_attributes]
      logger.debug "Updating volumes with: #{volumes}"
      volumes.each do |volume|
        if volume[:id].present?
          hd = vm.hard_drives.get volume[:id]
          if volume[:_delete] == '1'
            hd.destroy(underlying: true)
          else
            vhd = hd.vhd
            vhd.size = volume[:size_bytes].to_i
            vhd.save if vhd.dirty?
          end
        elsif volume[:_delete] != '1'
          vhd = vm.vhds.create basename: volume[:basename], size: volume[:size_bytes].to_i
          vm.hard_drives.create path: vhd.path
        end
      end
    end
  end
end
