# frozen_string_literal: true

require 'test_helper'

# PLG-30: automatic failback — the one High Availability setting the measured
# cluster build accepts as a WRITE on a virtual machine role (fog evidence
# section 60: AutoFailbackType sticks; priority, window and owners refuse or
# silently no-op). The plugin surface is deliberately as wide as that contract
# and no wider:
#
#   1. the create form can ASK for it (a checkbox); when asked, the plugin
#      writes it once, after the proven role add, on the client the machine was
#      built on at the identity the ladder resolved — the exact PLG-27 routing
#      rule the role Add itself obeys, because the failback write is the same
#      class of cluster write against the same owner;
#   2. asking when the cluster answer says the setting cannot land refuses
#      BEFORE the wire: no cluster (nothing to fail back), no role (ha_enabled
#      opted out — failback on a role-less machine is a knob on nothing), and a
#      fog without the failback request (this plugin does not silently drop a
#      setting the operator asked for — the whole fork refuses rather than
#      pretends);
#   3. a refused write is not a warning: it fails the create, and the existing
#      post-enablement rollback (the role this strand provably added, then the
#      machine) runs, because a machine delivered without the HA setting it
#      was ordered with is exactly the silent half-success this codebase
#      refuses everywhere else;
#   4. the Registration column DISPLAYS what the cluster reports for clustered
#      machines — on, off, or nothing at all when the fog is too old or the
#      property never arrived, because an absent field is not an "off" (the
#      same nil-is-not-false rule fog's own model answers with).
class HypervAutoFailbackTest < ActiveSupport::TestCase
  HOST = 'hv-node1'
  CR_URL = "http://#{HOST}:5985/wsman".freeze
  VOL1 = 'C:\ClusterStorage\Volume1'
  VM_NAME = 'plg30-row'
  VM_ID = 'ab0cdba7-6c16-41a0-819c-352a9b08aeb0'
  NODE = 'HV-NODE2'
  NODE_IP = '192.168.1.67'
  ELENA = '3323c48a-a1bb-4609-b25d-b02013bc701f'
  CSV = 'C:\ClusterStorage\Volume1'

  # One shared log so a test can see WHICH client received which cluster write,
  # and whether the machine was even built.
  class WriteLog
    attr_reader :entries

    def initialize
      @entries = []
    end

    def record(service_tag, method, kwargs = {})
      @entries << { service: service_tag, method: method }.merge(kwargs)
    end

    def methods_of(service_tag)
      entries.select { |e| e[:service] == service_tag }.map { |e| e[:method] }
    end
  end

  # The machine fog builds — same identity trap as the PLG-27 suite: the host's
  # create answer merges ComputerName (the node's own name) back over the model.
  # This one also records the rollback calls the post-enablement rescue makes,
  # so "the refused write rolled the strand back" is an observable fact.
  class FailbackVm
    attr_accessor :switch_name_resolver
    attr_reader :id, :name, :computer_name, :new_attributes

    def initialize(attributes, answer_name, log)
      @new_attributes = (attributes || {}).dup
      @answer_name = answer_name
      @computer_name = @new_attributes[:computer_name]
      @id = VM_ID
      @name = @new_attributes[:name]
      @log = log
      @stopped = false
      @destroyed = false
    end

    attr_reader :destroyed, :stopped

    def create(**_attrs)
      @computer_name = @answer_name
    end

    def placement_path=(value); end

    def generation
      :BIOS
    end

    def persisted?
      true
    end

    def path
      "#{CSV}\\#{name}"
    end

    def start; end

    def stop(**_kwargs)
      @stopped = true
    end

    def hard_drives
      []
    end

    def destroy(_folder)
      @destroyed = true
    end
  end

  class FailbackServers
    def initialize(answer_name, log)
      @answer_name = answer_name
      @log = log
    end

    def new(attributes = nil)
      @built = FailbackVm.new(attributes, @answer_name, @log)
      @log.record(@tag, :servers_new)
      @built
    end

    attr_accessor :tag
    attr_reader :built
  end

  # A fog client on the PLG-30 gem: records the role add and the failback write
  # under its own service tag. failback_error makes the write answer the way a
  # refusing cluster does, with fog's own error class.
  class CapableFog
    attr_reader :servers

    def initialize(service_tag, log, answer_name, failback_error: nil)
      @service_tag = service_tag
      @log = log
      @failback_error = failback_error
      @servers = FailbackServers.new(answer_name, log)
      @servers.tag = service_tag
    end

    def add_cluster_virtual_machine_role(**kwargs)
      @log.record(@service_tag, :add_role, kwargs)
      true
    end

    def set_cluster_virtual_machine_role_auto_failback(**kwargs)
      @log.record(@service_tag, :failback, kwargs)
      raise @failback_error if @failback_error

      true
    end
  end

  # The same client on an older gem: the failback request does not exist. This
  # is the vocabulary the plugin gates on (respond_to? plus the capability
  # constant), and its absence must refuse a checked box, not drop it.
  class LegacyFog < CapableFog
    undef_method :set_cluster_virtual_machine_role_auto_failback
  end

  def build_cr(answer_name: NODE, failback_error: nil, fog_class: CapableFog, clusterized: true)
    log = WriteLog.new
    endpoint = fog_class.new(:endpoint, log, answer_name)
    node = fog_class.new(:node, log, answer_name, failback_error: failback_error)

    cr = ForemanHyperv::Hyperv.new(name: 'lab-cr', url: CR_URL, user: 'u', password: 'p')
    cr.hyperv_node_overrides = "#{NODE.downcase} = #{NODE_IP}"
    cr.stubs(:client).returns(endpoint)
    cr.stubs(:client_for_node).with(NODE).returns(node)
    cr.stubs(:hypervisor).returns(stub('hypervisor', name: HOST, virtual_machine_path: 'C:\VMs',
                                                     virtual_hard_disk_path: 'C:\VMs\Disks'))
    cr.stubs(:validate_interfaces)
    cr.stubs(:validate_volumes)
    cr.stubs(:create_interfaces)
    cr.stubs(:create_volumes)
    cr.stubs(:cluster_named).returns(stub('cluster', name: 'lab-cluster'))
    cr.stubs(:placement_storage).returns(
      ForemanHyperv::Hyperv::ApiStorageDomain.new('Cluster Volume1', VOL1, 100, 50, 50)
    )
    cr.stubs(:enablement_supported?).returns(true)
    cr.stubs(:validate_placement!)
    cr.stubs(:clusterize?).returns(clusterized)
    cr.stubs(:readback_finds_role?).returns([true, nil])
    cr.stubs(:remove_cluster_role)
    cr.stubs(:rollback_folder_delete?).returns(false)
    [cr, log, node]
  end

  def create_attrs(extra = {})
    { name: VM_NAME, cluster_name: 'lab-cluster', start: '0', generation: 2,
      memory_startup: '512', processor_count: '1',
      dynamic_memory_enabled: '0', notes: 'plg30' }.merge(extra)
  end

  # ---- the create side: the write rides the role add's routing -----------------

  def test_a_checked_node_routed_create_writes_the_failback_where_the_role_add_ran
    cr, log, = build_cr
    cr.create_vm(create_attrs(computer_name: NODE, auto_failback: 'true'))

    writes = log.entries.select { |e| e[:method] == :failback }
    assert_equal 1, writes.size, 'the failback write is sent exactly once per create'
    write = writes.first
    assert_equal :node, write[:service],
                 'the failback is the same class of cluster write as the role Add and rides the ' \
                 'same client: the endpoint client refuses a bare node name its set never dialled'
    assert_equal NODE_IP, write[:computer_name],
                 'the identity is the address the ladder resolved for the machine, not the name ' \
                 'the host merge wrote back over the model'
    assert_equal VM_ID, write[:id]
    assert_equal true, write[:auto_failback],
                 'the fog contract takes exactly the boolean; a form string would be refused there'

    add_index = log.entries.index { |e| e[:method] == :add_role }
    write_index = log.entries.index { |e| e[:method] == :failback }
    assert add_index < write_index, 'failback is written only after the role add ran'
  end

  def test_a_checked_self_rung_create_writes_the_failback_on_the_endpoint
    cr, log, = build_cr(answer_name: HOST)
    cr.create_vm(create_attrs(auto_failback: 'true'))

    writes = log.entries.select { |e| e[:method] == :failback }
    assert_equal 1, writes.size
    write = writes.first
    assert_equal :endpoint, write[:service]
    assert_equal HOST, write[:computer_name],
                 'the self rung keeps the model name the endpoint itself answers, exactly as the ' \
                 'role add does'
  end

  def test_an_unchected_create_never_writes_failback
    cr, log, = build_cr
    cr.create_vm(create_attrs(computer_name: NODE))

    assert_empty log.methods_of(:node).grep(:failback) + log.methods_of(:endpoint).grep(:failback),
                 'the setting is opt-in: an unchecked box changes nothing on the cluster'
    assert_includes log.methods_of(:node), :add_role, 'the create itself went through'
  end

  def test_a_false_flag_never_writes_failback
    cr, log, = build_cr
    cr.create_vm(create_attrs(computer_name: NODE, auto_failback: 'false'))

    assert_empty log.methods_of(:node).grep(:failback) + log.methods_of(:endpoint).grep(:failback),
                 'unchecked and explicitly-off both mean "leave the cluster default"; the form ' \
                 'cannot tell them apart and neither may write'
  end

  # ---- the pre-wire refusals: a checked box that cannot land says so early -----

  def test_a_checked_standalone_create_is_refused_before_anything_is_built
    cr, log, = build_cr
    attrs = create_attrs(auto_failback: 'true')
    attrs.delete(:cluster_name)

    assert_raises(ForemanHyperv::OperationRefused) { cr.create_vm(attrs) }

    assert_empty log.entries,
                 'a machine with no cluster has no failback to set; saying so must not cost a ' \
                 'wire round trip and a rollback'
  end

  def test_a_checked_create_that_opted_out_of_the_role_is_refused_before_anything_is_built
    cr, log, = build_cr(clusterized: false)

    assert_raises(ForemanHyperv::OperationRefused) { cr.create_vm(create_attrs(auto_failback: 'true')) }

    assert_empty log.entries,
                 'failback on a role-less machine is a knob on nothing: ha_enabled=0 with the box ' \
                 'checked is a contradiction, refused, not one of them silently dropped'
  end

  def test_a_checked_create_on_an_older_fog_is_refused_before_anything_is_built
    cr, log, = build_cr(fog_class: LegacyFog)

    assert_raises(ForemanHyperv::OperationRefused) { cr.create_vm(create_attrs(auto_failback: 'true')) }

    assert_empty log.entries,
                 'the plugin does not silently drop a setting the operator asked for: a fog ' \
                 'without the failback request refuses the box before building the machine'
  end

  # ---- the refused write fails the create, with the proven rollback -------------

  def test_a_refused_failback_fails_the_create_and_rolls_back_the_role_and_machine
    refusal = Fog::Hyperv::Errors::RolePropertyWriteRefused.new(
      'the cluster refused the automatic-failback setting (Unable to save property changes)'
    )
    cr, log, node = build_cr(failback_error: refusal)
    cr.expects(:remove_cluster_role)

    assert_raises(Fog::Hyperv::Errors::RolePropertyWriteRefused) do
      cr.create_vm(create_attrs(computer_name: NODE, auto_failback: 'true'))
    end

    assert_includes log.methods_of(:node), :add_role, 'the role really was added before the refusal'
    assert node.servers.built.stopped, 'the machine the strand built is stopped by the rollback'
    assert node.servers.built.destroyed,
           'a machine delivered without the HA setting it was ordered with is not half-shipped: ' \
           'the role provably added by this strand comes off and the machine is destroyed'
  end

  # ---- the Registration column: what the cluster reports ----------------------

  RoleDouble = Struct.new(:name, :virtual_machine_id, :owner_node, :auto_failback, keyword_init: true)
  LegacyRoleDouble = Struct.new(:name, :virtual_machine_id, :owner_node, keyword_init: true)

  class RolesDouble
    def initialize(roles)
      @roles = roles
    end

    def all(_filters = nil)
      @roles
    end
  end

  class DisplayFog
    def initialize(roles_collection)
      @roles_collection = roles_collection
    end

    def cluster_virtual_machine_roles
      @roles_collection
    end

    def supports_clusters?
      true
    end

    # Present: this fog answers the PLG-30 contract, so the column may display it.
    def set_cluster_virtual_machine_role_auto_failback(**_kwargs)
      true
    end
  end

  class LegacyDisplayFog < DisplayFog
    undef_method :set_cluster_virtual_machine_role_auto_failback
  end

  VmDouble = Struct.new(:id, :name, :path, keyword_init: true)

  def display_cr(fog)
    cr = ForemanHyperv::Hyperv.new(name: 'lab-cr', url: CR_URL, user: 'u', password: 'p')
    cr.stubs(:client).returns(fog)
    cr
  end

  def clustered_vm
    VmDouble.new(id: ELENA, name: 'elena-smolen.maughmer.net', path: "#{CSV}\\elena-smolen.maughmer.net")
  end

  def role_with(auto_failback, role_class = RoleDouble)
    attrs = { name: "Virtual Machine #{clustered_vm.name}", virtual_machine_id: ELENA, owner_node: 'HV-NODE2' }
    # The legacy role model predates the field entirely — that is the point of
    # the respond_to? arm, so it gets a struct without the member at all.
    attrs[:auto_failback] = auto_failback if role_class == RoleDouble
    role_class.new(**attrs)
  end

  def test_a_clustered_machine_with_failback_on_says_so
    role = role_with(true)
    registration = display_cr(DisplayFog.new(RolesDouble.new([role]))).vm_registration(clustered_vm)

    assert_equal true, registration.auto_failback
    assert_includes registration.label, 'automatic failback on',
                    'the operator reading this row decides failover behaviour from it; the column ' \
                    'says what the cluster REPORTS, in the same breath as the owner'
  end

  def test_a_clustered_machine_with_failback_off_says_so
    role = role_with(false)
    registration = display_cr(DisplayFog.new(RolesDouble.new([role]))).vm_registration(clustered_vm)

    assert_equal false, registration.auto_failback
    assert_includes registration.label, 'automatic failback off'
  end

  def test_a_role_that_never_reported_the_property_displays_no_failback_word_at_all
    role = role_with(nil)
    registration = display_cr(DisplayFog.new(RolesDouble.new([role]))).vm_registration(clustered_vm)

    assert_nil registration.auto_failback,
               'an unreported property is not an "off" — the same nil-is-not-false rule the fog ' \
               'model answers with'
    assert_equal 'Clustered — owner HV-NODE2', registration.label,
                 'with nothing reported the column is byte-identical to the pre-PLG-30 answer'
  end

  def test_the_column_stays_silent_on_an_older_fog_even_if_a_role_happens_to_carry_the_field
    role = role_with(true)
    registration = display_cr(LegacyDisplayFog.new(RolesDouble.new([role]))).vm_registration(clustered_vm)

    assert_nil registration.auto_failback,
               'the display is gated on the same capability as the write: on a fog that never ' \
               'promised the contract, a stray field is not a claim the plugin will print'
    assert_not_includes registration.label, 'failback'
  end

  def test_a_role_model_without_the_method_at_all_is_asked_about_safely
    role = role_with(nil, LegacyRoleDouble)
    registration = display_cr(DisplayFog.new(RolesDouble.new([role]))).vm_registration(clustered_vm)

    assert_nil registration.auto_failback
    assert_equal :clustered, registration.state, 'the role itself still reads as clustered'
  end

  def test_the_other_registration_states_never_mention_failback
    standalone = VmDouble.new(id: 'cccc1111-2222-3333-4444-555566667777', name: 'plain.maughmer.net',
                              path: 'C:\VMs\plain.maughmer.net')
    fog = DisplayFog.new(RolesDouble.new([]))

    [standalone, VmDouble.new(id: 'dddd1111-2222-3333-4444-555566667777', name: 'left.maughmer.net',
                              path: "#{CSV}\\left.maughmer.net")].each do |vm|
      registration = display_cr(fog).vm_registration(vm)

      assert_nil registration.auto_failback
      assert_not_includes registration.label, 'failback',
                           'failback is a property of a cluster role; rows without one have nothing ' \
                           'to report and must not look half-filled'
    end
  end
end
