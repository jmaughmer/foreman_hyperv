# frozen_string_literal: true

require 'test_helper'

# PLG-36: preferred owners get their WRITE surface. Fog PR #13 shipped the
# measured write (evidence §76: Set-ClusterOwnerNode -Owners sticks; the clear
# is -Owners '' because @() and $null are refused); this suite pins the
# plugin's half:
#
#   1. the write gate is the capability constant AND the client method — a
#      write IS a request this side can probe for, unlike the read field;
#   2. the plugin never dials with a name the cluster may not have: node
#      names are membership-checked against the cluster's own node list, and
#      a failed membership read refuses rather than guessing (names arrive
#      canonical-cased from that list, so the cluster's stored value and the
#      form's option list stay the same strings);
#   3. the edit form applies the list ONLY on a clustered machine and ONLY on
#      change — a selection equal to the cluster's answer (case being the one
#      thing the cluster is measured not to preserve) must not spend a write;
#   4. fog's refusals land as the plugin's refused error carrying the
#      cluster's own words; "not clustered" and "cluster said no" both refuse
#      an operator's save rather than half-succeed;
#   5. vm_compute_attributes carries the current list (sorted, so the core
#      change-detect compares equal across round trips) and the form surface
#     (cluster_preferred_owners_for) answers nil whenever it cannot honestly
#      offer the control.
class HypervPreferredOwnersWriteTest < ActiveSupport::TestCase
  HOST = 'hv-node1'
  CR_URL = "http://#{HOST}:5985/wsman".freeze
  VM_ID = 'e8f37f42-11c4-4a5e-9b3a-0f2d8c1a6b77'
  VM_NAME = 'leah-navia.maughmer.net'

  NodeDouble = Struct.new(:name, keyword_init: true)
  VmDouble = Struct.new(:id, :name, keyword_init: true)

  # A role exactly as the installed fog's model answers it, carrying the
  # PLG-31b preferred_node_names field the write's change-detect reads.
  OwnersRoleDouble = Struct.new(:name, :virtual_machine_id, :owner_node, :attributes, keyword_init: true) do
    def auto_failback_type
      attributes[:auto_failback_type]
    end

    def preferred_node_names
      attributes[:preferred_node_names]
    end
  end

  class RolesDouble
    attr_reader :calls

    def initialize(roles)
      @roles = roles
      @calls = 0
    end

    def all(_filters = nil)
      @calls += 1
      @roles
    end
  end

  # A cluster-answering fog on the PLG-36 gem: it carries the failback and
  # owner-READ contract (this is the same partner the read shipped with), the
  # node list the membership check asks, and the owner WRITE the whole PR is
  # about. The write records what it was given so "exactly once, canonical,
  # unrouted" is an observable fact, and write_error answers the way a
  # refusing cluster does — with fog's own error class.
  class OwnersFog
    attr_reader :writes, :nodes_calls

    def initialize(roles_collection, nodes: %w[hv-node1 hv-node2], nodes_error: nil, write_error: nil)
      @roles_collection = roles_collection
      @nodes = nodes
      @nodes_error = nodes_error
      @write_error = write_error
      @writes = []
      @nodes_calls = 0
    end

    def cluster_virtual_machine_roles
      @roles_collection
    end

    def supports_clusters?
      true
    end

    def set_cluster_virtual_machine_role_auto_failback(**_args)
      true
    end

    def cluster_nodes
      @nodes_calls += 1
      raise @nodes_error if @nodes_error

      @nodes.map { |name| NodeDouble.new(name: name) }
    end

    def set_cluster_virtual_machine_role_owner_nodes(**kwargs)
      @writes << kwargs
      raise @write_error if @write_error

      true
    end
  end

  # The same fog one release older: the write request simply is not there.
  class LegacyOwnersFog < OwnersFog
    undef_method :set_cluster_virtual_machine_role_owner_nodes
  end

  def leah
    VmDouble.new(id: VM_ID, name: VM_NAME)
  end

  def owners_role(preferred: [], id: VM_ID)
    OwnersRoleDouble.new(name: VM_NAME, virtual_machine_id: id, owner_node: 'HV-NODE1',
                         attributes: { name: VM_NAME, owner_node: 'HV-NODE1', priority: 2000,
                                       auto_failback_type: 1, failback_window_start: nil,
                                       failback_window_end: nil, preferred_node_names: preferred })
  end

  def build_cr(fog)
    cr = ForemanHyperv::Hyperv.new(name: 'lab-cr', url: CR_URL, user: 'u', password: 'p')
    cr.stubs(:client).returns(fog)
    ForemanHyperv::Hyperv.any_instance.stubs(:role_index_flap_pause)
    cr
  end

  # The capability constant is the installed gem's, and after the PLG-36 fog
  # deploy it really carries the write entry; these two helpers swap it so the
  # constant's halves are pinned too, not just respond_to?.
  def without_capabilities
    old = Fog::Hyperv.send(:remove_const, :CAPABILITIES)
    Fog::Hyperv.const_set(:CAPABILITIES, [])
    yield
  ensure
    Fog::Hyperv.send(:remove_const, :CAPABILITIES)
    Fog::Hyperv.const_set(:CAPABILITIES, old)
  end

  def without_write_capability
    old = Fog::Hyperv.const_defined?(:CAPABILITIES) ? Fog::Hyperv.send(:remove_const, :CAPABILITIES) : nil
    Fog::Hyperv.const_set(:CAPABILITIES, old - [:cluster_role_owner_nodes_write]) if old
    yield
  ensure
    Fog::Hyperv.send(:remove_const, :CAPABILITIES) if Fog::Hyperv.const_defined?(:CAPABILITIES)
    Fog::Hyperv.const_set(:CAPABILITIES, old) if old
  end

  # ---- the gate -----------------------------------------------------------------

  def test_the_write_gate_is_the_constant_AND_the_client_method
    cr = build_cr(OwnersFog.new(RolesDouble.new([])))
    assert cr.send(:cluster_owner_nodes_write_supported?),
           'the deployed partner answers both, so the gate must be open'

    legacy = build_cr(LegacyOwnersFog.new(RolesDouble.new([])))
    assert_not legacy.send(:cluster_owner_nodes_write_supported?),
               'a constant alone would bless a partner whose client cannot send the request'

    without_write_capability do
      assert_not cr.send(:cluster_owner_nodes_write_supported?),
                 'a method name alone would bless a partner that never promised the contract'
    end

    without_capabilities do
      assert_not cr.send(:cluster_owner_nodes_write_supported?),
                 'a fog without the constant at all gets every fork behaviour treated as absent'
    end
  end

  # ---- the public write path ------------------------------------------------------

  def test_the_write_membership_checks_names_and_canonicalises_them
    fog = OwnersFog.new(RolesDouble.new([]))
    cr = build_cr(fog)

    assert cr.set_cluster_vm_preferred_owners(leah, ['HV-NODE2'])

    assert_equal 1, fog.writes.size
    write = fog.writes.first
    assert_equal VM_ID, write[:id]
    assert_equal ['hv-node2'], write[:owner_nodes],
                 'names arrive canonical-cased from the cluster\'s own list, so the stored value ' \
                 'and the read-back stay the strings the form offers — the cluster is not measured ' \
                 'to preserve case'
    assert_nil write[:computer_name],
               'the owners are pure cluster state: any node\'s cluster service answers (measured, ' \
               'the role read runs this same way every listing) — routing on a node name would hit ' \
               'the PLG-27 trap the endpoint client refuses names its set never dialled'
  end

  def test_the_clear_needs_no_membership
    fog = OwnersFog.new(RolesDouble.new([]))
    cr = build_cr(fog)

    assert cr.set_cluster_vm_preferred_owners(leah, [])

    assert_equal 1, fog.writes.size
    assert_equal [], fog.writes.first[:owner_nodes],
                 '[] is the explicit unrestricted state; the fog maps it to the one measured ' \
                 'clear spelling (-Owners \'\')'
    assert_equal 0, fog.nodes_calls, 'a list with no names cannot name a wrong node'
  end

  def test_a_name_the_cluster_does_not_have_is_refused_before_the_wire
    fog = OwnersFog.new(RolesDouble.new([]))
    cr = build_cr(fog)

    error = assert_raises(ForemanHyperv::OperationRefused) { cr.set_cluster_vm_preferred_owners(leah, ['hv-node9']) }

    assert_includes error.message, 'hv-node9'
    assert_empty fog.writes, 'the plugin does not dial with a node the cluster may not have'
  end

  def test_a_membership_read_that_fails_refuses_rather_than_guesses
    fog = OwnersFog.new(RolesDouble.new([]), nodes_error: Timeout::Error)
    cr = build_cr(fog)

    assert_raises(ForemanHyperv::OperationRefused) { cr.set_cluster_vm_preferred_owners(leah, ['hv-node1']) }

    assert_empty fog.writes, 'unknown nodes are not permission to write'
  end

  def test_a_node_named_twice_is_refused_before_the_wire
    fog = OwnersFog.new(RolesDouble.new([]))
    cr = build_cr(fog)

    assert_raises(ForemanHyperv::OperationRefused) { cr.set_cluster_vm_preferred_owners(leah, %w[hv-node1 HV-NODE1]) }

    assert_empty fog.writes
  end

  def test_a_refusing_cluster_raises_the_plugin_refusal_carrying_its_words
    fog = OwnersFog.new(RolesDouble.new([]),
                        write_error: Fog::Hyperv::Errors::RolePropertyWriteRefused.new(
                          'the cluster refused the preferred-owners setting (Server Update Failed)'
                        ))
    cr = build_cr(fog)

    error = assert_raises(ForemanHyperv::OperationRefused) { cr.set_cluster_vm_preferred_owners(leah, ['hv-node1']) }

    assert_includes error.message, 'Server Update Failed',
                    'the operator sees what the cluster actually said, not a paraphrase'
  end

  def test_a_machine_without_a_role_raises_the_plugin_refusal
    fog = OwnersFog.new(RolesDouble.new([]),
                        write_error: Fog::Hyperv::Errors::ClusterRoleNotFound.new(
                          'the machine has no clustered role, so there are no preferred owners to set'
                        ))
    cr = build_cr(fog)

    assert_raises(ForemanHyperv::OperationRefused) { cr.set_cluster_vm_preferred_owners(leah, ['hv-node1']) }
  end

  # ---- save_vm: only a clustered machine, only on change ---------------------------

  def edit_attr(preferred_owners)
    attrs = { name: VM_NAME, start: '1', memory_startup: '512', processor_count: '1',
              dynamic_memory_enabled: '0', notes: 'plg36' }
    attrs[:preferred_owners] = preferred_owners unless preferred_owners.nil?
    attrs
  end

  def edit_cr(fog, roles: [owners_role])
    cr = build_cr(fog)
    vm = stub('vm',
              id: VM_ID, name: VM_NAME, computer_name: 'hv-node2', generation: :BIOS,
              dynamic_memory_enabled: false, dirty?: false)
    vm.stubs(:processor_count=)
    vm.stubs(:notes=)
    vm.stubs(:dynamic_memory_enabled=)
    cr.stubs(:find_vm_by_uuid).returns(vm)
    cr.stubs(:validate_placement!)
    cr.stubs(:update_interfaces)
    cr.stubs(:update_volumes)
    cr.stubs(:cluster_role_index).returns(roles.index_by { |role| role.virtual_machine_id.to_s.downcase })
    [cr, vm]
  end

  def test_a_changed_selection_on_a_clustered_machine_writes_once
    fog = OwnersFog.new(RolesDouble.new([]))
    cr, = edit_cr(fog, roles: [owners_role(preferred: [])])

    cr.save_vm(VM_ID, edit_attr(['hv-node2']))

    assert_equal 1, fog.writes.size
    assert_equal ['hv-node2'], fog.writes.first[:owner_nodes]
  end

  def test_a_selection_equal_to_the_cluster_answer_writes_nothing
    # Case is the one thing the cluster is measured not to preserve; an
    # operator who touched nothing must not spend a write on it.
    fog = OwnersFog.new(RolesDouble.new([]))
    cr, = edit_cr(fog, roles: [owners_role(preferred: %w[hv-node1 HV-NODE2])])

    cr.save_vm(VM_ID, edit_attr(%w[HV-NODE1 hv-node2]))

    assert_empty fog.writes
  end

  def test_a_form_without_the_control_changes_no_owners
    fog = OwnersFog.new(RolesDouble.new([]))
    cr, = edit_cr(fog)

    cr.save_vm(VM_ID, edit_attr(nil))

    assert_empty fog.writes, 'no key is not an empty list: the clear has to be submitted to be meant'
  end

  def test_a_stale_key_on_a_machine_without_a_role_is_neither_written_nor_fatal
    fog = OwnersFog.new(RolesDouble.new([]))
    cr, = edit_cr(fog, roles: [])

    cr.save_vm(VM_ID, edit_attr(['']))

    assert_empty fog.writes, 'the control renders only on a clustered machine; a stale attribute ' \
                             'with nothing to configure must not brick every later save'
  end

  def test_a_key_on_an_older_fog_refuses_rather_than_drops
    fog = LegacyOwnersFog.new(RolesDouble.new([]))
    cr, = edit_cr(fog)

    assert_raises(ForemanHyperv::OperationRefused) { cr.save_vm(VM_ID, edit_attr(['hv-node1'])) }

    assert_empty fog.writes
  end

  def test_a_refused_owners_write_fails_the_save
    fog = OwnersFog.new(RolesDouble.new([]),
                        write_error: Fog::Hyperv::Errors::RolePropertyWriteRefused.new(
                          'the cluster refused the preferred-owners setting (Failed to retrieve the node)'
                        ))
    cr, = edit_cr(fog, roles: [owners_role(preferred: [])])

    assert_raises(ForemanHyperv::OperationRefused) { cr.save_vm(VM_ID, edit_attr(['hv-node2'])) }
  end

  # ---- the form surface -------------------------------------------------------------

  def test_the_edit_form_offers_the_current_list_sorted
    fog = OwnersFog.new(RolesDouble.new([owners_role(preferred: %w[hv-node2 hv-node1])]))
    cr = build_cr(fog)

    assert_equal %w[hv-node1 hv-node2], cr.cluster_preferred_owners_for(leah),
                 'sorted, because the option DOM order is what the form submits and what the ' \
                 'core change-detect compares against — both sides must agree without the cluster ' \
                 'having preserved anything'
  end

  def test_the_unset_list_still_offers_the_control
    # [] is the measured positive "any node" state — the control shows with
    # nothing selected so the operator CAN restrict.
    fog = OwnersFog.new(RolesDouble.new([owners_role(preferred: [])]))
    cr = build_cr(fog)

    assert_equal [], cr.cluster_preferred_owners_for(leah)
  end

  def test_the_control_hides_when_the_owner_read_failed_or_the_fog_cannot_write
    nil_read = build_cr(OwnersFog.new(RolesDouble.new([owners_role(preferred: nil)])))
    assert_nil nil_read.cluster_preferred_owners_for(leah),
               'unknown current owners offer no honest selection'

    no_role = build_cr(OwnersFog.new(RolesDouble.new([])))
    assert_nil no_role.cluster_preferred_owners_for(leah), 'no role, nothing to offer'

    legacy = build_cr(LegacyOwnersFog.new(RolesDouble.new([owners_role])))
    assert_nil legacy.cluster_preferred_owners_for(leah)

    without_write_capability do
      assert_nil build_cr(OwnersFog.new(RolesDouble.new([owners_role]))).cluster_preferred_owners_for(leah)
    end
  end

  def test_the_node_choices_are_sorted_and_survive_a_failed_read
    cr = build_cr(OwnersFog.new(RolesDouble.new([])))
    assert_equal %w[hv-node1 hv-node2], cr.cluster_node_names

    broken = build_cr(OwnersFog.new(RolesDouble.new([]), nodes_error: Timeout::Error))
    assert_nil broken.cluster_node_names, 'a list that cannot be read offers nothing; the page does not die'
  end

  def test_a_stand_alone_endpoint_offers_no_owners_control
    fog = OwnersFog.new(RolesDouble.new([]))
    fog.stubs(:supports_clusters?).returns(false)
    cr = build_cr(fog)

    assert_nil cr.cluster_preferred_owners_for(leah)
    assert_nil cr.vm_compute_attributes(server_vm)[:preferred_owners],
               'a stand-alone endpoint answers the control question with no role read at all'
    assert_equal 0, fog.cluster_virtual_machine_roles.calls,
                 'the gate answers stand-alone before any role index is built'
  end

  # ---- vm_compute_attributes: the key that drives core's change-detect -------------

  def server_vm
    # A machine as core hands it to vm_compute_attributes: the attributes
    # hash the form is sliced from, plus the readers core's volume/interface
    # joins make. A real fog Server cannot be built bare — its hard_drives
    # key builds a service-backed collection — so the shape is stubbed, the
    # way every other suite here stubs a listed machine.
    stub('vm', id: VM_ID, name: VM_NAME, computer_name: 'hv-node1',
               attributes: { id: VM_ID, name: VM_NAME, computer_name: 'hv-node1',
                             generation: 2, dynamic_memory_enabled: false,
                             memory_maximum: 1_073_741_824, memory_minimum: 536_870_912,
                             memory_startup: 536_870_912, notes: 'plg36', processor_count: 1 },
               hard_drives: [], interfaces: [],
               foreman_firmware_type: 'uefi', tpm_enabled: false)
  end

  def test_compute_attributes_carry_the_current_list_for_change_detect
    fog = OwnersFog.new(RolesDouble.new([owners_role(preferred: %w[hv-node2 hv-node1])]))
    cr = build_cr(fog)

    attrs = cr.vm_compute_attributes(server_vm)

    assert_equal %w[hv-node1 hv-node2], attrs[:preferred_owners],
                 'core compares the fresh read against the submitted form to decide whether to ' \
                 'call save_vm at all; without this key an owners-only change never triggers'
  end

  def test_compute_attributes_omit_the_key_when_the_control_could_not_be_offered
    fog = OwnersFog.new(RolesDouble.new([]))
    cr = build_cr(fog)

    assert_not_includes cr.vm_compute_attributes(server_vm).keys, :preferred_owners,
                        'no honest selection, no key: a missing key round-trips as "not submitted" ' \
                        'rather than as a clear'
  end

  # ---- the fog model rides the key, as it rides auto_failback -----------------------

  def test_the_fog_machine_answers_the_owners_accessor_nil_and_assignable
    # The rebuild path hands stored compute_attributes (which may carry the
    # key) straight into servers.new — the accessor is what keeps a
    # round-tripped key from exploding as UnknownAttribute, exactly as the
    # auto_failback accessor does for the create form.
    server = Fog::Hyperv::Compute::Server.new
    assert_nil server.preferred_owners

    assigned = Fog::Hyperv::Compute::Server.new(preferred_owners: ['hv-node1'])
    assert_equal ['hv-node1'], assigned.preferred_owners
  end
end
