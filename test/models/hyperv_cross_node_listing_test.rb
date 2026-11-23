# frozen_string_literal: true

require 'test_helper'

# PLG-29b: on a cluster, the instance list must list the cluster's machines,
# not just the ones the endpoint node happens to have registered.
#
# The shape that started this (evidence §58, §59): Get-VM answers for the
# machines registered on the node it ran on and NOTHING else. A clustered
# machine owned by another node is invisible to the endpoint's read — the
# acceptance row for PLG-28 (elena-smolen, owned by HV-NODE2) never appeared
# on the list page at all, which is also why its UI Delete had to be aimed at
# it by hand. Actions already solve this per machine: find_vm_by_uuid asks the
# cluster who owns the machine and reads that node (PLG-27's ladder). The list
# never got the same treatment, so the page could only ever show a subset, and
# "the machine is gone" was indistinguishable from "another node owns it".
#
# What this suite pins, in the order the claims get stronger:
#
#   1. every node's registrations join the list, joined by machine id
#      case-insensitively (the cluster reports GUIDs upper-case, the plugin
#      holds them lower-case) with the endpoint's own rows kept — this is
#      ADDITIVE: a machine the endpoint can answer for is never displaced by
#      a node's answer;
#   2. a node that will not answer does not blank the page (nodes drain, join
#      and stop answering with no event Foreman is told about), but the
#      endpoint's own refusal still surfaces: a page whose one guaranteed
#      read failed is not a listing, it is an error;
#   3. stand-alone endpoints keep the exact pre-PLG-29b behaviour — the live
#      fog collection, one read, no node vocabulary asked;
#   4. a fog without the node vocabulary degrades to the endpoint's answer
#      rather than raising: the listing got no WORSE than the build before
#      this one, and the degraded shape is the pinned contract, not a crash;
#   5. reads are per call: the fog collection this replaces is live, and a
#      list that cached across calls would resurrect the delete-a-row-see-a-
#      ghost failure this page has already had once.
class HypervCrossNodeListingTest < ActiveSupport::TestCase
  HOST = 'hv-node1'
  CR_URL = "http://#{HOST}:5985/wsman".freeze
  ELENA = '3323c48a-a1bb-4609-b25d-b02013bc701f'
  NODE2_VM = '77771111-2222-3333-4444-555566667777'
  PLAIN = 'cccc1111-2222-3333-4444-555566667777'

  # A listed machine: the identity the union keys on, plus a name.
  VmDouble = Struct.new(:id, :name, keyword_init: true)

  # The role the cluster's index carries, to the shape vm_registration reads.
  RoleDoubleLike = Struct.new(:owner_node)

  # A fog Servers collection, counting every read so liveness and the
  # one-read-per-node claims are observable, and able to stand in for a node
  # that has stopped answering.
  class ServersDouble
    attr_reader :calls

    def initialize(machines, raise_error: nil)
      @machines = machines
      @raise_error = raise_error
      @calls = 0
    end

    def all(filters = {})
      # fog's Collection#all splats the filters (**filters): nil is a
      # TypeError there, and the union must not introduce a call shape the
      # collection it replaces rejected.
      raise TypeError, 'no implicit conversion of nil into Hash' if filters.nil?

      @calls += 1
      raise @raise_error if @raise_error

      @machines
    end

    def get(identifier = nil, **_filters)
      all.find { |vm| vm.id.to_s.casecmp?(identifier.to_s) }
    end
  end

  NodeDouble = Struct.new(:name)

  # The endpoint's fog client on a clustered build: its own servers, and the
  # cluster's node list.
  class ClusterFogDouble
    attr_reader :servers_collection, :nodes

    def initialize(servers, node_names)
      @servers_collection = servers
      @nodes = node_names.map { |n| NodeDouble.new(n) }
    end

    def servers(_attrs = {})
      @servers_collection
    end

    def cluster_nodes
      @nodes
    end

    def supports_clusters?
      true
    end
  end

  # A stand-alone endpoint: the cluster vocabulary is answered, but the
  # endpoint is not a cluster.
  class StandaloneFogDouble < ClusterFogDouble
    def supports_clusters?
      false
    end
  end

  # A fog with no node vocabulary at all — a build this plugin still supports,
  # where cross-node listing cannot be asked for.
  class LegacyFogDouble < ClusterFogDouble
    def cluster_nodes
      raise NoMethodError, "undefined method 'cluster_nodes' for an instance"
    end
  end

  def endpoint_machines
    [
      VmDouble.new(id: ELENA, name: 'elena-smolen.maughmer.net'),
      VmDouble.new(id: PLAIN, name: 'plain.maughmer.net')
    ]
  end

  def node2_machines
    [
      VmDouble.new(id: NODE2_VM.upcase, name: 'on-node2.maughmer.net'),
      VmDouble.new(id: ELENA, name: 'elena-smolen.maughmer.net')
    ]
  end

  # The resource with its endpoint fog and the per-node ladder resolved to
  # fakes: HV-NODE2 answers node2_machines, HV-NODE3 answers nothing.
  # The resource with its endpoint fog swapped, and the per-node ladder
  # overridden plainly (not stubbed): HV-NODE2 answers node2_machines,
  # HV-NODE3 refuses; a node nobody staged raises through.
  class CrWithNodes < ForemanHyperv::Hyperv
    attr_accessor :node_fogs

    def client_for_node(node_name)
      node_fogs.fetch(node_name.to_s.downcase) do
        raise "no fog staged for node #{node_name}"
      end
    end
  end

  def build_cr(fog, node_fogs = {})
    cr = CrWithNodes.new(name: 'lab-cr', url: CR_URL, user: 'u', password: 'p')
    cr.node_fogs = node_fogs
    cr.stubs(:client).returns(fog)
    # PLG-33b: the pipeline composes its own endpoint clients; in these faked
    # suites it must arrive at the SAME fog double (see the parallel suite for
    # the full reason). Count, order and fail-soft assertions untouched.
    cr.stubs(:fresh_endpoint_client).returns(fog)
    cr
  end

  def clustered_cr(nodes: %w[HV-NODE1 HV-NODE2 HV-NODE3])
    endpoint = ServersDouble.new(endpoint_machines)
    fog = ClusterFogDouble.new(endpoint, nodes)
    node_fogs = {
      'hv-node2' => ClusterFogDouble.new(ServersDouble.new(node2_machines), nodes),
      'hv-node3' => ClusterFogDouble.new(ServersDouble.new([], raise_error: Timeout::Error), nodes)
    }
    [build_cr(fog, node_fogs), fog, node_fogs]
  end

  def listed_ids(cr)
    cr.vms.all.map { |vm| vm.id.to_s.downcase }
  end

  def test_a_clustered_listing_includes_the_machines_registered_on_the_other_nodes
    cr, = clustered_cr

    ids = listed_ids(cr)

    assert_includes ids, NODE2_VM,
                    'a machine registered on HV-NODE2 is a machine of this cluster: the endpoint node ' \
                    'cannot see it and the list used to print nothing — the operator could not tell ' \
                    '"deleted" from "owned by another node"'
    assert_includes ids, ELENA, 'the endpoint keeps its own rows: the union adds, it never displaces'
    assert_includes ids, PLAIN
  end

  def test_the_join_is_by_machine_id_and_case_insensitive_and_keeps_one_row_per_machine
    cr, = clustered_cr

    ids = listed_ids(cr)

    # node2 answers the SAME machine with an upper-case GUID (measured: the
    # cluster and WMI report ids upper-case); that is one machine, one row.
    assert_equal 1, ids.count(ELENA),
                 'the same GUID with different case is one machine, not two rows'
    assert_equal [ELENA, PLAIN, NODE2_VM], ids,
                 'the endpoint node reads first, then the other nodes in the order the cluster names them'
  end

  def test_a_node_that_will_not_answer_costs_its_rows_and_nothing_else
    # HV-NODE3 raises Timeout (drained, stopped, firewall): the page still
    # lists what every answering node reported. Nodes join and leave a cluster
    # with no event Foreman is told about; a list that blanked on one dead
    # node would tell the operator the cluster is empty.
    cr, = clustered_cr

    ids = listed_ids(cr)

    assert_equal [ELENA, PLAIN, NODE2_VM], ids
  end

  def test_the_endpoint_s_own_read_failing_is_still_an_error_not_a_quiet_partial_page
    endpoint = ServersDouble.new([], raise_error: Timeout::Error)
    fog = ClusterFogDouble.new(endpoint, %w[HV-NODE1 HV-NODE2])
    cr = build_cr(fog, 'hv-node2' => ClusterFogDouble.new(ServersDouble.new(node2_machines), ['HV-NODE1']))

    # The endpoint read is the read the page already makes today; its failure
    # is the failure the controller already reports. Silently answering only
    # the rows of the other nodes would print a page that looks complete
    # and is not.
    assert_raises(Timeout::Error) do
      cr.vms.all
    end
  end

  def test_a_standalone_endpoint_still_returns_the_live_fog_collection_untouched
    endpoint = ServersDouble.new(endpoint_machines)
    fog = StandaloneFogDouble.new(endpoint, [])
    cr = build_cr(fog)

    result = cr.vms

    assert_same endpoint, result,
                'the stand-alone path is untouched: the fog collection itself, no union wrapper'
    ids = listed_ids(cr)
    assert_equal [ELENA, PLAIN], ids
    # PLG-33b accounting: two reads of the endpoint now, and both are known.
    # The first vms() started a speculative Get-VM the stand-alone gate
    # discarded (never shown, never answered from); this second listing
    # re-reads LIVE — the claim-once rule that keeps §58's ghost out. One
    # listing per request (what the page actually does) reads exactly once.
    # take_rows SETTLES the discarded speculative read before the count: its
    # thread runs the read concurrently, and an unjoined thread next to a
    # call-count assert is a race, not a contract.
    pipeline = cr.instance_variable_get(:@listing_pipeline)
    pipeline.take_rows if pipeline
    assert_equal 2, endpoint.calls
  end

  def test_a_fog_without_the_node_vocabulary_lists_the_endpoint_answer_and_does_not_raise
    endpoint = ServersDouble.new(endpoint_machines)
    fog = LegacyFogDouble.new(endpoint, [])
    cr = build_cr(fog)

    ids = listed_ids(cr)

    assert_equal [ELENA, PLAIN], ids,
                 'a fog that cannot be asked for the node list degrades to exactly the pre-PLG-29b ' \
                 'answer; it does not raise and does not take the page down'
  end

  def test_the_node_the_endpoint_runs_on_is_never_read_twice
    cr, fog, node_fogs = clustered_cr
    # HV-NODE1 is the endpoint's own node (the URL names it) and is in the
    # cluster's node list (measured shape). Reading it again would cost a
    # second WinRM round trip and a second copy of every row.
    assert_includes fog.cluster_nodes.map(&:name), HOST.upcase

    listed_ids(cr)

    assert_not node_fogs.key?('hv-node1'),
               'the ladder must not even be asked for the node the endpoint runs on: its rows came from ' \
               'the endpoint read'
  end

  def test_get_finds_a_machine_owned_by_another_node
    cr, = clustered_cr

    vm = cr.vms.get(NODE2_VM)

    assert_equal NODE2_VM, vm.id.to_s.downcase,
                 'the page links each row through vms.get; a listing that shows a machine whose ' \
                 'get answers NotFound would 404 the row the union just surfaced'
  end

  def test_each_call_reads_afresh_and_asks_each_answering_node_exactly_once
    cr, fog, node_fogs = clustered_cr

    listed_ids(cr)
    listed_ids(cr)

    assert_equal 2, fog.servers_collection.calls,
                 'the fog collection this replaces is live per call; a listing that cached across ' \
                 'calls would resurrect the deleted-machine-ghost failure this page already had once'
    assert_equal 2, node_fogs['hv-node2'].servers_collection.calls
  end

  def test_a_clustered_machine_read_from_another_node_still_answers_the_registration_column
    # The two halves of PLG-29 join up here: the row arrives through node2's
    # read, and the column names the cluster owner — the Computer cell says
    # HV-NODE2 because that node answered, and the Registration cell says the
    # same thing independently because the cluster's role listing owns it.
    cr, = clustered_cr
    cr.stubs(:cluster_role_index).returns(
      NODE2_VM => RoleDoubleLike.new('HV-NODE2'),
      ELENA => RoleDoubleLike.new('HV-NODE2')
    )
    foreign = cr.vms.all.find { |vm| vm.id.to_s.downcase == NODE2_VM }

    registration = cr.vm_registration(foreign)

    assert_equal :clustered, registration.state
    assert_equal 'HV-NODE2', registration.owner_node
  end
end
