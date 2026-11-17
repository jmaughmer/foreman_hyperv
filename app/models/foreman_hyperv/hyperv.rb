# frozen_string_literal: true

module ForemanHyperv
  class Hyperv < ::ComputeResource
    include ComputeResourceCaching

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

    def cluster(name)
      return nil unless name

      client.clusters.get name
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
      attr = vm_instance_defaults.merge(attr.to_hash.deep_symbolize_keys)
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
        unless client.respond_to?(:add_cluster_virtual_machine_role)
          raise Foreman::Exception, 'Placing a virtual machine in a cluster needs a fog-hyperv that can add cluster roles'
        end

        client.add_cluster_virtual_machine_role(id: vm.id, computer_name: vm.computer_name)
        role_added = true
      end

      vm.start if start
      vm
    rescue StandardError
      if vm&.persisted?
        # The role owns the machine's config and disks the way the node does not:
        # taking the machine apart without taking the role apart first leaves the
        # cluster trying to start a machine that is gone (and fog's own disk teardown
        # ends up fighting the cluster over the files — TEST-RESULTS finding 22).
        remove_cluster_role(vm) if role_added
        vm.stop
        vm.hard_drives.each { |hdd| hdd.destroy(underlying: true) }
        vm.destroy(vm.path.end_with?(vm.name))
      end

      raise
    end

    def save_vm(uuid, web_attr)
      attr = web_attr.deep_symbolize_keys
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
      super
    rescue ActiveRecord::RecordNotFound, Fog::Errors::NotFound, Fog::Hyperv::Errors::PSError => e
      vm = vm_from_cluster_owner(uuid)
      raise e unless vm

      vm
    end

    def destroy_vm(uuid)
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
      Fog::Hyperv::Compute::NetworkAdapter.new attr
    end

    def new_volume(attr = {})
      basename = attr.delete(:basename) { 'Disk' }
      size = attr.delete(:size)

      vhd = client.vhds.new({ basename: basename, size: size }.compact)
      Fog::Hyperv::Compute::HardDrive.new vhd: vhd, **attr
    end

    def new_cdrom(attr = {})
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
      raise Foreman::Exception, "Refusing to delete a clustered virtual machine while the cluster still holds its role: #{e.message.lines.first}"
    end

    # The machine as the node that owns it right now sees it, or nil when no cluster
    # role claims it — the whole point being the case where the endpoint no longer
    # answers for it.
    def vm_from_cluster_owner(uuid)
      return nil unless client.respond_to?(:cluster_virtual_machine_roles) &&
                        client.respond_to?(:supports_clusters?) && client.supports_clusters?

      role = [client.cluster_virtual_machine_roles.all(vm_id: uuid)].flatten.compact.first
      return nil unless role&.owner_node

      logger.info "Virtual machine #{uuid} is owned by cluster node #{role.owner_node}, reading it from there"
      drop_hypervisor_list_unless_named(role.owner_node)
      client.servers.get(uuid, computer_name: role.owner_node)
    rescue StandardError => e
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
