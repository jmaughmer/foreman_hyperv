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

    # PLG-15c opened the destroy path for machines on endpoints PROVEN
    # stand-alone (standalone_destroy_state below). Everything the definition
    # calls a cluster compute resource stays refused — a clustered reading, a
    # sticky sighting, a configured marker that answered present, a machine
    # reporting a cluster role — and it hears the enablement contract as
    # written. The until-clause has landed; §4(22) says it is necessary, not
    # sufficient, and the remaining lifting is the enablement PR's, never a
    # setting's.
    DESTROY_REFUSAL = 'Destroying a virtual machine on this Hyper-V compute resource is refused: the ' \
                      'endpoint was not proven a stand-alone Hyper-V host — a cluster membership ' \
                      'reading, a stored cluster sighting, a configured-cluster marker, or the ' \
                      'machine’s own cluster role answered instead. All disk removals and VM destroys ' \
                      'on cluster compute resources are refused in code until FOG-10, PLG-15b and ' \
                      'PLG-21b have merged and (m) and its (k″) rows have landed; removal based solely ' \
                      'on an absent role additionally requires a named method that proves node-set ' \
                      'completeness; enablement is a code PR, not a configuration. Nothing was stopped ' \
                      'and nothing was deleted.'

    # The destroy gate refuses on every unknown, as its sister create gate
    # does, and the message says what the gate asks and what an unknown costs.
    STANDALONE_DESTROY_REFUSAL = 'Destroying a virtual machine on this Hyper-V compute resource is ' \
                                 'refused: the endpoint did not read as a stand-alone Hyper-V host on ' \
                                 'this attempt — the cluster membership read, the cluster-service ' \
                                 'state read, the cluster-service registry marker, or the cluster ' \
                                 'database file marker did not answer as expected. Nothing was ' \
                                 'stopped and nothing was deleted. A host that reads as clustered, or ' \
                                 'that cannot be read at all, stays refused; this lifts by a merged ' \
                                 'PR, never by configuration.'

    # The destroy-side self rung: the same N6 refusal the create path answers
    # with, worded for a machine that already exists. Per-node addressing is
    # PLG-5a's; until it lands, a VM on another node stays refused — the
    # pre-registered shipping state.
    DESTROY_SELF_RUNG_REFUSAL = 'Destroying a virtual machine on a computer other than this compute ' \
                                'resource’s own endpoint is refused until per-node addressing lands: ' \
                                'the name the endpoint gives itself did not match the machine’s ' \
                                'computer name. Nothing was stopped and nothing was deleted.'

    DISK_REFUSAL = 'Removing disks from a virtual machine is refused in every Hyper-V compute resource ' \
                   'in this plugin version. All disk removals and VM destroys on cluster compute ' \
                   'resources are refused in code until FOG-10, PLG-15b and PLG-21b have merged and ' \
                   '(m) and its (k″) rows have landed; removal based solely on an absent role ' \
                   'additionally requires a named method that proves node-set completeness; ' \
                   'enablement is a code PR, not a configuration.'

    # PLG-22: the enablement set. Everything this PR unlocks stands on five
    # behaviours of the fog it is built against — the tri-state cluster reads,
    # the exact-host connection gate (FOG-11), the literal-path destructive
    # calls (FOG-14), the stdout hygiene contract (FOG-15) and the input
    # hardening (FOG-9) — and the runtime check asks the installed fog for ALL
    # of them: the constant list AND the per-behaviour predicate every client
    # of that build answers. A fog missing any one is the pre-enablement era
    # again, and every operation this PR unlocks refuses exactly as it refused
    # before. The constant is FOG-9's, and the plugin gate trusts it for the
    # rule behind it (R13): the builder validator and the connection gate are
    # ONE pure function there, so there is nothing here for a second list to
    # re-prove.
    ENABLEMENT_CAPABILITIES = {
      tri_state_cluster: :supports_clusters?,
      exact_host_connection: :supports_exact_host_connections?,
      literal_path_destructive: :supports_literal_path_destructive?,
      stdout_json_hygiene: :supports_stdout_json_hygiene?,
      input_hardening: :supports_input_hardening?
    }.freeze

    # The capability-era refusal: the plugin build is enabled, the installed
    # fog is not. Names the missing behaviours so the operator knows what to
    # upgrade, and quotes no remote text.
    FOG_CAPABILITY_REFUSAL = 'This operation is refused: the fog-hyperv this plugin runs against does ' \
                             'not answer every behaviour the enablement depends on (missing: ' \
                             '%<missing>s). Nothing was stopped, deleted or created. Upgrade ' \
                             'fog-hyperv to the build the plugin declares, or use a plugin version ' \
                             'whose refusals match the fog you have.'

    # The enablement era still refuses a destroy whose classification reads did
    # not answer: indeterminate is not a decision enablement can spend. The
    # machine stays exactly as it is, with the reads made again on the next
    # attempt — the same cost the pre-enablement unknown carried, worded for
    # the era where clustered machines ARE destroyable.
    DESTROY_INDETERMINATE_REFUSAL = 'Destroying a virtual machine on this Hyper-V compute resource is ' \
                                    'refused: the cluster classification reads did not answer on this ' \
                                    'attempt, and an unreadable endpoint is not a license to delete. ' \
                                    'Nothing was stopped and nothing was deleted; the reads are made ' \
                                    'again on the next attempt.'

    # F2's guard: a node-identity name is quoted into the remote guard script
    # only in this shape — a host or node name, nothing a shell or PowerShell
    # reads as special. A name outside it is refused before anything is sent:
    # the guard is a server-side check, not a string exercise, and a name that
    # cannot be quoted safely is not a name to dial.
    NODE_NAME_SHAPE = /\A[A-Za-z0-9][A-Za-z0-9.-]{0,252}\z/

    # What $env:COMPUTERNAME answers with is the NETBIOS computer name: up to 15
    # characters, uppercase. Cluster node lists and operator overrides carry the
    # full (possibly DNS, possibly longer) name, so the guard accepts the full
    # name AND its 15-character truncation, for the node's own name and for the
    # first label of the identity host. PowerShell's -in comparison is
    # case-insensitive, so no Ruby-side case folding rides the wire.
    NETBIOS_MAX_LENGTH = 15

    # The enabled era's disk-removal refusal: the fog is the enablement's
    # partner, but THIS disk's file cannot be proven safe to delete — its
    # path is not attributable to the machine, or its sharing state is not
    # proven absent (fog's own contract refuses a drive whose persistent
    # reservations are true or unread, because deleting a disk another running
    # machine reads destroys that machine's data). The whole edit refuses; no
    # part of it half-completes.
    DISK_UNATTRIBUTED_REFUSAL = 'Removing that disk is refused: its file is not attributable to this ' \
                                'machine’s folder or a storage root the hypervisor named, or its ' \
                                'sharing state is not proven absent, and deleting a disk another ' \
                                'machine may be reading destroys the wrong thing. Nothing was ' \
                                'detached and no file was deleted; the disk stays exactly as it is.'

    # The folder pre-flight, one round trip: the folder's existence, its
    # reparse/hidden attributes, and its descendants' names (recursive — the
    # config lives one level down). The tokens are fixed words, never remote
    # text beyond the child NAMES (which this parses but never re-quotes);
    # %<folder>s arrives from the string rule, already attributed and
    # single-quoted.
    FOLDER_PREFLIGHT_SCRIPT = <<~SCRIPT
      $p = %<folder>s
      if (-not (Test-Path -LiteralPath $p)) { 'ABSENT' }
      else {
        $i = Get-Item -LiteralPath $p -Force
        if ($i.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { 'KEEP:JUNCTION' }
        elseif ($i.Attributes -band [System.IO.FileAttributes]::Hidden) { 'KEEP:HIDDEN' }
        else { 'NAMES:' + ((Get-ChildItem -LiteralPath $p -Force -Recurse | ForEach-Object { $_.Name }) -join ';') }
      }
    SCRIPT

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

    # PLG-15c's belt-and-braces cluster-service state read. GetNodeClusterState
    # (clusapi.dll) — the enum is MS Learn fetched 2026-11-19 and every value
    # this gate acts on is a measured lab cell (hyperv-e-results §45.2, §46.4):
    # a healthy member reads 19, a stopped-joined one 3, and joined-and-Disabled
    # 1 — BYTE-IDENTICAL to never-joined, which is why the dual markers, not
    # this read, carry the maintenance refusal (plan §2 item 9's honest role
    # statement). 0 means "no cluster service or config", not "feature absent":
    # feature-absent (d19) and registration-destroyed (d23g) read it alike, and
    # the mid-removal cell answered rc=2 — which is why rc≠0 and a raising
    # P/Invoke are ALWAYS indeterminate (N2), never a feature-absent reading.
    # Hosts that block Add-Type (R11: Constrained Language Mode, WDAC, AppLocker)
    # read indeterminate PERMANENTLY, so standalone destroy never unlocks on
    # them — the accepted availability trade, with a manual runbook in the docs.
    CLUSAPI_NO_CLUSTER_SERVICE = 0
    CLUSAPI_NOT_CONFIGURED = 1
    CLUSAPI_NOT_RUNNING = 3
    CLUSAPI_RUNNING = 19

    # The two stores the state-0 branch additionally asks about, read with the
    # same named-primitive discipline as the markers (N3): the service record is
    # what the lab measured it as — the ClusSvc service key itself, opened with
    # the primitive whose not-found answer row (v) measured — and the cluster
    # directory is read the same way but is NOT a configured-marker: an evicted
    # node keeps it as an empty husk and a feature install recreates it empty
    # (twice measured, §45.2/§46.5), so the gate consults it only where the
    # plan's B9/N2 rule names it, beside a missing service record.
    SERVICE_RECORD_READ = {
      cmdlet: 'Get-ItemProperty',
      path: 'HKLM:\SYSTEM\CurrentControlSet\Services\ClusSvc'
    }.freeze
    CLUSTER_DIRECTORY_READ = {
      cmdlet: 'Get-Item',
      path: 'C:\Windows\Cluster'
    }.freeze
    # The reviewed P/Invoke definition, carried as a constant so the script
    # built further below never breaks the length rule. Nothing else reaches
    # it; it sits with the two reads it belongs to, not in the private
    # section (Lint/UselessConstantScoping).
    CLUSTER_API_SIGNATURE = '[DllImport("clusapi.dll", CharSet=CharSet.Unicode, SetLastError=true)] ' \
                            'public static extern int GetNodeClusterState(' \
                            'string pszNodeName, out uint pdwClusterState);'

    # PLG-5a: the shape of one `NODE = host[:port]` line of the operator's
    # node→endpoint override. Both sides are bare host names — never a
    # scheme, never a path, never whitespace. A value outside the shape is
    # REFUSED at save, not sanitized: the whole point of the override is that
    # exactly one string becomes the endpoint, and a silently repaired value
    # hides which string that was. (Backticks refused, not stripped — the
    # PLG-15 discipline.)
    NODE_OVERRIDE_HOST = /\A[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*\z/
    NODE_OVERRIDE_PORT = /\A[1-9][0-9]{0,4}\z/
    # R17's enforcement point for "fail-closed until PLG-5b": the check runs
    # on the COMPOSED endpoint, not the override string — the compute resource
    # supplies scheme and TLS, so an https resource would otherwise compose an
    # https node endpoint and simply WORK, unvalidated. Only the measured
    # http+negotiate pattern (the d20/d21 rows) is composed; the refusal names
    # the composition it refused out loud.
    NODE_ENDPOINT_REFUSAL = 'Refusing to reach a cluster node through %<endpoint>s: the composed ' \
                            'per-node endpoint is not the measured http+negotiate transport, and ' \
                            'hardened transports stay refused until PLG-5b has validated them. ' \
                            'No node operation was attempted.'

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
    validate :hyperv_node_overrides_shape
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
      client.hosts.first ? nil : format(_('%<url>s did not return a Hyper-V host'), url: url)
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
      associate_by('mac', vm.network_adapters.map(&:mac))
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

      # PLG-15b opened creates for stand-alone machines; PLG-22 enables the
      # cluster create path — with the era rule the destroy path uses too:
      # a fog that does not answer the five behaviours gets the pre-enablement
      # refusals verbatim (the cluster ask refused before any read of the
      # endpoint, the stand-alone gate refusing on every unknown), and only
      # the enablement's partner fog runs the unlocked path below.
      unless enablement_supported?
        raise ForemanHyperv::OperationRefused, CLUSTER_CREATE_REFUSAL if attr[:cluster_name].present?
        raise ForemanHyperv::OperationRefused, STANDALONE_CREATE_REFUSAL unless create_allowed?
      end

      attr = vm_instance_defaults.merge(attr)
      attr.delete :computer_name if attr[:computer_name].blank?
      start = Foreman::Cast.to_bool(attr.delete(:start))

      apply_firmware_attributes(attr)

      validate_vm(attr, new: true)
      validate_interfaces(attr)
      validate_volumes(attr)

      # The enabled era's membership rule: every placement string the form
      # carries (computer_name, cluster_name, per-volume datastore) must be a
      # member of what the hypervisor itself reports — the character allowlist
      # ran first (validate_hash! above), the membership reads are unfiltered,
      # and a read that does not answer refuses the create. The pre-enablement
      # era needs none of this on the create path: its gate already refused
      # anything the endpoint read as clustered, and the self-rung check below
      # decides its one allowed target.
      validate_placement!(attr) if enablement_supported?

      # logger.debug "Creating VM with arguments; #{attr}"
      cluster = cluster_named(attr[:cluster_name])
      storage = placement_storage(cluster, attr)

      # The identity ladder (N6), decided before the model is built so the
      # model rides the RIGHT client: the self rung serves through this
      # resource's own client; a named node reaches its SEPARATE per-node
      # client only through the operator override (PLG-5a — the only source
      # of FQDN identity), with the override's identity spliced into the
      # model's computer name (N4); a named node with no override is
      # per-node addressing with nothing to dial, and stays refused — the
      # same fail-closed the reads use. In the pre-enablement era the named
      # target had nowhere to go anyway, and the self-rung check below
      # answers exactly as it did before.
      build_client = client
      computer = attr[:computer_name].presence
      routed_via_override = false
      if enablement_supported? && computer && !self_rung_name?(computer)
        override = node_override(computer)
        raise ForemanHyperv::OperationRefused, SELF_RUNG_REFUSAL if override.nil?

        build_client = client_for_node(computer)
        computer = override.split(':', 2).first
        routed_via_override = true
      end

      vm = build_client.servers.new(
        name: attr[:name],
        computer_name: computer || hypervisor.name,
        generation: attr[:generation],
        dynamic_memory_enabled: Foreman::Cast.to_bool(attr[:dynamic_memory_enabled]),
        memory_startup: attr[:memory_startup].to_i,
        memory_minimum: attr[:memory_minimum].to_i,
        memory_maximum: attr[:memory_maximum].to_i,
        processor_count: attr[:processor_count].to_i,
        notes: attr[:notes]
      )
      # N6 self rung: a machine built through this resource's own client has
      # to carry the name the endpoint gives itself (Get-VMHost), compared
      # case-insensitively — an override-routed machine is the one exception
      # the ladder allows, its identity being the operator's own assertion
      # (validated at save) dialled through its own client. servers.new has
      # built a model and sent nothing, so this raise tears nothing down.
      raise ForemanHyperv::OperationRefused, SELF_RUNG_REFUSAL unless routed_via_override || self_rung?(vm)

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
        # The rollback stays what PLG-15b made it for the drives: DETACHED,
        # not deleted — a strand's disk files may include a pre-existing disk
        # the form attached, and no rollback may destroy a file it did not
        # prove this strand created. The machine's own folder is the one piece
        # a post-enablement rollback CAN decide (the two-root rule plus its
        # pre-flight below), and it decides it only with the survivor rule:
        # any disk file still living inside the folder keeps the folder,
        # because the folder delete recurses and a silent attach-disk loss is
        # exactly what the rule exists to stop. The pre-enablement era keeps
        # the literal false it shipped with. remove_cluster_role is live now:
        # the enabled cluster create path reaches this rollback with a role
        # the strand provably added.
        remove_cluster_role(vm) if role_added
        vm.stop
        vm.hard_drives.each { |hdd| hdd.destroy(underlying: false) }
        vm.destroy(enablement_supported? && rollback_folder_delete?(vm))
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
        security.change_key_protector :new if security.tpm_enabled && security.key_protector.nil?
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
      # PLG-15c opened destroy for proven-stand-alone machines; PLG-22
      # enables it. The lookup still comes first (the gate and the teardown
      # decide on the machine fog reported), the id is still validated before
      # anything else, and a fog that answers no machine at all is still the
      # same nothing the rescue answers "done" for.
      ForemanHyperv::InputValidation.validate_id!(uuid)
      vm = find_vm_by_uuid(uuid)
      return true if vm.nil?

      unless enablement_supported?
        # The pre-enablement gate, verbatim: a fog that does not answer the
        # five behaviours gets the refusals this plugin shipped with, word for
        # word — enablement is a property of the fog+plugin pair, and the
        # plugin does not run a decision its partner cannot keep.
        case standalone_destroy_state(vm)
        when :standalone
          nil
        when :clustered
          raise ForemanHyperv::OperationRefused, DESTROY_REFUSAL
        when :not_self
          raise ForemanHyperv::OperationRefused, DESTROY_SELF_RUNG_REFUSAL
        else
          raise ForemanHyperv::OperationRefused, STANDALONE_DESTROY_REFUSAL
        end
        vm.stop turn_off: true
        vm.hard_drives.each { |hdd| hdd.destroy(underlying: false) }
        vm.destroy(false)
        return true
      end

      # The enabled era. The classification reads are still made — they record
      # sightings and they still refuse an unknown — but a clustered answer is
      # now a shape, not a refusal: the machine is un-clustered first, then
      # deleted. Everything decidable is decided BEFORE anything is mutated:
      # the folder verdict (one pre-flight script, fog's literal-path guard on
      # fog's side) and each drive's file verdict (call-site attribution plus
      # the model's own sharing read), so a destroy whose decisions could not
      # be read keeps exactly the pieces it could not decide, not a
      # half-torn-down machine guessing the rest.
      state = standalone_destroy_state(vm)
      raise ForemanHyperv::OperationRefused, DESTROY_INDETERMINATE_REFUSAL if state == :indeterminate
      # The enablement unlocks CLUSTERED machines; a stand-alone-proven
      # endpoint wearing someone else's machine name is still per-node
      # addressing, and that stays PLG-5b's, refusing with the same sentence
      # as before: an enabled plugin does not stretch further than its own
      # reviewed unlocks.
      raise ForemanHyperv::OperationRefused, DESTROY_SELF_RUNG_REFUSAL if state == :not_self

      machine_folder = folder_deletion_path(vm)
      folder_delete = !machine_folder.nil? && folder_preflight(vm, machine_folder) == :ok
      drive_deletes = []
      vm.hard_drives.each do |hdd|
        delete_file = drive_deletion_allowed?(vm, hdd)
        if !delete_file && file_lives_in?(hdd, machine_folder)
          # The folder delete recurses. A file this destroy refused to delete
          # must not be taken by the recursion it inherits — that is the same
          # silent wrong-thing in a new costume — so a kept file inside the
          # machine's folder keeps the folder too.
          logger.warn "The disk file #{hdd.path} of #{vm.name} stays, and its folder with it: " \
                      'a folder delete that recurses over a file this destroy refused is not a verdict'
          folder_delete = false
        end
        drive_deletes << [hdd, delete_file]
      end

      vm.stop turn_off: true
      # The role only when the machine reports one: fog's removal asserts a
      # matching role before it deletes anything, and a machine the cluster
      # does not hold has nothing to release. A cluster that will not give the
      # role up stops the destroy here — before the machine or a file goes.
      remove_cluster_role(vm) if vm.respond_to?(:clustered?) && vm.clustered?
      drive_deletes.each { |hdd, delete_file| hdd.destroy(underlying: delete_file) }
      vm.destroy(folder_delete)
      true
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
              "Scheduling compute instance update because #{k_path.join('.')} " \
                "changed it's value from '#{old_v}' (#{old_v.class}) " \
                "to '#{new_v}' (#{new_v.class})"
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
    # PLG-15b opens creates for stand-alone machines only; PLG-15c opens
    # destroys for stand-alone machines only (standalone_destroy_state below);
    # disk removals stay refused everywhere and every cluster path stays
    # locked behind the canonical enablement sentence the refusal messages
    # quote — those lifts belong to the enablement PR. Lifting a guard is a
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

    def disk_removal_allowed?
      enablement_supported?
    end

    # --- PLG-22: the enablement and its runtime check ---------------------------

    # Every behaviour the enablement stands on, asked of the fog actually
    # installed: the CAPABILITIES constant AND the predicate every client of
    # that build answers (a fog that has the list but not the behaviour, or
    # the behaviour but not the list, is not this build's partner). A fog too
    # old to even define CAPABILITIES answers "everything missing" — the
    # pre-enablement era, refusing exactly what it refused before enablement.
    # The whole check is a local constant read and five respond_to?/predicate
    # calls on the client object: no wire traffic, and it is safe to ask on
    # every operation.
    # @return [Boolean] does the installed fog answer all five?
    def enablement_supported?
      missing_enablement_capabilities.empty?
    end

    # The capabilities the installed fog does NOT answer, in the order of the
    # frozen list — empty means enablement stands. A predicate that raises is
    # an unanswered predicate, same as a missing one: the check asks the fog,
    # and an fog that cannot answer has not answered.
    # @return [Array<Symbol>] the missing behaviour names, for the refusal
    def missing_enablement_capabilities
      list = Fog::Hyperv.const_defined?(:CAPABILITIES) ? Fog::Hyperv::CAPABILITIES : []
      ENABLEMENT_CAPABILITIES.select do |capability, predicate|
        list.exclude?(capability) || !client_answers?(capability, predicate)
      end.keys
    rescue StandardError
      ENABLEMENT_CAPABILITIES.keys
    end

    def client_answers?(capability, predicate)
      client.respond_to?(predicate) && client.public_send(predicate) == true
    rescue StandardError => e
      logger.warn "The fog capability check for #{capability} did not answer: #{e.class}"
      false
    end

    # The refusal every unlocked operation answers with when the fog is not
    # the enablement's partner — one message, naming what is missing, quoting
    # no remote text (the names are this file's constants).
    def refuse_without_enablement!
      missing = missing_enablement_capabilities
      return if missing.empty?

      raise ForemanHyperv::OperationRefused, format(FOG_CAPABILITY_REFUSAL, missing: missing.join(', '))
    end

    # --- PLG-22: the two-root folder rule ---------------------------------------

    # The roots a machine's files may provably live under, from the endpoint's
    # own reports: the config root (virtual_machine_path), the disk root
    # (virtual_hard_disk_path — the two roots the folder rule must know both
    # of, measured ≠ on the lab host), and every shared volume of the cluster
    # the endpoint belongs to (a clustered machine's config folder lives on a
    # cluster shared volume, not on either node-local root). Nothing the user
    # typed is in this list; it is what the hypervisor itself named.
    #
    # A root that cannot be read is simply not a root: attribution against a
    # missing root fails closed (no delete), exactly as a missing shared-volume
    # listing leaves a clustered machine's folder unattributed.
    # @return [Array<String>] the normalized roots
    def storage_roots
      roots = []
      begin
        host = hypervisor
        roots << host.virtual_machine_path if host.respond_to?(:virtual_machine_path)
        roots << host.virtual_hard_disk_path if host.respond_to?(:virtual_hard_disk_path)
      rescue StandardError => e
        logger.warn "The endpoint could not name its storage roots for the delete decision: #{e.class}"
      end
      begin
        clusters.each do |cluster|
          next unless cluster.respond_to?(:shared_volumes)

          cluster.shared_volumes.each do |volume|
            roots << volume.volume_path if volume.respond_to?(:volume_path)
          end
        end
      rescue StandardError => e
        logger.warn "The cluster shared volumes could not be read for the delete decision: #{e.class}"
      end
      roots.map { |root| normalize_windows_path(root) }.reject(&:empty?).uniq
    end

    # Windows paths, made comparable: forward slashes to backslashes, repeated
    # separators collapsed, trailing separators trimmed (a root reported as
    # `C:\VMs\` and a path built as `C:\VMs\vm1` are the same folder). Case is
    # NOT folded here — the comparisons that consume this fold as they compare,
    # so the value stays quotable back to an operator read.
    def normalize_windows_path(path)
      path.to_s.tr('/', '\\').gsub(/\\{2,}/, '\\').sub(/\\\z/, '')
    end

    # The folder a machine's config lives in, deleted with the machine, only
    # when BOTH answers say so — and any answer that cannot be had says keep:
    #
    # 1. the string rule: the folder's own name is the machine's name (exact,
    #    case-insensitively) and it sits directly under one of the roots the
    #    hypervisor itself named (the two roots and the shared volumes), with
    #    that root spelled out in full — no 8.3 short-name root (a `PROGRA~1`
    #    segment could alias any long name, and attribution against an alias
    #    is not attribution) and no name shape a filesystem read could not
    #    tie back (`\ / : * ? " < > |`, a `..` segment, a trailing `.` or
    #    space, control or non-printing characters — all keep the folder);
    # 2. the wire preflight (measured exists shape, §45.4; folder-level
    #    collision itself NOT separately measured — stated): the folder is
    #    there, is not a reparse point (a junction's contents live wherever
    #    the junction points, and recursing through one deletes someone
    #    else's tree), is not hidden (a hidden folder wearing the machine's
    #    name is not provably the machine's), and its contents carry this
    #    machine's config — every `*.vmcx`/`*.vmrs` in it named for this
    #    machine, and at least one `.vmcx` present.
    #
    # @return [Boolean] delete the folder with the machine (fog's destroy(true))
    def destroy_folder?(vm)
      folder = folder_deletion_path(vm)
      return false unless folder

      case folder_preflight(vm, folder)
      when :ok
        true
      when :absent
        logger.info "The config folder #{folder} of #{vm.name} is already gone; nothing to delete with it"
        false
      else
        false
      end
    end

    # The string rule alone, without the wire read: the folder path if the
    # name and root attribution hold, nil if not. Kept apart from destroy_folder?
    # so the create-rollback decision and the pre-flight gate read the same rule,
    # and so a path the rule refuses never reaches the pre-flight script at all.
    def folder_deletion_path(vm)
      name = vm.name.to_s
      path = normalize_windows_path(vm.path)
      return nil if name.empty? || path.empty?

      # The name shape a filesystem read could tie back: no path or wildcard
      # characters, no control or non-printing characters, no traversal
      # segment (`..` anywhere — the plan's red list), no trailing `.` or
      # space (Windows trims them and the trimmed folder is not provably the
      # named one). A single dot inside the name is legal (vm.old is a VM
      # name); a component bound at Windows' own 255.
      return nil unless name.match?(%r{\A[^\\/:*?"<>|\x00-\x1f](?:[^\\/:*?"<>|\x00-\x1f]| )*[^\\/:*?"<>|\x00-\x1f]?\z})
      return nil if name.include?('..') || name.match?(/[. ]\z/)
      return nil unless name.length <= 255
      return nil if path.split('\\').any? { |segment| segment == '..' }
      return nil if path.split('\\').any? { |segment| segment.match?(/~\d+\z/) }

      folder_name = path.split('\\').last.to_s
      return nil unless folder_name.casecmp(name).zero?

      parent = normalize_windows_path(path.split('\\')[0..-2]&.join('\\'))
      return nil if parent.empty?

      roots = storage_roots
      return nil if roots.empty?

      roots.any? { |root| parent.casecmp(root).zero? } ? path : nil
    end

    # The wire half, one script, one round trip: exists, attributes, contents
    # in a single answer. The path riding the script is one the string rule
    # already attributed (its components matched a hypervisor-named root and a
    # clean machine name) — the escaping is belt, the string rule is braces.
    # Any read that cannot be had (fog error, unparsable answer) keeps the
    # folder: the pre-flight licenses the delete, and no answer licenses nothing.
    # @return [Symbol] :ok, :absent, or :keep (with the reason logged)
    def folder_preflight(vm, folder)
      quoted = "'#{folder.gsub("'", "''")}'"
      script = format(FOLDER_PREFLIGHT_SCRIPT, folder: quoted)
      out = vm.service.run_cmd(script, _skip_json: true)
      answer = out.stdout.to_s.strip
      case answer
      when 'ABSENT' then :absent
      when 'KEEP:JUNCTION' then keep_folder(folder, 'it is a reparse point (junction or symlink)')
      when 'KEEP:HIDDEN' then keep_folder(folder, 'it is hidden')
      when /\AFORBIDDEN:/ then keep_folder(folder, 'the remote refused the path itself')
      when /\ANAMES:/ then folder_contents_ok?(vm, folder, answer.delete_prefix('NAMES:'))
      else keep_folder(folder, 'the pre-flight answer was not the shape this rule understands')
      end
    rescue StandardError => e
      logger.warn "The config-folder pre-flight for #{folder} did not answer (#{e.class}); the folder stays"
      :keep
    end

    def keep_folder(folder, reason)
      logger.info "The config folder #{folder} stays: #{reason}"
      :keep
    end

    # The content attribution, measured against the layout the hypervisor
    # actually writes: the config lives ONE LEVEL DOWN in `Virtual Machines\`
    # and is named for the machine's GUID (`{id}.vmcx`, `{id}.vmrs`), not for
    # its name — so attribution runs on the id (the machine name second, for
    # any layout that spells it), and the read is recursive. A second
    # machine's config in this folder is the collision the rule exists for —
    # recursing would delete both. Snapshots, avhdx files and the snapshot
    # directories carry no config signature and pass with the folder.
    def folder_contents_ok?(vm, folder, names_blob)
      names = names_blob.split(';').map(&:strip).reject(&:empty?).map(&:downcase)
      configs = names.select { |n| n.end_with?('.vmcx', '.vmrs') }
      attributed = [vm.id.to_s.downcase, vm.name.to_s.downcase]
      foreign = configs.reject { |n| attributed.include?(n.sub(/\.(vmcx|vmrs)\z/, '')) }
      return keep_folder(folder, 'another machine’s config file lives in it') unless foreign.empty?

      unless configs.any? { |n| n.end_with?('.vmcx') && attributed.include?(n.delete_suffix('.vmcx')) }
        return keep_folder(folder, 'this folder holds no config file of this machine')
      end

      :ok
    end

    # A create rollback's folder verdict (see the rollback in create_vm): the
    # machine's own folder per the two-root rule and its pre-flight, kept if
    # any disk file still lives inside it — the rollback detached every drive
    # without deciding any file, so an attached pre-existing disk inside the
    # folder is a survivor by definition, and the recursing folder delete
    # would take it without being asked to.
    def rollback_folder_delete?(vm)
      machine_folder = folder_deletion_path(vm)
      return false unless machine_folder
      return false unless folder_preflight(vm, machine_folder) == :ok

      survivor = vm.hard_drives.any? { |hdd| file_lives_in?(hdd, machine_folder) }
      if survivor
        logger.warn "The config folder of #{vm.name} keeps itself: a disk file still lives in it, " \
                    'and the rollback detached rather than decided it'
        false
      else
        true
      end
    end

    def file_lives_in?(hdd, folder)
      parent = normalize_windows_path(hdd.path.to_s.split('\\')[0..-2]&.join('\\'))
      !parent.empty? && parent.casecmp(folder.to_s).zero?
    end

    # --- PLG-22: the drive rule (call-site path check) ----------------------------

    # A disk file is deleted (not just detached) only when its path is
    # attributable to this machine the same way the folder is: its parent
    # folder is this machine's folder or one of the roots the hypervisor
    # named, no traversal or short-name segment, and no fog error along the
    # way. The fog model's own sharing check rides the delete itself
    # (destroy(underlying: true) refuses a drive whose persistent-reservations
    # state is not proven absent — SharedDiskDeleteRefused), and this plugin
    # reads that same property before the wire so a destroy whose disk cannot
    # be proven unshared detaches and leaves the file rather than failing
    # half-torn-down: an orphaned file is recoverable, a wrongly deleted one
    # is not.
    # @return [Boolean] delete the file with the detach
    def drive_deletion_allowed?(vm, hdd)
      path = normalize_windows_path(hdd.path)
      return false if path.empty?
      return false if path.split('\\').any? { |segment| segment == '..' || segment.match?(/~\d+\z/) }

      parent = normalize_windows_path(path.split('\\')[0..-2]&.join('\\'))
      machine_folder = folder_deletion_path(vm)
      roots = storage_roots
      return false if roots.empty?

      attributable = parent.casecmp(machine_folder.to_s).zero? || roots.any? { |root| parent.casecmp(root).zero? }
      return false unless attributable

      if hdd.respond_to?(:support_persistent_reservations) && hdd.support_persistent_reservations != false
        logger.warn "The disk #{path} of #{vm.name} keeps its file: its sharing state reads " \
                    "#{hdd.support_persistent_reservations.inspect}, and only a proven-absent one licenses the delete"
        return false
      end
      true
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

    # --- PLG-15c: the stand-alone destroy gate ---------------------------------------

    # The rule as plan §2 item 9 writes it, in the plan's own order, and every
    # reading is made again on this attempt — there is nothing to configure and
    # nothing is cached. The answers it gives: :standalone (every condition
    # provably met), :clustered (any reading that makes this a cluster compute
    # resource by the definition — a stored sighting, a reported role, a
    # membership row, a present marker, a joined or maintenance service state),
    # :indeterminate (anything that says nothing: denied reads, unparsable
    # tokens, rc≠0, a raising P/Invoke, an unreadable ledger), and :not_self
    # (the machine's computer name re-read at destroy time is not the name the
    # endpoint gives itself — per-node addressing is PLG-5a's). Destroy-side
    # safety on the accepted-on-argument broken-node shape (§47.4, d23g) rides
    # on the ledger alone, with its pre-15b blind spot — stated plainly in the
    # plan and nowhere hidden here.
    def standalone_destroy_state(vm)
      return :clustered if sticky_cluster_sighting?

      # The machine's own reported role, before any gate read: a role is a
      # claim on config and disks no stand-alone proof can talk anyone out of.
      # B6's mirror on the destroy side (plan §2 item 9): every clustered
      # observation the gate makes lands on the insert-only ledger before the
      # refusal returns — the membership read already records its own row, so
      # the readings this gate adds append theirs here, and a later run of
      # clean reads can never unlock this endpoint.
      if vm.respond_to?(:clustered?) && vm.clustered?
        persist_cluster_sighting(kind: 'sighting', reason: 'the machine fog reported a cluster role')
        return :clustered
      end

      case cluster_membership_state
      when :not_clustered
        nil
      when :clustered
        # The sighting went out with the read itself (cluster_membership_state
        # appends it); this branch only decides and refuses.
        logger.warn 'Refusing to destroy a virtual machine: the endpoint answered a cluster membership row'
        return :clustered
      else
        logger.warn 'Refusing to destroy a virtual machine: the cluster membership read did not answer'
        return :indeterminate
      end

      MARKER_READS.each_key do |marker|
        state = marker_state(marker)
        case state
        when :absent
          next
        when :present
          # Both stores present under a not-clustered membership read is the
          # measured maintenance shape (d22): "not proven stand-alone" is
          # exactly what the definition of a cluster compute resource turns on.
          persist_cluster_sighting(kind: 'sighting', reason: "the #{marker} cluster marker read answered present")
          logger.warn "Refusing to destroy a virtual machine: the #{marker} marker read answered present"
          return :clustered
        else
          logger.warn "Refusing to destroy a virtual machine: the #{marker} marker read answered #{state}"
          return :indeterminate
        end
      end

      case cluster_service_state
      when :standalone
        nil
      when :clustered
        persist_cluster_sighting(kind: 'sighting', reason: 'the cluster-service state read answered joined')
        logger.warn 'Refusing to destroy a virtual machine: the cluster-service state read answered joined'
        return :clustered
      else
        logger.warn 'Refusing to destroy a virtual machine: the cluster-service state read did not answer'
        return :indeterminate
      end

      # The destroy-time re-read (plan §2 item 9): the machine is where the
      # endpoint says it is, or the destroy is per-node addressing wearing a
      # UUID.
      return :not_self unless self_rung?(vm)

      :standalone
    end

    # B6's ledger read, on the destroy side: a sticky sighting is the endpoint's
    # own past, and the definition is a SIGHTING row — a strand record is one
    # machine with an unresolved role write, not an endpoint that ever answered
    # as a cluster, and it does not make a host sticky. An endpoint that does
    # not parse to a host, or a ledger that cannot be read, answers sticky: the
    # gate's "no sticky sighting" is not provable there, and B6's rule is that
    # an unreadable ledger is a refusal, not an absence.
    def sticky_cluster_sighting?
      host = endpoint_host_name
      unless host
        logger.warn 'The destroy gate could not ask the ledger: the configured endpoint does not name a host'
        return true
      end

      ForemanHyperv::ClusterSighting.exists?(endpoint_host: host, kind: 'sighting')
    rescue ActiveRecord::ActiveRecordError => e
      logger.warn "The destroy gate could not read the sightings ledger: #{e.class}"
      true
    end

    # The clusapi leg, read entirely server-side as one command answering one
    # JSON token: the P/Invoke's rc and state, the service record's answer and
    # the cluster directory's answer — each through typed catches, so absent is
    # only ever the measured not-found exception (N3, the same discipline and
    # the same catch table as the marker read). The acceptance set is measured
    # shapes only: state 1 with the service record present (never-joined,
    # §45.2), and state 0 with the service record AND the cluster directory
    # also answering not-found — the B9/N2 branch, where the marker loop has
    # already read PARAMS and CLUSDB not-found, so all three stores are gone
    # (d19, d23g). State 1 beside a missing record, and state 0 under a present
    # record, are shapes no measurement produced — they read indeterminate, and
    # so does every rc≠0 and every raising call (N2).
    def cluster_service_state
      out = client.run_cmd(cluster_service_read_script, _skip_json: true)
      reply = out.stdout.to_s.strip
      return :indeterminate if reply.empty? || reply.length > 2_048

      token = Fog::JSON.decode(reply)
      return :indeterminate unless token.is_a?(Hash)
      return :indeterminate unless %w[clusapi svc cdir].all? { |leg| token[leg].is_a?(Hash) }

      clusapi = token['clusapi']
      unless clusapi['result'].to_s == 'ok' && clusapi['rc'].is_a?(Integer) && clusapi['state'].is_a?(Integer)
        logger.warn "The cluster-service state read did not answer: #{sanitize_text(clusapi['type'].to_s)}"
        return :indeterminate
      end
      return :indeterminate unless clusapi['rc'].zero?

      service_record = token['svc']['result'].to_s
      case clusapi['state']
      when CLUSAPI_RUNNING, CLUSAPI_NOT_RUNNING
        :clustered
      when CLUSAPI_NOT_CONFIGURED
        # clusapi=1 beside a service record that is not present is not a cell
        # the battery ever produced, and the plan names it indeterminate.
        return :standalone if service_record == 'present'

        logger.warn "Refusing to trust clusapi=1 with the service record answered #{service_record}"
        :indeterminate
      when CLUSAPI_NO_CLUSTER_SERVICE
        # The 0 means "no cluster service or config" (d23g): accepted, as the
        # plan argues, exactly when every store says gone — the markers above,
        # the service record here, and the cluster directory here. Anything
        # else under a 0, including the never-measured record-present shape,
        # says nothing.
        cluster_directory = token['cdir']['result'].to_s
        return :standalone if service_record == 'absent' && cluster_directory == 'absent'

        logger.warn "Refusing to trust clusapi=0 with the service record #{service_record} " \
                    "and the cluster directory #{cluster_directory}"
        :indeterminate
      else
        :indeterminate
      end
    rescue StandardError => e
      # fog raising at all — transport, auth, parse — says nothing (N3).
      logger.warn "The cluster-service state read did not answer: #{e.class}"
      :indeterminate
    end

    # The script the service-state read runs. Three named primitives, typed
    # catches carrying the full exception class on every token, one JSON line:
    # the P/Invoke under its own type guard (a warm runspace already knows the
    # type), the service registry key opened with the same primitive whose
    # not-found answer row (v) measured for the PARAMS marker, and the cluster
    # directory opened with Get-Item. Only the two path constants and the
    # reviewed P/Invoke definition are interpolated — no user input is anywhere
    # near it, and the whole read is one command.
    def cluster_service_read_script
      svc = SERVICE_RECORD_READ
      cdir = CLUSTER_DIRECTORY_READ
      <<~CLUSTER_SERVICE_READ
        $ForemanHypervServiceRead = [pscustomobject]@{ clusapi = $null; svc = $null; cdir = $null }
        $ForemanHypervCluster = [pscustomobject]@{ result = 'error'; rc = $null; state = $null; type = $null }
        try {
          if (-not ('ForemanHyperv.ClusterApi' -as [type])) {
            Add-Type -Namespace ForemanHyperv -Name ClusterApi -ErrorAction Stop `
              -MemberDefinition '#{CLUSTER_API_SIGNATURE}'
          }
          $ForemanHypervState = [uint32]0
          $ForemanHypervRc = [ForemanHyperv.ClusterApi]::GetNodeClusterState($null, [ref]$ForemanHypervState)
          $ForemanHypervCluster.result = 'ok'
          $ForemanHypervCluster.rc = $ForemanHypervRc
          $ForemanHypervCluster.state = $ForemanHypervState
        } catch {
          $ForemanHypervCluster.type = $_.Exception.GetType().FullName
        }
        $ForemanHypervServiceRead.clusapi = $ForemanHypervCluster
        $ForemanHypervSvc = try {
          $null = #{svc[:cmdlet]} -LiteralPath '#{svc[:path]}' -ErrorAction Stop
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
        $ForemanHypervServiceRead.svc = $ForemanHypervSvc
        $ForemanHypervCdir = try {
          $null = #{cdir[:cmdlet]} -LiteralPath '#{cdir[:path]}' -ErrorAction Stop
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
        $ForemanHypervServiceRead.cdir = $ForemanHypervCdir
        $ForemanHypervServiceRead | ConvertTo-Json -Compress
      CLUSTER_SERVICE_READ
    end

    # N6's self rung: the endpoint's own Get-VMHost name against the machine's
    # computer name, case-insensitively. A name that does not match — or an
    # endpoint that cannot name itself — is refused: per-node addressing is
    # PLG-5a's, and "fail-closed until PLG-5a" lives here until that PR lands
    # (the pre-registered shipping state, not an oversight).
    def self_rung?(vm)
      self_rung_name?(vm&.computer_name)
    end

    # The same rung for a name before any model exists (the create path
    # decides which client to build on): case-insensitive equality with the
    # name the endpoint gives itself over Get-VMHost. An endpoint that cannot
    # name itself matches nothing.
    def self_rung_name?(asked)
      asked = asked.to_s.strip
      return false if asked.empty?

      host_name = hypervisor.name.to_s.strip
      return false if host_name.empty?

      asked.casecmp(host_name).zero?
    rescue StandardError => e
      logger.warn "The endpoint could not name itself for the self-check: #{e.class}"
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
    #
    # F2 (due before this PR, and landed here): when the enablement stands, the
    # removal rides a two-element cmdlist whose FIRST element is the node-identity
    # guard — every connection shell is its own shell (measured), so a guard in a
    # separate read could answer for one machine and the mutation run on another.
    # The guard throws server-side when the machine dialled is not the node named,
    # and fog's own error detection carries that out as a refusal; the second
    # element is fog's own removal script, whose readback (the measured
    # ClusterObjectNotFound miss) is the proof the removal happened — the plugin
    # duplicates nothing of that contract, it only composes the guard in front.
    # An older fog without the script utility or the cmdlist API keeps the plain
    # request call, unguarded, exactly as before enablement.
    def remove_cluster_role(vm)
      node = ((vm.respond_to?(:owner_node) && vm.owner_node.presence) || vm.computer_name).to_s.strip
      service = vm.service || client

      # Validated before composing anything: an id that is not an id is the
      # user's bad input, not a cluster that refused.
      ForemanHyperv::InputValidation.validate_id!(vm.id)
      # Composed before any rescue can fold it: a name that cannot be quoted
      # into the guard is refused as itself, not as a cluster that "would not
      # release the role" — it never reached the cluster.
      guard = guarded_role_guard(node)

      begin
        if guard
          script = Fog::Hyperv::Utils::ClusterRole.build_removal_script(vm.id)
          out = service.run_cmdlist([[guard, {}], [script, {}]], target_computer: node, skip_json: true)
          # fog's own removal contract, kept at the call site that composes it:
          # the script prints nothing on any path, so a body is not an answer
          # this plugin knows.
          unless out.stdout.to_s.strip.empty?
            logger.warn 'The clustered role removal answered with a result body; it emits none'
            raise Foreman::Exception,
                  'Refusing to delete a clustered virtual machine while its role removal did not answer cleanly'
          end
        elsif client.respond_to?(:remove_cluster_virtual_machine_role)
          client.remove_cluster_virtual_machine_role(id: vm.id, computer_name: node)
        end
      rescue StandardError => e
        # A fog failure's own text can carry the remote command line, including
        # percent signs, and Foreman::Exception sprintfs its message again when
        # it renders: the class is quoted, the text is not.
        logger.warn "The Hyper-V cluster would not release the role: #{e.class}"
        raise Foreman::Exception,
              'Refusing to delete a clustered virtual machine while the cluster still holds its role'
      end
    end

    # The guard script, or nil when this build/era does not compose one (the
    # pre-enablement fog paths). The candidates are the node's own name and the
    # first label of the identity that reaches it — each with its 15-character
    # truncation, because $env:COMPUTERNAME answers the NETBIOS name, which is
    # uppercase and capped at 15 while cluster reads and operator overrides
    # carry the full DNS-flavoured name (memory of the lab, pre-registered as
    # the >15-character red test: the guard must not false-refuse a long name
    # that is honestly the machine's own). PowerShell's -notin is
    # case-insensitive; no case folding rides the wire beyond these terms.
    def guarded_role_guard(node)
      return nil unless enablement_supported?
      return nil unless client.respond_to?(:run_cmdlist) && cluster_role_script_available?

      identity = node_override(node).to_s.split(':', 2).first.to_s
      candidates = [node, identity.split('.').first].reject { |c| c.to_s.empty? }
      candidates.each do |candidate|
        unless candidate.match?(NODE_NAME_SHAPE)
          raise ForemanHyperv::OperationRefused,
                'Refusing to remove a cluster role while the target node name is not a name this ' \
                'plugin can put through its identity guard; nothing was asked of the host with that name'
        end
      end
      terms = candidates.flat_map { |c| [c, c[0, NETBIOS_MAX_LENGTH]] }.map(&:downcase).uniq
      quoted = terms.map { |term| "'#{term.gsub("'", "''")}'" }.join(', ')
      %(if ($env:COMPUTERNAME -notin @(#{quoted})) { throw "foreman_hyperv node identity mismatch: $env:COMPUTERNAME" })
    end

    # The utility ships with the fog the enablement names; an older fog raises
    # LoadError or simply lacks the builder, and both answer "no guard for you"
    # — the legacy request path runs instead, unguarded, as it did before.
    def cluster_role_script_available?
      require 'fog/hyperv/utils/cluster_role'
      Fog::Hyperv::Utils::ClusterRole.respond_to?(:build_removal_script)
    rescue LoadError, NameError
      false
    end

    # The machine as the node that owns it right now sees it, or nil when no cluster
    # role claims it — the whole point being the case where the endpoint no longer
    # answers for it. Every action on a machine starts with this lookup, so the
    # node this asks is addressed by an IDENTITY that resolves, never by the
    # role's unqualified name (N5, §45.3): the override host when the operator
    # supplied one (PLG-5a), the endpoint host when the owner is the endpoint's
    # own node, and nothing at all otherwise — a node without usable identity
    # is refused its reads, and no fog call carries its name.
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

      owner = role.owner_node.to_s.strip
      override = node_override(owner)
      drop_hypervisor_list_unless_named(owner)
      if override
        identity_host = override.split(':', 2).first
        logger.info "Virtual machine #{uuid} is owned by cluster node #{owner}, reading it from its override endpoint"
        return client_for_node(owner).servers.get(uuid, computer_name: identity_host)
      end

      if endpoint_serves_node?(owner)
        logger.info "Virtual machine #{uuid} is owned by this endpoint's own node, reading it here"
        return client.servers.get(uuid, computer_name: endpoint_host_name)
      end

      # Fail closed (N6, pre-registered): fog would take this name to its
      # completion sink — the prefix-cache path that can complete against the
      # WRONG endpoint and fake a pass (R22) — so the name never leaves here.
      logger.warn "Virtual machine #{uuid} is owned by cluster node #{owner}: this compute resource " \
                  'has no node→endpoint override for it, so reads through that node are refused ' \
                  'until hyperv_node_overrides carries it (or PLG-5b discovers the address)'
      nil
    rescue StandardError => e
      raise if e.is_a?(ForemanHyperv::UnsafeIdentifier)

      # A refusal to compose (R17) is a decision, not an unreadable wire: it
      # travels up as itself instead of being folded into the nil that says
      # "no owner answered" — the same rule cluster_membership_state applies
      # to the ledger's own refusal.
      raise if e.is_a?(ForemanHyperv::OperationRefused)

      logger.warn "Clustered lookup of virtual machine #{uuid} failed: #{e.message.lines.first}"
      nil
    end

    # --- PLG-5a: the operator node→endpoint override ---------------------------

    # The attribute parsed: downcased node names (the role carries NETBIOS
    # casing; the operator may type any), values exactly as written. A node
    # named twice means the last line wins — both were seen by the same shape
    # check, and refusing the save over which-of-two was meant would punish
    # the trailing comment-out with an error.
    def node_override_map
      @node_override_map ||= hyperv_node_overrides.to_s.each_line.filter_map do |line|
        next if line.strip.empty?

        node, value = line.split('=', 2)
        next if node.nil? || value.nil? || node.strip.empty? || value.strip.empty?

        [node.strip.downcase, value.strip]
      end.to_h
    end

    def node_override(node_name)
      node_override_map[node_name.to_s.strip.downcase]
    end

    # The composed per-node endpoint (N4): scheme, TLS and port come from the
    # compute resource; the override supplies ONLY the identity spliced in.
    # The path is /wsman because WinRM always answers there. The R17 check is
    # on this composition: an unparseable endpoint has no measured scheme
    # either, so it refuses too.
    def node_endpoint(node_name)
      override = node_override(node_name)
      return nil if override.nil?

      identity_host, identity_port = override.split(':', 2)
      base = begin
        URI.parse(url.to_s)
      rescue URI::Error
        nil
      end
      composed = format('%<scheme>s://%<host>s:%<port>s/wsman',
                        scheme: base&.scheme,
                        host: identity_host,
                        port: identity_port || base&.port)
      unless base&.scheme == 'http'
        raise ForemanHyperv::OperationRefused, format(NODE_ENDPOINT_REFUSAL, endpoint: composed)
      end

      composed
    end

    # A SEPARATE Fog::Compute per node (N4): hyperv_host is never passed, so
    # fog cannot compose an endpoint from it behind our back; the endpoint
    # arrives complete. One instance per node per resource, so one connection
    # cache per node — R22's "exactly one connection" is about THIS instance.
    def client_for_node(node_name)
      @node_clients ||= {}
      @node_clients[node_name.to_s.strip.downcase] ||= Fog::Compute.new(
        provider: :HyperV,
        hyperv_endpoint: node_endpoint(node_name),
        hyperv_username: user,
        hyperv_password: password
      )
    end

    # Whether the role's owner is the node this endpoint itself serves: the
    # endpoint host fully qualified, or as the bare first label the NETBIOS
    # name carries (case-insensitive). A first-label collision across two
    # domains reads from the endpoint, misses, and answers nil — a miss,
    # never a wrong machine, because GUIDs are unique and a node that does
    # not host the GUID answers NotFound.
    def endpoint_serves_node?(node_name)
      endpoint = endpoint_host_name
      return false if endpoint.nil? || node_name.blank?

      asked = node_name.to_s.strip.downcase
      asked == endpoint || asked == endpoint.split('.').first
    end

    # Each non-blank line must read NODE = host[:port]. The error names the
    # line's node verbatim, because the operator has to know WHICH line to
    # fix; the offending value rides in the message too.
    def hyperv_node_overrides_shape
      hyperv_node_overrides.to_s.each_line do |line|
        next if line.strip.empty?

        node, value = line.split('=', 2)
        if node.nil? || value.nil? || node.strip.empty? || value.strip.empty?
          errors.add(:hyperv_node_overrides, "line #{line.inspect} is not NODE = host[:port]")
          next
        end

        host, port = value.strip.split(':', 2)
        next if NODE_OVERRIDE_HOST.match?(node.strip) &&
                NODE_OVERRIDE_HOST.match?(host) &&
                (port.nil? || (NODE_OVERRIDE_PORT.match?(port) && port.to_i <= 65_535))

        errors.add(:hyperv_node_overrides,
                   "for node #{node.strip}: #{value.strip.inspect} is not a bare host or host:port " \
                   '(no scheme, no path, port 1-65535) — refused, not repaired')
      end
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
        # nic.is_legacy = Foreman::Cast.to_bool(iface[:is_legacy]) if
        #   vm.generation == :BIOS && iface[:is_legacy].present?
        # logger.debug "Creating interface with #{iface.inspect} - #{nic.inspect}\n#{nic.vlan_setting.inspect}"
        nic.save
      end

      unless vm.network_adapters.all(_return_fields: %i[dynamic_mac_address_enabled])
               .any?(&:dynamic_mac_address_enabled)
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
      # PLG-22: every requested disk removal is DECIDED before any of them is
      # executed — an explicit removal that cannot prove its file safe refuses
      # the whole edit up front, rather than deleting two disks and refusing
      # on the third. A _delete reaching here already passed the capability
      # gate (refuse_disk_removal! runs on the submitted hash before anything
      # is fetched); the call-site rule below is the attribution half.
      deletions = volumes.filter_map do |volume|
        next unless volume[:id].present? && volume[:_delete] == '1'

        hd = vm.hard_drives.get volume[:id]
        raise ForemanHyperv::OperationRefused, DISK_UNATTRIBUTED_REFUSAL unless drive_deletion_allowed?(vm, hd)

        hd
      end
      deletions.each { |hd| hd.destroy(underlying: true) }

      volumes.each do |volume|
        if volume[:id].present?
          next if volume[:_delete] == '1'

          hd = vm.hard_drives.get volume[:id]
          vhd = hd.vhd
          vhd.size = volume[:size_bytes].to_i
          vhd.save if vhd.dirty?
        elsif volume[:_delete] != '1'
          vhd = vm.vhds.create basename: volume[:basename], size: volume[:size_bytes].to_i
          vm.hard_drives.create path: vhd.path
        end
      end
    end
  end
end
