# frozen_string_literal: true

require 'test_helper'

# PLG-33: the cross-node listing runs its WinRM reads CONCURRENTLY.
#
# The measured reason (evidence §65 window, operator report): the VM tab of a
# clustered resource costs ~13.5 s at idle, ~10 s of it in
# ClusterNodeServers#yield_sources — the endpoint's Get-VM and one fresh
# WinRM connection + cold Get-VM for every OTHER node, run one after another.
# The reads are live per call BY DESIGN (§58's ghost-machine decision: this
# page must not cache across calls), so the honest lever is parallelism, not
# caching.
#
# What this suite pins, in the order the claims get stronger:
#
#   1. the reads genuinely OVERLAP — fakes count the maximum number of reads
#      active at any instant, and a sequential run measures exactly 1;
#   2. they overlap BEFORE the join — a start-barrier fake releases a read
#      only once every source has begun, and a sequential listing cannot
#      assemble that quorum before its deadline;
#   3. everything the sequential listing promised still holds under the
#      parallel reads: the exact join ORDER (endpoint rows first, then the
#      other nodes in the order the cluster names them — pinned with fakes
#      that finish in the opposite order), the additive case-insensitive
#      id dedup, one read per source, fail-soft for a node that raises, and
#      the endpoint's own failure RAISED, not swallowed;
#   4. concurrency is BOUNDED (MAX_CONCURRENT_NODE_READS): a large cluster
#      must not stampede WinRM's per-user shell limits.
class HypervParallelNodeListingTest < ActiveSupport::TestCase
  HOST = 'hv-node1'
  CR_URL = "http://#{HOST}:5985/wsman".freeze
  ELENA = '3323c48a-a1bb-4609-b25d-b02013bc701f'
  PLAIN = 'cccc1111-2222-3333-4444-555566667777'
  NODE2_VM = '77771111-2222-3333-4444-555566667777'
  NODE3_VM = '88881111-2222-3333-4444-555566667777'

  VmDouble = Struct.new(:id, :name, keyword_init: true)
  NodeDouble = Struct.new(:name)

  # Shared across every fake of one listing: who is active RIGHT NOW, the
  # high-water mark, total arrivals, and an optional start barrier.
  class Overlap
    require 'monitor'
    def initialize(barrier_expect: nil, barrier_deadline: 5.0)
      @monitor = Monitor.new
      @condition = @monitor.new_cond
      @active = 0
      @max_active = 0
      @arrived = 0
      @barrier_expect = barrier_expect
      @barrier_deadline = barrier_deadline
      @max_seen_violation = nil
    end

    def entered
      @monitor.synchronize do
        @active += 1
        @arrived += 1
        @max_active = @active if @active > @max_active
        if @barrier_expect && @arrived < @barrier_expect
          @condition.wait(@barrier_deadline)
          # Deadline passed without the quorum: a sequential listing cannot
          # assemble it, and that is the failure the barrier exists to catch.
          raise Timeout::Error, "start barrier met only #{@arrived} of #{@barrier_expect} reads" if @arrived < @barrier_expect
        end
        @condition.broadcast
      end
    end

    def exited
      @monitor.synchronize { @active -= 1 }
    end

    def max_active
      @monitor.synchronize { @max_active }
    end
  end

  # A registration read that reports its own overlap, optionally sleeps so
  # overlap is observable, optionally fails, and counts its calls (the
  # one-read-per-source and liveness claims).
  class TrackingServers
    attr_reader :calls

    def initialize(machines, overlap:, sleep_s: 0.0, raise_error: nil)
      @machines = machines
      @overlap = overlap
      @sleep_s = sleep_s
      @raise_error = raise_error
      @calls = 0
    end

    def all(filters = {})
      @calls += 1
      @overlap.entered
      begin
        sleep @sleep_s
        raise @raise_error if @raise_error

        @machines
      ensure
        @overlap.exited
      end
    end
  end

  class TrackingFog
    attr_reader :servers_collection

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

  # CR whose per-node ladder resolves to staged fakes; composition (the
  # client_for_node call itself) still runs on the caller's path so the
  # missing-node raise stays a composition-time fail-soft, not thread magic.
  class CrWithNodes < ForemanHyperv::Hyperv
    attr_accessor :node_fogs

    def client_for_node(node_name)
      node_fogs.fetch(node_name.to_s.downcase) do
        raise "no fog staged for node #{node_name}"
      end
    end
  end

  def build_cr(fog, node_fogs)
    cr = CrWithNodes.new(name: 'lab-cr', url: CR_URL, user: 'u', password: 'p')
    cr.node_fogs = node_fogs
    cr.stubs(:client).returns(fog)
    # PLG-33b: the pipeline composes its own endpoint clients; in these faked
    # suites it must arrive at the SAME fog double, or the speculative reads
    # dial real fog while every assertion watches this one. The read-count,
    # order and bound assertions are untouched — the pipeline only changes
    # WHEN these same reads happen, and they stay counted.
    cr.stubs(:fresh_endpoint_client).returns(fog)
    cr
  end

  def endpoint_machines
    [VmDouble.new(id: ELENA, name: 'elena.maughmer.net'),
     VmDouble.new(id: PLAIN, name: 'plain.maughmer.net')]
  end

  def node2_machines
    [VmDouble.new(id: NODE2_VM.upcase, name: 'on-node2.maughmer.net'),
     VmDouble.new(id: ELENA, name: 'elena.maughmer.net')]
  end

  def three_node_cluster(overlap:, endpoint_sleep: 0.2, node_sleep: 0.2, node2_raise: nil)
    endpoint = TrackingServers.new(endpoint_machines, overlap: overlap, sleep_s: endpoint_sleep)
    fog = TrackingFog.new(endpoint, %w[HV-NODE1 HV-NODE2 HV-NODE3])
    node_fogs = {
      'hv-node2' => TrackingFog.new(
        TrackingServers.new(node2_machines, overlap: overlap, sleep_s: node_sleep, raise_error: node2_raise), fog.cluster_nodes
      ),
      'hv-node3' => TrackingFog.new(
        TrackingServers.new([VmDouble.new(id: NODE3_VM, name: 'on-node3.maughmer.net')], overlap: overlap, sleep_s: node_sleep), fog.cluster_nodes
      )
    }
    [build_cr(fog, node_fogs), endpoint, node_fogs]
  end

  def listed_ids(cr)
    cr.vms.all.map { |vm| vm.id.to_s.downcase }
  end

  # ---- 1: the reads overlap ----

  def test_the_endpoint_and_the_other_nodes_are_read_at_the_same_time
    overlap = Overlap.new
    cr, = three_node_cluster(overlap: overlap)

    ids = listed_ids(cr)

    assert_includes ids, NODE2_VM
    assert_includes ids, NODE3_VM
    assert_operator overlap.max_active, :>=, 3,
                    'three sources (endpoint + HV-NODE2 + HV-NODE3) must be in flight together; ' \
                    'a sequential ladder measures exactly 1 — that is the ~10 s the operator waits'
  end

  # ---- 2: they overlap BEFORE the join ----

  def test_no_source_is_joined_until_every_source_has_begun
    # The barrier releases a read only when all three have ENTERED. A
    # sequential listing can never assemble the quorum inside the deadline,
    # so its endpoint read fails the barrier and the page loses rows (or
    # raises) — here the full union must come back, barrier met.
    overlap = Overlap.new(barrier_expect: 3, barrier_deadline: 4.0)
    cr, = three_node_cluster(overlap: overlap, endpoint_sleep: 0.05, node_sleep: 0.05)

    ids = listed_ids(cr)

    assert_equal [ELENA, PLAIN, NODE2_VM, NODE3_VM].sort, ids.sort
    assert_operator overlap.max_active, :>=, 3
  end

  # ---- 3: every sequential contract survives ----

  def test_the_join_order_survives_reads_that_finish_out_of_order
    # The endpoint is the SLOWEST source: a parallel implementation sees
    # node2 and node3 answer first, yet the printed order stays endpoint-
    # first, then the other nodes in the order the cluster names them.
    overlap = Overlap.new
    cr, = three_node_cluster(overlap: overlap, endpoint_sleep: 0.5, node_sleep: 0.05)

    assert_equal [ELENA, PLAIN, NODE2_VM, NODE3_VM], listed_ids(cr),
                 'order is a pinned contract, not an artifact of read timing'
  end

  def test_the_join_stays_one_case_insensitive_row_per_machine
    overlap = Overlap.new
    cr, = three_node_cluster(overlap: overlap)

    ids = listed_ids(cr)

    assert_equal 1, ids.count(ELENA), 'the same GUID reported by two nodes is one row'
  end

  def test_every_source_is_read_exactly_once_per_listing
    overlap = Overlap.new
    cr, endpoint, node_fogs = three_node_cluster(overlap: overlap)

    cr.vms.all

    assert_equal 1, endpoint.calls
    assert_equal 1, node_fogs['hv-node2'].servers_collection.calls
    assert_equal 1, node_fogs['hv-node3'].servers_collection.calls
  end

  def test_a_node_that_fails_mid_flight_costs_only_its_own_rows
    overlap = Overlap.new
    cr, = three_node_cluster(overlap: overlap, node2_raise: Timeout::Error)

    ids = listed_ids(cr)

    assert_includes ids, NODE3_VM, 'the answering nodes still print'
    assert_includes ids, ELENA
    assert_not_includes ids, NODE2_VM, 'the failed node costs its rows and nothing else'
  end

  def test_the_endpoint_own_failure_still_raises_and_is_not_swallowed
    overlap = Overlap.new
    endpoint = TrackingServers.new(endpoint_machines, overlap: overlap, raise_error: SocketError)
    fog = TrackingFog.new(endpoint, %w[HV-NODE1 HV-NODE2 HV-NODE3])
    node_fogs = {
      'hv-node2' => TrackingFog.new(TrackingServers.new([], overlap: overlap), fog.cluster_nodes),
      'hv-node3' => TrackingFog.new(TrackingServers.new([], overlap: overlap), fog.cluster_nodes)
    }
    cr = build_cr(fog, node_fogs)

    assert_raises(SocketError) { cr.vms.all }
  end

  # ---- 4: concurrency is bounded ----

  def test_concurrency_is_bounded_on_a_large_cluster
    assert_equal 8, ForemanHyperv::ClusterNodeServers::MAX_CONCURRENT_NODE_READS,
                 'the bound is part of the contract (WinRM per-user shell limits)'

    overlap = Overlap.new
    names = (1..10).map { |i| "HV-N#{i.to_s.rjust(2, '0')}" }
    endpoint = TrackingServers.new(endpoint_machines, overlap: overlap, sleep_s: 0.15)
    fog = TrackingFog.new(endpoint, names)
    node_fogs = {}
    names.each_with_index do |n, i|
      next if n.casecmp?(HOST)

      node_fogs[n.downcase] = TrackingFog.new(
        TrackingServers.new([VmDouble.new(id: format('9999000%d-0000-0000-0000-000000000000', i),
                                          name: "#{n.downcase}.maughmer.net")],
                            overlap: overlap, sleep_s: 0.15),
        fog.cluster_nodes
      )
    end
    cr = build_cr(fog, node_fogs)

    ids = cr.vms.all.map { |vm| vm.id.to_s.downcase }

    assert_equal node_fogs.size + endpoint_machines.size, ids.size, 'a bounded pool still drains'
    assert_operator overlap.max_active, :<=, ForemanHyperv::ClusterNodeServers::MAX_CONCURRENT_NODE_READS
    assert_operator overlap.max_active, :>=, 2, 'bounded, but not a ladder'
  end
end
