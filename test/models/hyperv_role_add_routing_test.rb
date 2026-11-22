# frozen_string_literal: true

require 'test_helper'

# PLG-27: the role add rides the client that built the machine, at the identity
# the placement ladder resolved — never the endpoint client addressed by the
# model's post-merge name.
#
# The first cross-node clustered create through the UI (evidence §57) built the
# machine on HV-NODE2 through its per-node client — VM, disks, and NIC all
# landed where the ladder pointed — and then add_cluster_role_proven dialled
# the ENDPOINT's fog client with computer_name: vm.computer_name. That name is
# not the address the ladder dialled: fog's create merges the host's New-VM
# answer back over the model with every return field, and ComputerName in that
# answer is the node's own name (measured: "HV-NODE2", the NetBIOS name). The
# endpoint client's WinRM guard admits only its endpoint and names already
# connected, so the bare node name was refused before the cmdlet ran — the Add
# never executed, the readback never found a role, and the strand contract left
# a machine on Volume1 for an operator. Every other node-routed operation in
# this plugin (the N6 ladder, find_vm_by_uuid's fallback) dials the node's own
# client with the resolved ADDRESS; the role add was the one writer that
# re-derived an identity from the model instead of using the one already
# resolved.
class HypervRoleAddRoutingTest < ActiveSupport::TestCase
  HOST = 'hv-node1'
  CR_URL = "http://#{HOST}:5985/wsman".freeze
  VOL1 = 'C:\ClusterStorage\Volume1'
  VM_NAME = 'plg27-row'
  VM_ID = 'ab0cdba7-6c16-41a0-819c-352a9b08aeb0'
  NODE = 'HV-NODE2'
  NODE_IP = '192.168.1.67'

  # One shared log so a test can see WHICH client received the add, not just
  # that some client did.
  class AddLog
    attr_reader :entries

    def initialize
      @entries = []
    end

    def record(service_tag, kwargs)
      @entries << { service: service_tag }.merge(kwargs)
    end
  end

  # The machine fog builds. It answers create the way the real fog does: the
  # host's reply merges back over the model, and ComputerName in that reply is
  # the node's own name — the identity the ladder dialled is gone from the
  # model the moment the machine exists. That overwrite is the whole trap this
  # suite pins.
  class RoutingVm
    attr_reader :new_attributes, :id, :name

    def initialize(attributes, answer_name)
      @new_attributes = (attributes || {}).dup
      @answer_name = answer_name
      @computer_name = @new_attributes[:computer_name]
      @id = VM_ID
      @name = @new_attributes[:name]
    end

    def computer_name
      @computer_name
    end

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

    def start; end
  end

  class RoutingServers
    def initialize(answer_name)
      @answer_name = answer_name
    end

    def new(attributes = nil)
      @built = RoutingVm.new(attributes, @answer_name)
    end

    attr_reader :built
  end

  # A fog client double that records every role add it receives under its own
  # tag. Both the endpoint client and the per-node client are doubles of this
  # class, so "which client ran the Add" is an observable fact.
  class RoutingFog
    attr_reader :servers

    def initialize(service_tag, log, answer_name)
      @service_tag = service_tag
      @log = log
      @servers = RoutingServers.new(answer_name)
    end

    def add_cluster_virtual_machine_role(**kwargs)
      @log.record(@service_tag, kwargs)
      true
    end
  end

  def build_cr(answer_name: NODE)
    log = AddLog.new
    endpoint = RoutingFog.new(:endpoint, log, answer_name)
    node = RoutingFog.new(:node, log, answer_name)

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
    cr.stubs(:clusterize?).returns(true)
    # The readback proof is PLG-21a's own contract (pinned in the role-readback
    # suite, endpoint-based, unchanged here); the role is found on the first
    # pass so the ONLY variable in these two tests is where the Add was sent.
    cr.stubs(:readback_finds_role?).returns([true, nil])
    [cr, log]
  end

  def create_attrs(extra = {})
    { name: VM_NAME, cluster_name: 'lab-cluster', start: '0', generation: 2,
      memory_startup: '512', processor_count: '1',
      dynamic_memory_enabled: '0', notes: 'plg27' }.merge(extra)
  end

  # ---- the node-rung: the Add rides the node client at the resolved address ----

  def test_a_node_routed_create_adds_the_role_on_the_node_client_at_its_address
    cr, log = build_cr
    cr.create_vm(create_attrs(computer_name: NODE))

    assert_equal 1, log.entries.size, 'the role Add is sent exactly once per create'
    add = log.entries.first
    assert_equal :node, add[:service],
                 'the Add runs where the machine was built — fog documents that the cluster ' \
                 'service being configured is the LOCAL one, and the endpoint client refuses ' \
                 'a bare node name its set has never dialed'
    assert_equal NODE_IP, add[:computer_name],
                 'the identity is the address the placement ladder resolved, not the name the ' \
                 'host merge wrote back over the model — the node answers its own NetBIOS name, ' \
                 'and the client that built the machine dials that address'
    assert_equal VM_ID, add[:id]
  end

  # ---- the self-rung: unchanged endpoint semantics, pinned against regression ----

  def test_a_self_rung_create_adds_the_role_on_the_endpoint_itself
    cr, log = build_cr(answer_name: HOST)
    cr.create_vm(create_attrs)

    assert_equal 1, log.entries.size
    add = log.entries.first
    assert_equal :endpoint, add[:service],
                 'a machine built through the resource own client keeps its role add on that ' \
                 'client: the endpoint is in its own set, and the ladder routed nothing away'
    assert_equal HOST, add[:computer_name],
                 'the self-rung identity stays the model name the endpoint itself answers'
  end
end
