# frozen_string_literal: true

require 'test_helper'

# PLG-46 (review observation 1): the config root of a create ROUTED to a named
# node is that NODE's own answer. create_vm took its config path from
# `storage&.id || hypervisor.virtual_machine_path`, and the hypervisor half is
# the ENDPOINT's host read — Get-VMHost through the endpoint's client. On the
# self rung that is the machine's own host and the fallback is honest (PLG-14
# left it untouched); on a machine routed to another node the endpoint's root
# may be the endpoint's LOCAL disk, and the config files named on it land off
# the node that owns and runs the machine — the same one-machine-local-disk
# fact PLG-14 refuses for a blank volume path, arriving from the route instead
# of from the volume. This suite pins the three answers a create may take, and
# the one it may never take again:
#
#   1. a routed create with no placed volume takes the routed node's OWN
#      config root, read through the same client the machine rides;
#   2. a node that answers no root REFUSES (PLG-14 doctrine — refuse, do not
#      guess), and nothing is asked of the host;
#   3. a node read that cannot answer at all travels up untouched — an
#      unanswered read is no answer either, and base never hears the node at
#      all, so base creates on the endpoint's root instead of failing;
#   4. the routed create that DOES place a volume keeps the volume as its
#      config root and dials the node's host read ZERO times — PLG-46 widens
#      reads on the routed no-volume path only (green on both trees, a pin).
#
# The stand-alone (self-rung) fallback is pinned by the PLG-16 suite
# (hyperv_placement_wiring_test.rb, 'C:\VMs') and is not repeated here.
class HypervRoutedConfigRootTest < ActiveSupport::TestCase
  ENDPOINT = 'hv-node1'
  NODE = 'hv-node2'
  NODE_IP = '192.168.1.67'
  VOL1 = 'C:\ClusterStorage\Volume1'
  ENDPOINT_ROOT = 'C:\EndpointVMs'
  NODE_ROOT = 'C:\NodeVMs'
  CR_URL = "http://#{ENDPOINT}:5985/wsman".freeze

  # The machine the NODE client's servers.new builds. It records the create
  # kwargs exactly as they arrived — the config root the create shipped is the
  # fact under test — and answers the post-create surface (placement_path,
  # generation, start/stop) so create_vm runs its steps without fog, the way
  # the PLG-16 suite's double does. persisted? follows fog-core: FALSE until
  # create has been sent — which is exactly why a refusal raised before the
  # create tears nothing down: the rescue's rollback asks persisted? first.
  class RootedVm
    attr_accessor :switch_name_resolver, :placement_path
    attr_reader :new_attributes, :create_kwargs, :generation

    def initialize(attributes)
      @new_attributes = (attributes || {}).dup
      @placement_path = @new_attributes[:placement_path]
      @generation = :BIOS
      @persisted = false
    end

    def name
      @new_attributes[:name]
    end

    def computer_name
      @new_attributes[:computer_name]
    end

    def create(**attrs)
      @create_kwargs = attrs
      @persisted = true
    end

    def persisted?
      @persisted
    end

    def start; end

    def stop; end
  end

  class RootedServers
    attr_reader :built

    def new(attributes = nil)
      @built = RootedVm.new(attributes)
    end
  end

  # The node's Get-VMHost answer. Every read counts, so "the node was not
  # dialed for a root" is an observable fact, and a node read can be made to
  # die outright instead of answering a blank.
  class RootedHosts
    attr_reader :reads

    def initialize(root:, raises: false)
      @root = root
      @raises = raises
      @reads = 0
    end

    def first
      @reads += 1
      raise 'WSMAN: the node did not answer' if @raises

      Struct.new(:virtual_machine_path).new(@root)
    end
  end

  class RootedFog
    attr_reader :servers, :hosts

    def initialize(node_root: NODE_ROOT, raises: false)
      @servers = RootedServers.new
      @hosts = RootedHosts.new(root: node_root, raises: raises)
    end
  end

  def build_cr(node_fog:, endpoint_fog: RootedFog.new)
    cr = ForemanHyperv::Hyperv.new(name: 'lab-cr', url: CR_URL, user: 'u', password: 'p')
    cr.hyperv_node_overrides = "#{NODE.downcase} = #{NODE_IP}"
    cr.stubs(:client).returns(endpoint_fog)
    cr.stubs(:client_for_node).with(NODE).returns(node_fog)
    # The endpoint's own host read, with a root OBSERVABLY different from the
    # node's: the base tree answers the routed create with THIS one.
    cr.stubs(:hypervisor).returns(stub('hypervisor', name: ENDPOINT, virtual_machine_path: ENDPOINT_ROOT,
                                                     virtual_hard_disk_path: 'C:\EndpointVMs\Disks'))
    cr.stubs(:enablement_supported?).returns(true)
    cr.stubs(:validate_placement!)
    cr.stubs(:self_rung_name?).with(NODE).returns(false)
    cr.stubs(:validate_interfaces)
    cr.stubs(:validate_volumes)
    cr.stubs(:create_interfaces)
    cr.stubs(:create_volumes)
    cr
  end

  def routed_create(cr, name: 'plg46-routed')
    cr.create_vm(name: name, computer_name: NODE, start: '0', generation: 2,
                 memory_startup: '512', processor_count: '1',
                 dynamic_memory_enabled: '0', notes: 'plg46')
  end

  # ---- 1. the routed node answers its own root ----

  def test_a_routed_create_takes_the_config_root_from_the_node_it_rides
    node = RootedFog.new(node_root: NODE_ROOT)
    cr = build_cr(node_fog: node)

    routed_create(cr)

    assert_equal NODE_ROOT, node.servers.built.create_kwargs[:path],
                 'the config root of a create routed to a node is the NODE’s own answer: the ' \
                 "endpoint’s root (#{ENDPOINT_ROOT}) may be the endpoint’s local disk, and a machine " \
                 'created through the node’s client must not be named onto it'
    assert_equal 1, node.hosts.reads,
                 'the root is read once, from the node, through the client the machine rides'
  end

  # ---- 2. a node answering no root refuses ----

  def test_a_routed_create_refuses_when_the_node_answers_no_config_root
    node = RootedFog.new(node_root: '  ')
    cr = build_cr(node_fog: node)

    error = assert_raises(ForemanHyperv::OperationRefused) { routed_create(cr) }
    assert_includes error.message, NODE.to_s, 'the refusal names the node that answered nothing'
    assert_includes error.message, 'nothing was created',
                    'the refusal is decided before vm.create — servers.new sent nothing, so ' \
                    'there is nothing to tear down'
    assert_nil node.servers.built.create_kwargs,
               'a node that answers no root hears no create: PLG-14 refuses, it does not guess'
  end

  # ---- 3. a node read that cannot answer travels up untouched ----

  def test_a_node_read_that_cannot_answer_propagates_rather_than_becoming_a_guess
    node = RootedFog.new(raises: true)
    cr = build_cr(node_fog: node)

    error = assert_raises(RuntimeError) { routed_create(cr) }
    assert_includes error.message, 'did not answer',
                    'an unanswered read is no answer either: the transport failure travels up ' \
                    'untouched and the create does not proceed on it'
    assert_nil node.servers.built.create_kwargs,
               'the create was never asked of the host'
  end

  # ---- 4. the placed routed create keeps the volume (green on both trees) ----

  def test_a_routed_placed_create_keeps_the_volume_and_dials_the_node_root_zero_times
    node = RootedFog.new(node_root: NODE_ROOT)
    cr = build_cr(node_fog: node)
    cr.stubs(:cluster_named).returns(stub('cluster', name: 'lab-cluster'))
    cr.stubs(:placement_storage).returns(
      ForemanHyperv::Hyperv::ApiStorageDomain.new('Cluster Volume1', VOL1, 100, 50, 50)
    )
    cr.stubs(:clusterize?).returns(false)

    cr.create_vm(name: 'plg46-placed', computer_name: NODE, cluster_name: 'lab-cluster',
                 start: '0', generation: 2, memory_startup: '512', processor_count: '1',
                 dynamic_memory_enabled: '0', notes: 'plg46')

    assert_equal VOL1, node.servers.built.create_kwargs[:path],
                 'a placed create’s config root is the placed volume — PLG-46 changes only the ' \
                 'routed create that placed no volume'
    assert_equal 0, node.hosts.reads,
                 'a placed create does not widen reads: the volume already answers, the node’s ' \
                 'own root is not asked'
  end
end
