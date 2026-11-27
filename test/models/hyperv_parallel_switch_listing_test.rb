# frozen_string_literal: true

require 'test_helper'

# PLG-55: the switch listing of a clustered compute resource reads its nodes
# CONCURRENTLY.
#
# The measured reason (whole-fork review 2026-11-26): one cold node switch
# read costs ~4-5 RTT of its own, and the sequential per-node loop serialized
# a four-node cluster's cold host-form and /available_networks calls into
# ~15-20 s of pure wire time at the satellite budget this fork documents.
# Each read rides its OWN fog client — reachable nodes arrive from
# cluster_backed_hosts already composed onto their node's client
# (client_for_node), and the node_only fallbacks of down nodes, which
# cluster_backed_hosts binds to the shared endpoint client, are handed
# fresh endpoint clients before they are queued (PLG-33b: never two
# threads on one client) — so the fix adds no plumbing: it runs the same
# reads on the bounded pool the PLG-33 instance listing uses.
#
# What this suite pins, in the order the claims get stronger:
#
#   1. the reads genuinely OVERLAP — the fakes count the maximum number of
#      reads active at any instant, and the sequential loop measures exactly 1;
#   2. they overlap BEFORE the join — a start-barrier fake releases a read
#      only once all three have begun, and a sequential loop cannot assemble
#      that quorum inside the barrier deadline;
#   3. the wall-clock win is real — three half-second reads finish inside less
#      than their sum (the pool pays the slowest node, not the total);
#   4. the pool stays BOUNDED by the listing's shared WinRM shell budget, and
#      every node is read exactly once per call;
#   5. everything the sequential loop promised still holds: the union dedups
#      by name with the first-listed node's answer winning, a switch missing
#      from some nodes is still offered and still logged as missing where it
#      is, a node that cannot answer costs its switches and nothing else with
#      the same log line, and the answer never depends on which node answered
#      first. The stand-alone fallbacks (no cluster named, a cluster with no
#      hosts listed) and the field shape core's rabl renders are pinned too;
#   6. two nodes being down never means two threads on one fog client:
#      cluster_backed_hosts binds those name-only fallbacks to the SHARED
#      endpoint client, and the pool hands each a fresh endpoint client
#      before queueing (PLG-33b) — while the endpoint-redirect reads still
#      answer the full union with the same logged warnings.
class HypervParallelSwitchListingTest < ActiveSupport::TestCase
  HOST = 'hv-node1'
  CR_URL = "http://#{HOST}:5985/wsman".freeze
  CLUSTER = 'lab-cluster'
  GUID_A = 'aaaa1111-2222-3333-4444-555566667777'
  GUID_B = 'bbbb1111-2222-3333-4444-555566667777'
  GUID_C = 'cccc1111-2222-3333-4444-555566667777'

  # Fog switch-model stand-in: the cache block inside switches(host) maps
  # #attributes on these, and the result is what the fake main client's
  # #load receives back.
  SwitchModel = Struct.new(:attributes)
  # What the fake main client's switches.load hands to api_networks — the
  # name/id pair available_networks reads is all core's rabl path uses.
  ReadModel = Struct.new(:name, :id)
  NodeDouble = Struct.new(:name)
  ClusterDouble = Struct.new(:name, :nodes)

  # The overlap/barrier witness of the PLG-33 suite, same rules: who is
  # active RIGHT NOW, the high-water mark, and an optional start barrier that
  # a sequential loop — one read at a time — cannot assemble in time.
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
    end

    def entered
      @monitor.synchronize do
        @active += 1
        @arrived += 1
        @max_active = @active if @active > @max_active
        if @barrier_expect && @arrived < @barrier_expect
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @barrier_deadline
          loop do
            break if @arrived >= @barrier_expect

            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            break if remaining <= 0

            # A spurious wake re-checks the count rather than failing a
            # quorum that IS arriving; only the deadline breaks the wait.
            @condition.wait(remaining)
          end
          # Deadline passed without the quorum: a sequential loop cannot
          # assemble it, and that is the failure the barrier exists to catch.
          met = @arrived >= @barrier_expect
          raise Timeout::Error, "start barrier met only #{@arrived} of #{@barrier_expect} reads" unless met
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

  # One node's Get-VMSwitch read: reports its own overlap, optionally sleeps
  # so overlap and wall time are observable, optionally fails, and counts its
  # calls (the one-read-per-node claim).
  class TrackingSwitches
    attr_reader :calls

    def initialize(models, overlap:, sleep_s: 0.0, raise_error: nil)
      @models = models
      @overlap = overlap
      @sleep_s = sleep_s
      @raise_error = raise_error
      @calls = 0
    end

    def all(_filters = {})
      @calls += 1
      @overlap.entered
      begin
        sleep @sleep_s
        raise @raise_error if @raise_error

        @models
      ensure
        @overlap.exited
      end
    end
  end

  # The host model cluster_backed_hosts stages onto a node's own client: it
  # carries the name the switch cache keys on and the switch collection the
  # test watches.
  class HostDouble
    attr_reader :name, :switches

    def initialize(name, switches)
      @name = name
      @switches = switches
    end
  end

  # The node's fog client as client_for_node hands it over: hosts.first is
  # the host the listing stages (cluster_backed_hosts asks for nothing else).
  class NodeFog
    def initialize(host_double)
      @host_double = host_double
    end

    def hosts
      [@host_double]
    end
  end

  # The resource's own client as far as available_networks sees it:
  # switches.load rebuilds plain readable models from the cached attributes,
  # dialling nothing — fog-core's Collections#switches hands out a fresh
  # collection per call, and load is pure, so one stand-in answers every
  # host's wrap without shared state. Built with endpoint_reads it ALSO
  # plays the endpoint's hosts.new(name:) — the node_only fallback hosts,
  # which fog binds to exactly this client (see EndpointHosts).
  class MainFog
    attr_reader :dialled, :endpoint_reads, :overlap

    def initialize(endpoint_reads: nil, overlap: nil)
      @endpoint_reads = endpoint_reads
      @overlap = overlap
      @dialled = []
    end

    def switches
      @load ||= LoadDouble.new
    end

    def hosts
      @hosts ||= EndpointHosts.new(self)
    end

    class LoadDouble
      def load(models)
        models.map { |model| ReadModel.new(model['name'], model['id']) }
      end
    end

    # client.hosts.new(name:) — fog-core's Collection#new injects
    # service: the client it came from (verified against fog-core
    # collection.rb / model.rb), which is exactly the binding
    # own_client_host swaps the read off of.
    class EndpointHosts
      def initialize(owner)
        @owner = owner
      end

      def new(name:)
        EndpointBoundHost.new(
          name: name,
          service: @owner,
          models: @owner.endpoint_reads.fetch(name),
          overlap: @owner.overlap
        )
      end
    end

    # The name-only fallback of cluster_backed_hosts: its read reaches the
    # node THROUGH the owning client — the endpoint runs Get-VMSwitch scoped
    # by name and redirects — so .all dials on the owner (recorded in the
    # owner's dialled, counted by the overlap witness) and answers the
    # node's switches.
    class EndpointBoundHost
      attr_reader :name, :service

      def initialize(name:, service:, models:, overlap:)
        @name = name
        @service = service
        @models = models
        @overlap = overlap
      end

      def switches
        EndpointSwitches.new(@service, @name, @models, @overlap)
      end
    end

    class EndpointSwitches
      def initialize(client, name, models, overlap)
        @client = client
        @name = name
        @models = models
        @overlap = overlap
      end

      def all(_filters = {})
        @client.dialled << @name
        @overlap.entered
        begin
          sleep 0.2
          @models
        ensure
          @overlap.exited
        end
      end
    end
  end

  # CR whose per-node ladder resolves to staged fakes; composition still runs
  # on the caller's path (the same rule the PLG-33 suite states: the missing-
  # node raise stays a composition-time event, not thread magic).
  class CrWithNodeFogs < ForemanHyperv::Hyperv
    attr_accessor :node_fogs

    def client_for_node(node_name)
      node_fogs.fetch(node_name.to_s.strip.downcase) do
        raise "no fog staged for node #{node_name}"
      end
    end
  end

  def base_cr
    cr = CrWithNodeFogs.new(name: 'lab-cr', url: CR_URL, user: 'u', password: 'p')
    cr.stubs(:client).returns(MainFog.new)
    # The cache OBJECT is built from this answer, and an unpersisted CR caches
    # nothing either way; what this suite pins is the reads, not their
    # lifetime (FOG-35 territory).
    cr.stubs(:cluster_endpoint?).returns(false)
    cr
  end

  def switch_model(name, id)
    SwitchModel.new({ 'name' => name, 'id' => id })
  end

  # Three nodes: LAN exists on all three (one offered choice is the truth),
  # SRV-n belongs to one node each (the union must offer all three, and each
  # is "missing from" the other two).
  def three_node_cluster(overlap, node2_raise: nil, sleeps: {})
    answers = node_switch_answers
    fogs = {}
    trackers = {}
    answers.each do |name, models|
      tracker = TrackingSwitches.new(
        models,
        overlap: overlap,
        sleep_s: sleeps.fetch(name, 0.0),
        raise_error: name == 'HV-NODE2' ? node2_raise : nil
      )
      trackers[name] = tracker
      fogs[name.downcase] = NodeFog.new(HostDouble.new(name, tracker))
    end
    cr = base_cr
    cr.node_fogs = fogs
    cr.stubs(:cluster_named).returns(ClusterDouble.new(CLUSTER, answers.keys.map { |n| NodeDouble.new(n) }))
    [cr, trackers]
  end

  # The same three nodes' switch sets, shared by both stagings so the union
  # claims are about the same answer.
  def node_switch_answers
    {
      'HV-NODE1' => [switch_model('LAN', GUID_A), switch_model('SRV-1', GUID_A)],
      'HV-NODE2' => [switch_model('LAN', GUID_B), switch_model('SRV-2', GUID_B)],
      'HV-NODE3' => [switch_model('LAN', GUID_C), switch_model('SRV-3', GUID_C)]
    }
  end

  # Two nodes answer the cluster but not WinRM (client_for_node raises — the
  # real failure the cluster_backed_hosts rescue catches): they land in the
  # listing as name-only fallbacks BOUND TO THE SHARED ENDPOINT CLIENT.
  # That is a routine cluster failure, and it is the one way two workers
  # could meet on one fog client, which PLG-33b forbids. node 1 rides its
  # own node client as usual; the two fallbacks must be swapped onto fresh
  # endpoint clients before they are queued.
  def two_down_nodes(overlap)
    answers = node_switch_answers
    shared = MainFog.new(endpoint_reads: answers, overlap: overlap)
    fresh = Array.new(2) { MainFog.new(endpoint_reads: answers, overlap: overlap) }
    cr = CrWithNodeFogs.new(name: 'lab-cr', url: CR_URL, user: 'u', password: 'p')
    cr.stubs(:client).returns(shared)
    cr.stubs(:cluster_endpoint?).returns(false)
    cr.stubs(:fresh_endpoint_client).returns(fresh[0], fresh[1])
    cr.node_fogs = {
      'hv-node1' => NodeFog.new(
        HostDouble.new('HV-NODE1', TrackingSwitches.new(answers['HV-NODE1'], overlap: overlap, sleep_s: 0.2))
      )
    }
    cr.stubs(:cluster_named).returns(
      ClusterDouble.new(CLUSTER, %w[HV-NODE1 HV-NODE2 HV-NODE3].map { |n| NodeDouble.new(n) })
    )
    [cr, shared, fresh]
  end

  # The boot-disk janitor suite's round-22 lesson, learned again the hard way
  # (seed 24444 of the first battery: mocha does NOT reliably execute a block
  # passed to stubs, so a block-capture silently records nothing on some
  # seeds). A plain recording object behind Rails.stubs(:logger) — the same
  # seam that suite uses — dispatches through ordinary Ruby.
  class RecordingLogger
    attr_reader :warnings

    def initialize
      @warnings = []
    end

    def warn(msg = nil)
      @warnings << msg.to_s
    end

    def method_missing(_name, *_args)
      nil
    end

    def respond_to_missing?(_name, _include_private = false)
      true
    end
  end

  def silence_warnings
    logger = RecordingLogger.new
    Rails.stubs(:logger).returns(logger)
    logger.warnings
  end

  def test_the_three_node_switch_reads_run_concurrently
    overlap = Overlap.new
    cr, = three_node_cluster(overlap, sleeps: { 'HV-NODE1' => 0.3, 'HV-NODE2' => 0.3, 'HV-NODE3' => 0.3 })

    names = cr.available_networks(CLUSTER).map(&:name)

    assert_equal 3, overlap.max_active, 'three cold reads must be in flight at once; the sequential loop measures 1'
    assert_equal %w[LAN SRV-1 SRV-2 SRV-3], names
  end

  def test_every_node_read_begins_before_any_finishes
    overlap = Overlap.new(barrier_expect: 3)
    cr, = three_node_cluster(overlap)

    names = cr.available_networks(CLUSTER).map(&:name)

    # A sequential loop cannot assemble the quorum: the first two reads wait
    # out the barrier alone and raise, are rescued fail-soft, and only the
    # LAST read passes (its own arrival completes the count) — base's measured
    # answer is just ["LAN","SRV-3"].
    assert_equal %w[LAN SRV-1 SRV-2 SRV-3], names,
                 'reads ran one after another: only the last node beat the barrier'
  end

  def test_the_fanout_costs_the_slowest_node_not_the_sum
    overlap = Overlap.new
    cr, = three_node_cluster(overlap, sleeps: { 'HV-NODE1' => 0.5, 'HV-NODE2' => 0.5, 'HV-NODE3' => 0.5 })

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    names = cr.available_networks(CLUSTER).map(&:name)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :<, 1.0, 'three 0.5 s reads in series cost at least 1.5 s; the pool pays the slowest one'
    assert_includes names, 'SRV-1'
  end

  def test_concurrency_is_bounded_by_the_shared_shell_budget
    overlap = Overlap.new
    fogs = {}
    nodes = []
    10.times do |i|
      name = "HV-NODE#{i + 1}"
      tracker = TrackingSwitches.new([switch_model("SW-#{i + 1}", GUID_A)], overlap: overlap, sleep_s: 0.05)
      fogs[name.downcase] = NodeFog.new(HostDouble.new(name, tracker))
      nodes << NodeDouble.new(name)
    end
    cr = base_cr
    cr.node_fogs = fogs
    cr.stubs(:cluster_named).returns(ClusterDouble.new(CLUSTER, nodes))

    names = cr.available_networks(CLUSTER).map(&:name)

    assert_equal 10, names.size, 'every node still answers'
    assert_operator overlap.max_active, :<=, ForemanHyperv::ClusterNodeServers::MAX_CONCURRENT_NODE_READS,
                    'the WinRM per-user shell budget the instance listing shares'
  end

  def test_each_node_is_read_exactly_once_per_call
    overlap = Overlap.new
    cr, trackers = three_node_cluster(overlap)

    cr.available_networks(CLUSTER)

    trackers.each_value { |tracker| assert_equal 1, tracker.calls, 'no node gets asked twice for one listing' }
  end

  def test_the_same_switch_name_on_two_nodes_is_one_choice_and_the_first_node_wins
    overlap = Overlap.new
    cr, = three_node_cluster(overlap)

    networks = cr.available_networks(CLUSTER)

    lans = networks.select { |network| network.name == 'LAN' }
    assert_equal 1, lans.size, 'the same name on three nodes is one choice'
    assert_equal GUID_A, lans.first.id, 'the first-listed node owns the offered id'
  end

  def test_a_switch_missing_from_one_node_stays_an_offered_choice_and_is_logged
    overlap = Overlap.new
    cr, = three_node_cluster(overlap)
    warnings = silence_warnings

    names = cr.available_networks(CLUSTER).map(&:name)

    assert_includes names, 'SRV-3'
    missing = warnings.grep(/SRV-3 is missing from/)
    assert_equal 1, missing.size
    assert_includes missing.first, 'HV-NODE1'
    assert_includes missing.first, 'HV-NODE2'
  end

  def test_a_node_that_cannot_answer_costs_only_its_own_switches
    overlap = Overlap.new
    cr, = three_node_cluster(overlap, node2_raise: SocketError)
    warnings = silence_warnings

    names = cr.available_networks(CLUSTER).map(&:name)

    assert_not_includes names, 'SRV-2', 'the failed node loses its own switch and nothing else'
    assert_includes names, 'SRV-1'
    assert_includes names, 'SRV-3'
    assert warnings.any? { |msg| msg.include?('could not be read') && msg.include?('HV-NODE2') },
           'the same loud line the sequential loop logged'
  end

  def test_the_answer_never_depends_on_which_node_answers_first
    overlap = Overlap.new
    # Node 3 answers first, node 1 last: the answers must still land in the
    # order the cluster names its nodes, so the first-wins id is node 1's.
    cr, = three_node_cluster(overlap, sleeps: { 'HV-NODE1' => 0.3, 'HV-NODE2' => 0.1 })

    networks = cr.available_networks(CLUSTER)

    assert_equal %w[LAN SRV-1 SRV-2 SRV-3], networks.map(&:name)
    assert_equal GUID_A, networks.first.id, 'source position, not thread timing, orders the union'
  end

  def test_down_nodes_are_never_queued_on_the_shared_endpoint_client
    overlap = Overlap.new
    cr, shared, fresh = two_down_nodes(overlap)
    silence_warnings

    names = cr.available_networks(CLUSTER).map(&:name)

    assert_equal %w[LAN SRV-1 SRV-2 SRV-3], names, 'endpoint-routed fallback reads keep the union whole'
    assert_empty shared.dialled,
                 'PLG-33b forbids two threads on one client: the node_only fallbacks must be ' \
                 're-dialled onto fresh endpoint clients before queueing ' \
                 '(the sequential base read them on the shared client)'
    assert_equal [['HV-NODE2'], ['HV-NODE3']], fresh.map { |client| client.dialled.sort },
                 'each fallback rides its own fresh client, once'
    assert_equal 3, overlap.max_active, 'the fallbacks fan out too, each on its own connection'
  end

  def test_down_nodes_are_reported_loudly_and_still_answered_through_the_endpoint
    overlap = Overlap.new
    cr, = two_down_nodes(overlap)
    warnings = silence_warnings

    names = cr.available_networks(CLUSTER).map(&:name)

    assert_equal 1, warnings.grep(/HV-NODE2.*not reachable over WinRM/).size
    assert_equal 1, warnings.grep(/HV-NODE3.*not reachable over WinRM/).size
    assert_includes names, 'SRV-2', 'the endpoint redirect answers for the down node, so its switch is still offered'
    assert_includes names, 'SRV-3'
    assert_equal 1, warnings.grep(/SRV-1 is missing from/).size,
                 'the down nodes still count into the missing-switch warnings'
  end

  def test_a_standalone_resource_answers_from_the_endpoint_read_alone
    overlap = Overlap.new
    tracker = TrackingSwitches.new(
      [switch_model('LAN', GUID_A), switch_model('MGMT', GUID_B)],
      overlap: overlap
    )
    cr = base_cr
    cr.stubs(:cluster_named).returns(nil)
    cr.stubs(:hosts).returns([HostDouble.new(HOST, tracker)])

    networks = cr.available_networks(nil)

    assert_equal %w[LAN MGMT], networks.map(&:name)
    assert_equal 1, tracker.calls, 'the stand-alone listing reads the endpoint once, as it always did'
  end

  def test_a_named_cluster_that_lists_no_hosts_falls_back_to_the_endpoint_read
    overlap = Overlap.new
    tracker = TrackingSwitches.new([switch_model('LAN', GUID_A)], overlap: overlap)
    cr = base_cr
    cr.stubs(:cluster_named).returns(ClusterDouble.new(CLUSTER, []))
    cr.stubs(:hosts).returns([HostDouble.new(HOST, tracker)])

    names = cr.available_networks(CLUSTER).map(&:name)

    assert_equal ['LAN'], names
    assert_equal 1, tracker.calls
  end

  def test_the_rendered_fields_keep_core_rabls_shape
    overlap = Overlap.new
    cr, = three_node_cluster(overlap)

    lan = cr.available_networks(CLUSTER).first

    assert_equal 'LAN', lan.name
    assert_equal GUID_A, lan.id
    assert_nil lan.datacenter
    assert_equal 'LAN', lan.virtualswitch
    assert_nil lan.vlanid
  end
end
