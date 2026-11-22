# frozen_string_literal: true

require 'test_helper'

# PLG-14: placement storage from fog's capacity projection (FOG-8). The old
# nested read arrived on the measured build with a type-name string where the
# volume object should have been (evidence §30, §33.1) — nil path, nil size,
# nil free space on a healthy cluster — and the fields this surface reads
# (shared_volume[:size]) do not exist on the projected model at all. So this
# suite pins three things:
#
#   1. the FLAT mapping — capacity/free space off the projected attributes,
#      never re-synthesised; the ApiStorageDomain field order is core's
#      available_storage_domains.rabl contract and rides unchanged;
#   2. the STATE FILTER — only cluster resource state 2 (Online, measured)
#      is placement storage; offline (3), an unmeasured state, and a silence
#      are each EXCLUDED WITH A REASON naming the volume (FOG-8's own rule:
#      unmeasured states are excluded with a reason, never treated as
#      either), and a volume that answers no mount path on the node is
#      excluded even when online (the path is never synthesised);
#   3. the BLANK-ID GATE on the create — a chosen storage whose id (mount
#      path) is blank refuses the create by name. It must never fall through
#      to the node's own virtual_machine_path (a clustered machine's config
#      off the CSV) and never join a relative placement_path that lands the
#      disks at C:\<name> (the FOG-17 shape on the read side).
#
# The stand-alone semantics PLG-14 must NOT move: a blank cluster id and a
# host with no cluster answer [] (the UI's honest "no datastores"), and the
# stand-alone create keeps falling back to the hypervisor's own VM path.
class HypervAvailableStorageDomainsTest < ActiveSupport::TestCase
  HOST = 'hv-node1'
  VOL1 = 'C:\ClusterStorage\Volume1'
  VOL2 = 'C:\ClusterStorage\Volume2'
  VOL3 = 'C:\ClusterStorage\Volume3'

  # The projected fog model, attribute-for-attribute as ClusterCapacity
  # answers it (plain attributes, nils stay nils — the live-row shapes of
  # evidence §48: online volume with path/sizes; offline volume with nil
  # path and nil capacities and the '' fault state).
  # rubocop:disable Lint/StructNewOverride -- the projected fog model really does
  # carry a size attribute; this double overrides Struct#size on purpose.
  VolDouble = Struct.new(:name, :id, :state, :owner_node, :volume_path, :size, :free_space,
                         :percent_free, :fault_state, keyword_init: true)
  # rubocop:enable Lint/StructNewOverride

  ClusterDouble = Struct.new(:id, :name, :volumes, keyword_init: true) do
    def shared_volumes
      volumes
    end
  end

  # A cluster-shaped answer from a fog too old to project at all.
  NO_VOLUMES_CLUSTER = Struct.new(:id, :name)

  class LogDouble
    attr_reader :infos, :warnings

    def initialize
      @infos = []
      @warnings = []
    end

    def info(message)
      @infos << message.to_s
    end

    def warn(message)
      @warnings << message.to_s
    end
  end

  def online_volume(name, path, size: 100_000, free: 50_000)
    VolDouble.new(name: name, id: 'a49ab1ad-0000-0000-0000-000000000001', state: 2,
                  owner_node: 'hv-node3', volume_path: path, size: size, free_space: free,
                  percent_free: 98.12914, fault_state: 'NoFaults')
  end

  def offline_volume(name)
    VolDouble.new(name: name, id: 'a49ab1ad-0000-0000-0000-000000000002', state: 3,
                  owner_node: 'hv-node2', volume_path: nil, size: nil, free_space: nil,
                  percent_free: nil, fault_state: '')
  end

  def build_cr(volumes: [], cluster_name: 'lab-cluster', cluster_id: 'f5fc878c-0000-0000-0000-000000000000')
    cluster = ClusterDouble.new(id: cluster_id, name: cluster_name, volumes: volumes)
    cr = ForemanHyperv::Hyperv.new(name: 'lab-cr', url: "http://#{HOST}:5985/wsman", user: 'u', password: 'p')
    cr.stubs(:clusters).returns([cluster])
    log = LogDouble.new
    cr.stubs(:logger).returns(log)
    [cr, cluster, log]
  end

  # ---- 1. the flat mapping ----------------------------------------------------

  def test_an_online_volume_maps_to_the_api_fields_off_the_projection
    cr, cluster, = build_cr(volumes: [online_volume('Cluster Volume1', VOL1)])

    domains = cr.available_storage_domains(cluster.id)

    assert_equal 1, domains.size
    domain = domains.first
    assert_equal 'Cluster Volume1', domain.name
    assert_equal VOL1, domain.id, 'the id stays the mount path — the form and the rabl ask storage by it'
    assert_equal 100_000, domain.capacity, 'capacity is the projected size, byte-for-byte'
    assert_equal 50_000, domain.freespace, 'free space is the projected free_space, byte-for-byte'
    assert_nil domain.uncommitted, 'Hyper-V answers no uncommitted number; nil stays nil'
  end

  def test_the_api_struct_field_order_is_core_s_rabl_contract
    assert_equal %i[name id capacity freespace uncommitted],
                 ForemanHyperv::Hyperv::ApiStorageDomain.members,
                 'available_storage_domains.rabl reads these five in this order'
  end

  def test_the_fields_come_from_the_projection_not_a_re_synthesis
    # An online volume whose partition sizes are nil answers nil here: the
    # plugin must not zero them, and must not read fog's old nested hash
    # (the projected model has no shared_volume attribute at all).
    bare = VolDouble.new(name: 'Bare', id: 'x', state: 2, owner_node: 'hv-node1',
                         volume_path: VOL3, size: nil, free_space: nil,
                         percent_free: nil, fault_state: 'NoFaults')
    cr, cluster, = build_cr(volumes: [bare])

    domains = cr.available_storage_domains(cluster.id)
    assert_equal 1, domains.size
    domain = domains.first

    assert_nil domain.capacity
    assert_nil domain.freespace
    assert_not bare.respond_to?(:shared_volume), 'the projected model carries no nested hash to read'
  end

  # ---- 2. the state filter, with exclusion reasons ----------------------------

  def test_only_online_volumes_are_offered_and_the_rest_are_excluded_naming_themselves
    volumes = [online_volume('Cluster Volume1', VOL1),
               offline_volume('Cluster Volume2'),
               VolDouble.new(name: 'Weird', id: 'w', state: 7, owner_node: 'hv-node1',
                             volume_path: VOL2, size: 1, free_space: 1, percent_free: 1, fault_state: 'X'),
               VolDouble.new(name: 'Silent', id: 's', state: nil, owner_node: 'hv-node1',
                             volume_path: VOL3, size: 1, free_space: 1, percent_free: 1, fault_state: '')]
    cr, cluster, log = build_cr(volumes: volumes)

    domains = cr.available_storage_domains(cluster.id)

    assert_equal ['Cluster Volume1'], domains.map(&:name),
                 'state 2 is the only measured Online; 3, 7 and silence are not placement storage'
    assert_equal 3, log.infos.size, 'every exclusion is logged'
    joined = log.infos.join("\n")
    assert_includes joined, 'Cluster Volume2'
    assert_includes joined.downcase, 'offline', 'the offline row is excluded FOR A REASON, not silently'
    assert_includes joined, 'Weird'
    assert_includes joined, '7', 'the unmeasured state is named as answered, not guessed at'
    assert_includes joined, 'Silent'
  end

  def test_an_online_volume_answering_no_mount_path_is_excluded_even_when_online
    [nil, ''].each do |path|
      pathless = VolDouble.new(name: 'Pathless', id: 'p', state: 2, owner_node: 'hv-node1',
                               volume_path: path, size: 10, free_space: 5,
                               percent_free: 50.0, fault_state: 'NoFaults')
      cr, cluster, log = build_cr(volumes: [pathless])

      assert_empty cr.available_storage_domains(cluster.id),
                   'the path is never synthesised from the name, so an online volume without one is not storage'
      assert_includes log.infos.join(' '), 'Pathless'
      assert_includes log.infos.join(' ').downcase, 'mount path'
    end
  end

  def test_a_fog_refusal_of_the_capacity_read_travels_up_untouched
    cluster = ClusterDouble.new(id: 'c', name: 'lab-cluster', volumes: nil)
    cluster.define_singleton_method(:shared_volumes) do
      raise ForemanHyperv::OperationRefused, 'the read contradicted its own witness'
    end
    cr = ForemanHyperv::Hyperv.new(name: 'lab-cr', url: "http://#{HOST}:5985/wsman", user: 'u', password: 'p')
    cr.stubs(:clusters).returns([cluster])

    assert_raises(ForemanHyperv::OperationRefused) { cr.available_storage_domains('c') }
  end

  # ---- the semantics PLG-14 must not move --------------------------------------

  def test_a_blank_cluster_id_and_a_host_with_no_cluster_still_answer_empty
    cr, = build_cr

    assert_empty cr.available_storage_domains(nil)
    assert_empty cr.available_storage_domains('')
    cr2 = ForemanHyperv::Hyperv.new(name: 'standalone', url: "http://#{HOST}:5985/wsman", user: 'u', password: 'p')
    cr2.stubs(:clusters).returns([])
    assert_empty cr2.available_storage_domains('anything')
    cr3 = ForemanHyperv::Hyperv.new(name: 'old-fog', url: "http://#{HOST}:5985/wsman", user: 'u', password: 'p')
    cr3.stubs(:clusters).returns([NO_VOLUMES_CLUSTER.new(id: 'c1', name: 'lab-cluster')])
    assert_empty cr3.available_storage_domains('c1'), 'a fog that projects nothing simply has no volumes'
  end

  def test_storage_domain_lookup_answers_from_the_offered_set_only
    cr = ForemanHyperv::Hyperv.new(name: 'lab-cr', url: "http://#{HOST}:5985/wsman", user: 'u', password: 'p')
    cr.stubs(:clusters).returns([ClusterDouble.new(id: 'c1', name: 'lab-cluster', volumes: [])])
    offered = [ForemanHyperv::Hyperv::ApiStorageDomain.new('Cluster Volume1', VOL1, 100, 50, nil)]
    cr.stubs(:available_storage_domains).returns(offered)

    assert_equal 'Cluster Volume1', cr.storage_domain(VOL1).name, 'the deprecated route addresses by the id field'
    assert_equal 'Cluster Volume1', cr.storage_domain('Cluster Volume1').name
    assert_nil cr.storage_domain('Cluster Volume2'),
               'an excluded volume is simply not one of the offered domains'
  end

  # ---- 3. placement_storage: the named-but-unmatched raises --------------------

  def placement_cr(volumes)
    build_cr(volumes: volumes)
  end

  def test_placement_storage_without_an_ask_takes_the_first_offered_volume
    cr, cluster, = placement_cr([online_volume('Cluster Volume1', VOL1), online_volume('Cluster Volume3', VOL3)])

    domain = cr.send(:placement_storage, cluster, { volumes_attributes: {} })

    assert_equal VOL1, domain.id
  end

  def test_placement_storage_refuses_a_named_volume_that_is_nowhere_naming_it
    cr, cluster, = placement_cr([online_volume('Cluster Volume1', VOL1)])
    attrs = { volumes_attributes: { '0' => { 'datastore' => 'Cluster Volume9' } } }

    error = assert_raises(Foreman::Exception) { cr.send(:placement_storage, cluster, attrs) }
    assert_includes error.message, 'Cluster Volume9'
  end

  def test_placement_storage_refuses_a_named_but_excluded_volume_naming_the_exclusion
    cr, cluster, = placement_cr([online_volume('Cluster Volume1', VOL1), offline_volume('Cluster Volume2')])
    attrs = { volumes_attributes: { '0' => { 'datastore' => 'Cluster Volume2' } } }

    error = assert_raises(Foreman::Exception) { cr.send(:placement_storage, cluster, attrs) }
    assert_includes error.message, 'Cluster Volume2'
    assert_includes error.message.downcase, 'offline',
                    'the operator named a volume the cluster DOES have — the refusal says why it is not storage'
  end

  def test_placement_storage_with_every_volume_excluded_refuses_naming_the_exclusions
    cr, cluster, = placement_cr([offline_volume('Cluster Volume2'), offline_volume('Cluster Volume3')])

    error = assert_raises(Foreman::Exception) { cr.send(:placement_storage, cluster, { volumes_attributes: {} }) }
    assert_includes error.message, 'Cluster Volume2'
    assert_includes error.message, 'Cluster Volume3'
    assert_includes error.message.downcase, 'offline'
  end

  def test_placement_storage_on_a_cluster_with_no_volumes_at_all_keeps_the_plain_refusal
    cr, cluster, = placement_cr([])

    error = assert_raises(Foreman::Exception) { cr.send(:placement_storage, cluster, { volumes_attributes: {} }) }
    assert_includes error.message, 'no shared volumes'
  end

  # ---- validate_placement!: an excluded ask is not an unread one ----------------

  def test_validate_placement_names_the_exclusion_when_the_ask_exists_but_is_not_storage
    cr = ForemanHyperv::Hyperv.new(name: 'lab-cr', url: "http://#{HOST}:5985/wsman", user: 'u', password: 'p')
    cr.stubs(:placement_target_names).returns([HOST])
    cluster = ClusterDouble.new(id: 'c1', name: 'lab-cluster', volumes: [offline_volume('Cluster Volume2')])
    cr.stubs(:endpoint_cluster).returns(cluster)
    cr.stubs(:logger).returns(LogDouble.new)

    attrs = { volumes_attributes: { '0' => { 'datastore' => 'Cluster Volume2' } } }
    error = assert_raises(ForemanHyperv::OperationRefused) { cr.send(:validate_placement!, attrs) }
    assert_includes error.message, 'Cluster Volume2'
    assert_includes error.message.downcase, 'offline',
                    'the cluster HAS this volume and refuses it for a reason — a different answer from never-reading-it'
  end

  def test_validate_placement_still_refuses_a_volume_the_cluster_never_answered
    cr = ForemanHyperv::Hyperv.new(name: 'lab-cr', url: "http://#{HOST}:5985/wsman", user: 'u', password: 'p')
    cr.stubs(:placement_target_names).returns([HOST])
    cluster = ClusterDouble.new(id: 'c1', name: 'lab-cluster', volumes: [online_volume('Cluster Volume1', VOL1)])
    cr.stubs(:endpoint_cluster).returns(cluster)
    cr.stubs(:logger).returns(LogDouble.new)

    attrs = { volumes_attributes: { '0' => { 'datastore' => 'Cluster Volume9' } } }
    error = assert_raises(ForemanHyperv::OperationRefused) { cr.send(:validate_placement!, attrs) }
    assert_includes error.message, 'has not read'
    assert_not_includes error.message, 'offline'
  end

  # ---- the blank-id gate on the create ------------------------------------------

  class NoCallsServers
    def new(**_kwargs)
      raise 'servers.new ran: the blank-id create must refuse before the model is built'
    end
  end

  class NoCallsFog
    def servers
      NoCallsServers.new
    end
  end

  def test_a_chosen_storage_with_a_blank_id_refuses_the_create_by_name_rather_than_falling_back
    cr = ForemanHyperv::Hyperv.new(name: 'lab-cr', url: "http://#{HOST}:5985/wsman", user: 'u', password: 'p')
    cr.stubs(:client).returns(NoCallsFog.new)
    cr.stubs(:hypervisor).returns(stub('hypervisor', name: HOST, virtual_machine_path: 'C:\VMs',
                                                     virtual_hard_disk_path: 'C:\VMs\Disks'))
    cr.stubs(:validate_interfaces)
    cr.stubs(:validate_volumes)
    cr.stubs(:create_interfaces)
    cr.stubs(:create_volumes)
    cr.stubs(:cluster_named).returns(stub('cluster', name: 'lab-cluster'))
    blank_domain = ForemanHyperv::Hyperv::ApiStorageDomain.new('Cluster Volume2', nil, nil, nil, nil)
    cr.stubs(:placement_storage).returns(blank_domain)

    # The enablement era carries the membership rule; stub it to stay out of
    # this test's way — the blank-id gate is about what the create DOES with
    # an accepted storage, not about how it was accepted.
    cr.stubs(:enablement_supported?).returns(true)
    cr.stubs(:validate_placement!)

    error = assert_raises(ForemanHyperv::OperationRefused) do
      cr.create_vm(name: 'plg14-row', start: '0', generation: 2, memory_startup: '512',
                   processor_count: '1', dynamic_memory_enabled: '0', notes: 'plg14')
    end
    assert_includes error.message, 'Cluster Volume2'
    assert_includes error.message.downcase, 'mount path',
                    'the refusal says what is missing: the chosen storage answers no path'
  end

  # A model that rides the real create to its end: it records the create
  # kwargs (the path is what this test reads), answers a generation that is
  # not :UEFI so the security branch stays away, and carries the self-rung
  # name the create insists on for a machine built on the resource's own
  # client — the same surface the stand-alone suite's VmDouble carries.
  class VmRecorder
    attr_accessor :id, :name, :computer_name, :path, :generation, :hard_drives, :placement_path
    # PLG-28: the plugin's fog extension gives every fog server this accessor;
    # a double of that class answers to it too.
    attr_accessor :switch_name_resolver
    attr_reader :create_kwargs

    def initialize(computer_name)
      @computer_name = computer_name
      @generation = :BIOS
      @create_kwargs = {}
    end

    def create(**attrs)
      @create_kwargs = attrs
    end

    def persisted?
      true
    end

    def start; end
  end

  class RecordingServers
    attr_reader :vm

    def initialize(vm)
      @vm = vm
    end

    def new(_attributes = nil)
      @vm
    end
  end

  class RecordingFog
    attr_reader :servers

    def initialize(servers)
      @servers = servers
    end
  end

  def test_a_standalone_create_keeps_falling_back_to_the_hypervisor_path
    # No cluster, no storage: the stand-alone machine's config still goes to
    # the node's own virtual_machine_path — PLG-14 changes nothing here.
    vm = VmRecorder.new(HOST)
    fog = RecordingFog.new(RecordingServers.new(vm))
    cr = ForemanHyperv::Hyperv.new(name: 'lab-cr', url: "http://#{HOST}:5985/wsman", user: 'u', password: 'p')
    cr.stubs(:client).returns(fog)
    cr.stubs(:create_allowed?).returns(true)
    cr.stubs(:hypervisor).returns(stub('hypervisor', name: HOST, virtual_machine_path: 'C:\VMs',
                                                     virtual_hard_disk_path: 'C:\VMs\Disks'))
    cr.stubs(:validate_interfaces)
    cr.stubs(:validate_volumes)
    cr.stubs(:create_interfaces)
    cr.stubs(:create_volumes)

    cr.create_vm(name: 'plg14-standalone', start: '0', generation: 2, memory_startup: '512',
                 processor_count: '1', dynamic_memory_enabled: '0', notes: 'plg14')

    assert_equal 'C:\VMs', vm.create_kwargs[:path],
                 'the stand-alone fallback rides unchanged'
    assert_nil vm.placement_path, 'a stand-alone machine gets no shared-volume disk folder'
  end
end
