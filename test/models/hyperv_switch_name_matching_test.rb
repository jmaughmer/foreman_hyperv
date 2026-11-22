# frozen_string_literal: true

require 'test_helper'

# PLG-28: the query-side NIC match crosses nodes too — the endpoint's GUID is
# resolved to the shared switch name it names, exactly as the write side (PLG-26)
# resolves it before fog dials the target.
#
# The acceptance row proved the shape end to end (evidence §57): the machine was
# built on HV-NODE2, NIC connected, disks on Volume1, the role Add landed — and
# core's own "Query instance details" step then died with "Could not find virtual
# machine network interface matching 192.168.1.161". setComputeDetails asks the
# created machine (select_nic) for the MAC of every physical Foreman NIC, and the
# match runs on mac (the Foreman NIC has none yet on create), then on switch
# identity. A virtual switch is a per-node resource: the NIC record carries the
# ENDPOINT's GUID for "External" (908ed04b-… measured on the lab form), while the
# queried adapter answers the node's own GUID for the same switch
# (Get-VMNetworkAdapter on HV-NODE2), under switch_name "External" (measured on
# both rungs). Neither GUID matches the other off the endpoint node, the stored
# compute_attributes carry no switch_name, and the existing name fallback had
# nothing to compare — so the match fell through to nothing and the orchestration
# rolled the machine back. The endpoint's own switch listing is the one table
# that knows "this GUID IS that name", and the compute resource already reads it
# (PLG-26's resolve_nic_switch); the created machine now carries that
# translation, and select_nic uses it as the last cross-node identity both sides
# can answer to.
class HypervSwitchNameMatchingTest < ActiveSupport::TestCase
  ENDPOINT_GUID = '908ed04b-1960-48b2-9cab-037e9cebf603' # HV-NODE1's GUID for "External" (measured)
  NODE_GUID = '0f4f2b6d-2f77-4715-82a2-64881a921f57'     # HV-NODE2's GUID, same "External"
  ADAPTER_ID = 'Microsoft:47BCF071-75B6-495B-A1C2-0A77622D482B\\84B39840-3455-4A56-A585-D84556520B89'

  # The Foreman NIC as core hands it to select_nic mid-orchestration: no MAC yet
  # (that is what the match must deliver), compute_attributes exactly as the form
  # stored them — the endpoint's GUID, an empty identity, nothing else.
  NicDouble = Struct.new(:mac, :compute_attributes, keyword_init: true)

  # One line of the endpoint's switch listing: the GUID the form value carries,
  # and the name every node of the cluster shares for it.
  Switch = Struct.new(:id, :name)

  def nic
    NicDouble.new(mac: nil, compute_attributes: { 'identity' => '', 'switch_id' => ENDPOINT_GUID,
                                                  'vlan_operation_mode' => 'Untagged' })
  end

  # An adapter exactly as the queried machine answers it (measured): the node's
  # GUID, the shared name, a MAC already assigned by the hypervisor.
  AdapterDouble = Struct.new(:id, :mac, :name, :switch_id, :switch_name, :vlan_operation_mode, keyword_init: true)

  def adapter(attrs = {})
    AdapterDouble.new({ id: ADAPTER_ID, mac: '00:15:5d:01:42:10', name: 'Network Adapter',
                        switch_name: 'External', vlan_operation_mode: :Untagged }.merge(attrs))
  end

  def vm_model
    Fog::Hyperv::Compute::Server.new(service: stub('service'))
  end

  # ---- the cross-node rung: the endpoint GUID names the shared switch ----

  def test_a_node_routed_adapter_matches_when_the_endpoint_guid_names_its_switch
    vm = vm_model
    vm.switch_name_resolver = ->(guid) { 'External' if guid.to_s.casecmp?(ENDPOINT_GUID) }
    n = nic

    matched = vm.select_nic([adapter(switch_id: NODE_GUID)], n)

    assert_not_nil matched,
                   'the adapter on HV-NODE2 carries the node GUID for the very switch the NIC record ' \
                   'names by the ENDPOINT GUID; the endpoint listing already proves both GUIDs are ' \
                   'named "External", and matching may throw away a machine over the mismatch that ' \
                   'translation resolves'
    assert_equal ADAPTER_ID, matched.id
    assert_equal ADAPTER_ID, n.compute_attributes['identity'],
                 'the identity recorded on the NIC stays the adapter id — the edit path reads ' \
                 'the machine back through it and must not re-derive it from any GUID'
  end

  def test_the_resolved_name_still_has_to_answer_the_adapter_s_switch
    vm = vm_model
    vm.switch_name_resolver = ->(_guid) { 'Mgmt' }

    assert_nil vm.select_nic([adapter(switch_id: NODE_GUID)], nic),
               'a switch the endpoint names differently is a different switch — the translation ' \
               'may bridge GUIDs, it may not invent connectivity'
  end

  # ---- the self rung: unchanged endpoint semantics, pinned ----

  def test_a_machine_on_the_endpoint_node_still_matches_on_the_guid_alone
    vm = vm_model
    n = nic

    matched = vm.select_nic([adapter(switch_id: ENDPOINT_GUID)], n)

    assert_not_nil matched, 'on the endpoint itself the stored GUID IS the adapter GUID — no resolver attached'
    assert_equal ADAPTER_ID, n.compute_attributes['identity']
  end

  def test_a_different_switch_still_does_not_match_without_any_translation
    assert_nil vm_model.select_nic([adapter(switch_id: NODE_GUID, switch_name: 'Mgmt')], nic),
               'no resolver, no name in the NIC attributes: a foreign GUID with a foreign name ' \
               'stays no match — the bridge exists only where the endpoint proves it'
  end

  # ---- the attach: create hands the translation to the machine core reads back ----

  # The PLG-27 harness, kept whole: this test rides the same create_vm path to
  # prove the machine RETURNED TO CORE carries the endpoint translation.
  HOST = 'hv-node1'
  CR_URL = "http://#{HOST}:5985/wsman".freeze
  VOL1 = 'C:\ClusterStorage\Volume1'
  VM_NAME = 'plg28-row'
  VM_ID = '47bcf071-75b6-495b-a1c2-0a77622d482b'
  NODE = 'HV-NODE2'
  NODE_IP = '192.168.1.67'

  class AttachVm
    attr_accessor :switch_name_resolver
    attr_reader :new_attributes, :id, :name, :computer_name

    def initialize(attributes)
      @new_attributes = (attributes || {}).dup
      @computer_name = 'HV-NODE2'
      @id = VM_ID
      @name = @new_attributes[:name]
    end

    def create(**_attrs); end

    def placement_path=(_value); end

    def generation
      :BIOS
    end

    def persisted?
      true
    end

    def start; end
  end

  class AttachServers
    def new(attributes = nil)
      @built = AttachVm.new(attributes)
    end

    attr_reader :built
  end

  class AttachFog
    attr_reader :servers

    def initialize
      @servers = AttachServers.new
    end

    def add_cluster_virtual_machine_role(**_kwargs)
      true
    end
  end

  def build_cr
    cr = ForemanHyperv::Hyperv.new(name: 'lab-cr', url: CR_URL, user: 'u', password: 'p')
    cr.hyperv_node_overrides = "#{NODE.downcase} = #{NODE_IP}"
    cr.stubs(:client).returns(AttachFog.new)
    cr.stubs(:client_for_node).with(NODE).returns(AttachFog.new)
    cr.stubs(:hypervisor).returns(stub('hypervisor', name: HOST, virtual_machine_path: 'C:\VMs',
                                                     virtual_hard_disk_path: 'C:\VMs\Disks'))
    cr.stubs(:validate_interfaces)
    cr.stubs(:validate_volumes)
    cr.stubs(:create_interfaces)
    cr.stubs(:create_volumes)
    cr.stubs(:cluster_named).returns(stub('cluster', name: 'HV-CL01'))
    cr.stubs(:placement_storage).returns(
      ForemanHyperv::Hyperv::ApiStorageDomain.new('Cluster Volume1', VOL1, 100, 50, 50)
    )
    cr.stubs(:enablement_supported?).returns(true)
    cr.stubs(:validate_placement!)
    cr.stubs(:clusterize?).returns(true)
    cr.stubs(:readback_finds_role?).returns([true, nil])
    # The endpoint's own switch listing — the one table that knows the GUID behind
    # the form value and the name every node shares.
    cr.stubs(:switches).returns([Switch.new(ENDPOINT_GUID, 'External')])
    cr
  end

  def test_a_created_machine_carries_the_endpoint_translation_of_its_switch_guids
    cr = build_cr
    vm = cr.create_vm(name: VM_NAME, cluster_name: 'HV-CL01', computer_name: NODE, start: '0',
                      generation: 2, memory_startup: '512', processor_count: '1',
                      dynamic_memory_enabled: '0', notes: 'plg28')

    resolver = vm.switch_name_resolver
    assert_not_nil resolver,
                   'core reads the machine it was handed back to assign MACs (setComputeDetails -> ' \
                   'select_nic); the cross-node switch identity lives only on the endpoint listing, ' \
                   'so the machine core holds must carry that translation'
    assert_equal 'External', resolver.call(ENDPOINT_GUID),
                 'the endpoint GUID the form stored resolves to the name every node shares'
    assert_nil resolver.call('ffffffff-ffff-ffff-ffff-ffffffffffff'),
               'a GUID the endpoint listing does not answer stays unresolved — bridging only ' \
               'what the endpoint itself proves'
  end
end
