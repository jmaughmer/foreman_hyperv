# frozen_string_literal: true

require 'test_helper'

# PLG-33c: the LAST sequential endpoint hop of the listing — the cluster role
# read the Registration column and the HA rows ask for during render — starts
# with the listing instead of following it, on the pipeline's fourth lane.
#
# The measured reason (PLG-33b's stage decomposition, §66): the page runs the
# probe, the node list and the endpoint rows together (PLG-33b) and THEN, at
# render, asks the resource's own client for the role index — a membership
# confirmation probe (~0.67 s warm, tens cold) plus the roles read (2.2 s
# warm). The gate that started the listing already answered the membership
# question YES seconds earlier; asking it again on the render thread is the
# last hop the workstation waits through one at a time.
#
# What this suite pins, in the order the claims get stronger:
#   1. a clustered listing's gate TRUE starts the roles read on the pipeline
#      client, and the render consumes that answer: the resource's own client
#      answers ZERO probes and ZERO role reads for the index;
#   2. the answer has LANDED by the time the listing returns — the render
#      pays no wait at all (the whole point: prefetch, not just overlap);
#   3. an empty lane is the honest "no role" index, not a fall-back trigger;
#   4. a lane that raises warns with its own words and the sequential path
#      runs VERBATIM — PLG-35's confirm-retry probe and read-retry read and
#      all — with the counts pinned so the fallback cannot quietly become
#      the fast path or lose its retry;
#   5. a stand-alone gate never taxes the speculative read (PLG-33b's
#      honored-not-taxed rule), and a legacy fog is answered :unsupported
#      before the lane is consumed — the discarded lane dies quietly;
#   6. with no pipeline there is no lane, and the PLG-35 sync path runs
#      untouched: exactly one confirmation probe and one read;
#   7. the lane is start-once and take-once, like every other hop;
#   8. the full page flow — listing then a clustered registration row —
#      reads the cluster's roles exactly ONCE across every client, and the
#      only read the resource's own client answers is endpoint_cluster's
#      (which is not the role index and predates this PR).
class HypervRoleIndexLaneTest < ActiveSupport::TestCase
  HOST = 'hv-node1'
  CR_URL = "http://#{HOST}:5985/wsman".freeze
  LEAH = 'e8f37f42-11c4-4a5e-9b3a-0f2d8c1a6b77'
  NODE2_VM = '77771111-2222-3333-4444-555566667777'

  VmDouble = Struct.new(:id, :name, :path, keyword_init: true)
  NodeDouble = Struct.new(:name)
  # A cluster model shaped like fog's: the cache block in Hyperv#clusters
  # maps its models to attributes, and endpoint_cluster reads .name back.
  ClusterDouble = Struct.new(:id, :name, keyword_init: true) do
    def attributes
      { 'id' => id, 'name' => name }
    end
  end
  # A role as the installed fog answers it: the group name the cluster builds
  # ("Virtual Machine <name>", measured) and the machine id it reports
  # upper-case on ClusterGroup.
  RoleDouble = Struct.new(:name, :virtual_machine_id, :owner_node, keyword_init: true)

  # Rails.logger is Foreman::SilencedLogger (a SimpleDelegator over the
  # Logging gem's logger), and neither a Mocha stub on it nor one on its
  # delegate intercepts Rails.logger.warn in this harness (both were tried on
  # the CT; the generated level methods SUPER around them). The mechanism
  # that demonstrably works is a singleton redefinition of warn on the
  # delegate — record, then call the original — plus a thread-local level
  # lift so the delegator's level check cannot swallow the call first (the
  # same trick SilencedLogger#silence uses). Restored in ensure either way.
  def capture_warns
    warns = []
    outer = Rails.logger
    delegate = outer.respond_to?(:__getobj__) ? outer.__getobj__ : outer
    delegate.singleton_class.send(:alias_method, :__p33c_orig_warn__, :warn)
    delegate.singleton_class.send(:define_method, :warn) do |*args, &block|
      warns << (args.first || block&.call).to_s
      __p33c_orig_warn__(*args, &block)
    end
    previous = outer.local_level if outer.respond_to?(:local_level)
    outer.local_level = Logger::DEBUG if outer.respond_to?(:local_level=)
    yield warns
    warns
  ensure
    outer.local_level = previous if outer.respond_to?(:local_level=)
    if delegate.singleton_class.method_defined?(:__p33c_orig_warn__)
      delegate.singleton_class.send(:alias_method, :warn, :__p33c_orig_warn__)
      delegate.singleton_class.send(:remove_method, :__p33c_orig_warn__)
    end
  end

  # Overlap accounting shared by the fakes of one listing (the PLG-33b suite's).
  class Overlap
    require 'monitor'
    def initialize
      @monitor = Monitor.new
      @active = 0
      @max_active = 0
    end

    def enter
      @monitor.synchronize do
        @active += 1
        @max_active = @active if @active > @max_active
      end
    end

    def exit
      @monitor.synchronize { @active -= 1 }
    end

    def max_active
      @monitor.synchronize { @max_active }
    end
  end

  # One fake fog answering every endpoint-side read the listing and the role
  # index touch, each call-counted: the probe, the node list, the endpoint
  # rows, the cluster collection endpoint_cluster reads, and — the subject
  # of this PR — the cluster role listing. The roles read has its OWN sleep
  # so a test can say "the lane landed while the listing still ran" without
  # racing the clock.
  class EndpointFog
    attr_reader :probe_calls, :nodes_calls, :rows_calls, :roles_calls

    def initialize(overlap:, machines:, node_names:, roles:, sleep_s: 0.15, roles_sleep: 0.01,
                   supports: true, roles_error: nil)
      @overlap = overlap
      @machines = machines
      @node_names = node_names
      @roles = roles
      @sleep_s = sleep_s
      @roles_sleep = roles_sleep
      @supports = supports
      @roles_error = roles_error
      @probe_calls = 0
      @nodes_calls = 0
      @rows_calls = 0
      @roles_calls = 0
      @servers = ServersCollection.new(self)
      @clusters = [ClusterDouble.new(id: 'HV-CL01', name: 'HV-CL01')]
    end

    def servers(_attrs = {})
      @servers
    end

    def cluster_nodes
      @nodes_calls += 1
      read(@sleep_s) { @node_names.map { |n| NodeDouble.new(n) } }
    end

    def supports_clusters?
      @probe_calls += 1
      read(@sleep_s) { @supports }
    end

    # The model reads clusters two ways: client.clusters.all (via _clusters)
    # and client.clusters.load(cached_attribute_rows). Answer both with the
    # same set so endpoint_cluster&.name resolves to the measured HV-CL01.
    def clusters
      ClustersCollection.new(@clusters)
    end

    def cluster_virtual_machine_roles
      RolesCollection.new(self)
    end

    def all_rows
      @rows_calls += 1
      read(@sleep_s) { @machines }
    end

    def all_roles
      @roles_calls += 1
      read(@roles_sleep) do
        raise @roles_error if @roles_error

        @roles
      end
    end

    private

    def read(seconds)
      @overlap.enter
      begin
        sleep seconds
        yield
      ensure
        @overlap.exit
      end
    end

    class ServersCollection
      def initialize(fog)
        @fog = fog
      end

      def all(filters = {})
        raise TypeError, 'no implicit conversion of nil into Hash' if filters.nil?

        @fog.all_rows
      end
    end

    class RolesCollection
      def initialize(fog)
        @fog = fog
      end

      def all(_filters = nil)
        @fog.all_roles
      end
    end

    # client.clusters.all answers models; client.clusters.load(rows) rebuilds
    # them from cached attribute hashes. endpoint_cluster reads .first.name.
    class ClustersCollection
      Loaded = Struct.new(:id, :name)

      def initialize(clusters)
        @clusters = clusters
      end

      def all(*_args)
        @clusters
      end

      def load(rows)
        rows.map { |r| Loaded.new(r[:id] || r['id'], r[:name] || r['name']) }
      end
    end
  end

  # A fog whose model predates the role listing entirely: build_cluster_role_
  # index's respond_to? guard answers :unsupported off exactly this absence.
  class LegacyFog < EndpointFog
    undef_method :cluster_virtual_machine_roles
  end

  # The RESOURCE's own client and the PIPELINE's fresh clients are DISTINCT
  # fakes: every count below is a claim about which client paid the read.
  class LaneCr < ForemanHyperv::Hyperv
    attr_accessor :client_fog, :pipeline_fog, :node_fogs

    def client_for_node(node_name)
      node_fogs.fetch(node_name.to_s.downcase) do
        raise "no fog staged for node #{node_name}"
      end
    end

    def fresh_endpoint_client
      @pipeline_fog
    end
  end

  def leah_role
    RoleDouble.new(name: "Virtual Machine leah-navia.maughmer.net",
                   virtual_machine_id: LEAH.upcase, owner_node: 'HV-NODE1')
  end

  def leah
    VmDouble.new(id: LEAH, name: 'leah-navia.maughmer.net', path: 'C:\ClusterStorage\CSV1\leah.vhdx')
  end

  def build_cr(overlap:, roles: [leah_role], supports: true, roles_error: nil, legacy_client: false)
    nodes = %w[HV-NODE1 HV-NODE2]
    machines = [VmDouble.new(id: LEAH, name: 'leah-navia.maughmer.net'),
                VmDouble.new(id: 'cccc1111-2222-3333-4444-555566667777', name: 'plain.maughmer.net')]
    @client_fog = if legacy_client
                    LegacyFog.new(overlap: overlap, machines: machines, node_names: nodes, roles: roles,
                                  supports: supports)
                  else
                    EndpointFog.new(overlap: overlap, machines: machines, node_names: nodes, roles: roles,
                                    supports: supports)
                  end
    @pipeline_fog = EndpointFog.new(overlap: overlap, machines: machines, node_names: nodes, roles: roles,
                                    supports: supports, roles_error: roles_error)
    node_fogs = {
      'hv-node2' => EndpointFog.new(overlap: overlap,
                                    machines: [VmDouble.new(id: NODE2_VM, name: 'on-node2.maughmer.net')],
                                    node_names: nodes, roles: roles)
    }
    # caching_enabled false: core's Rails.cache is shared across tests and the
    # :clusters key is name+url scoped — a stand-alone test caching [] would
    # poison the clustered full-page test's endpoint_cluster read. The model
    # logic this suite pins is cache-independent; the fakes must be too.
    cr = LaneCr.new(name: 'lab-cr', url: CR_URL, user: 'u', password: 'p', caching_enabled: false)
    cr.client_fog = @client_fog
    cr.pipeline_fog = @pipeline_fog
    cr.node_fogs = node_fogs
    cr.stubs(:client).returns(@client_fog)
    cr
  end

  setup do
    # The sync path's flap pauses really sleep (PLG-35); this suite pins the
    # CALLS, never the clock.
    ForemanHyperv::Hyperv.any_instance.stubs(:role_index_flap_pause)
  end

  # ---- 1/2: the gate starts the read, the render consumes it, own client idle ----

  def test_a_clustered_listings_gate_starts_the_role_read_and_the_render_consumes_it
    overlap = Overlap.new
    cr = build_cr(overlap: overlap)

    cr.vms # the listing: pipeline starts, the gate consumes the probe -> lane starts
    index = cr.send(:cluster_role_index)

    assert_kind_of Hash, index
    assert index.key?(LEAH), 'the page-side join finds the machine in the lane-delivered index'
    assert_equal 1, @pipeline_fog.roles_calls,
                 'the roles read happened once, on the pipeline client'
    assert_equal 0, @client_fog.roles_calls,
                 'the render consumed the lane: the resource client never re-read the roles'
    assert_equal 0, @client_fog.probe_calls,
                 'and never re-probed either: the gate that started the lane IS the membership ' \
                 'answer (PLG-35 confirms a flapped NO; a YES needs no confirmation)'
  end

  def test_the_lane_has_landed_by_the_time_the_listing_returns
    overlap = Overlap.new
    cr = build_cr(overlap: overlap)

    cr.vms.all # the FULL listing: fan-out runs while the 0.01 s lane read completes

    assert_equal 1, @pipeline_fog.roles_calls,
                 'the prefetch is the point: by the end of the listing the answer is HOME, ' \
                 'and render waits for nothing'
  end

  def test_the_full_page_reads_the_clusters_roles_exactly_once_across_every_client
    overlap = Overlap.new
    cr = build_cr(overlap: overlap)

    ids = cr.vms.all.map { |vm| vm.id.to_s.downcase }
    registration = cr.vm_registration(leah)

    assert_includes ids, NODE2_VM, 'the listing itself is unaffected'
    assert_equal :clustered, registration.state
    assert_equal 'HV-CL01', registration.cluster_name
    assert_equal 1, @pipeline_fog.roles_calls + @client_fog.roles_calls +
                   cr.node_fogs.values.sum { |f| f.roles_calls },
                 'one role listing answers the whole page, wherever it rode'
    assert_equal 0, @client_fog.roles_calls, 'and it was never the render re-asking'
    assert_equal 2, @client_fog.probe_calls,
                 'the resource client answers EXACTLY endpoint_cluster\'s two probes (its own ' \
                 'gate check and the one _clusters re-asks) — both predate this PR; the role ' \
                 'index confirmed nothing again'
  end

  # ---- 3: an empty lane is an answer, not a failure ----

  def test_an_empty_lane_is_the_honest_no_role_index_not_a_fall_back_trigger
    overlap = Overlap.new
    cr = build_cr(overlap: overlap, roles: [])

    cr.vms
    index = cr.send(:cluster_role_index)

    assert_equal({}, index, 'the cluster answered and holds no roles — that is the answer')
    assert_equal 0, @client_fog.roles_calls, 'the empty answer must not trigger a second read'
    assert_equal 0, @client_fog.probe_calls, 'or a second probe'
  end

  # ---- 4: a failed lane falls back, loudly once, to the verbatim sync path ----

  def test_a_lane_that_raises_warns_once_by_name_and_the_sync_path_runs_verbatim
    overlap = Overlap.new
    cr = build_cr(overlap: overlap, roles_error: Timeout::Error)

    index = nil
    warns = capture_warns do
      cr.vms
      index = cr.send(:cluster_role_index)
    end

    assert_kind_of Hash, index
    assert index.key?(LEAH), 'the fallback still answers the page'
    assert_equal 1, warns.count { |m| m.include?('pipelined') },
                 "the failed lane is named exactly once, before the fallback; got: #{warns.inspect}"
    assert_equal 1, @client_fog.probe_calls, 'the sequential path ran VERBATIM: PLG-35 probe...'
    assert_equal 1, @client_fog.roles_calls, '...and PLG-35 read-retry read, on the resource client'
  end

  # ---- 5: stand-alone is honored; legacy fog is answered before the lane ----

  def test_a_stand_alone_gate_never_taxed_the_speculative_role_read
    overlap = Overlap.new
    cr = build_cr(overlap: overlap, supports: false)

    cr.vms
    index = cr.send(:cluster_role_index)

    assert_equal :not_a_cluster, index
    assert_equal 0, @pipeline_fog.roles_calls,
                 'PLG-33b rule transplanted: an endpoint the gate disproved is never ' \
                 'dialled for cluster roles it cannot have'
  end

  def test_a_legacy_resource_client_is_answered_before_the_lane_is_consumed
    overlap = Overlap.new
    cr = build_cr(overlap: overlap, legacy_client: true)

    index = nil
    warns = capture_warns do
      cr.vms # the pipeline's fresh fog DOES answer roles: the lane runs speculatively...
      index = cr.send(:cluster_role_index)
    end
    sleep 0.05 # ...and dies unreaped; give the 0.01 s hop time to prove it died quietly

    assert_equal :unsupported, index, 'the respond_to? guard answers first, exactly as before'
    assert_equal 1, @pipeline_fog.roles_calls, 'one speculative read, discarded — a legacy ' \
                                              'resource under a modern fresh client is a transient upgrade state'
    assert_equal [], warns, 'the discarded lane is not an error the operator needs to see'
  end

  # ---- 6: no pipeline, no lane: PLG-35's sync path untouched ----

  def test_without_a_pipeline_the_sync_path_runs_verbatim
    overlap = Overlap.new
    cr = build_cr(overlap: overlap)

    index = cr.send(:cluster_role_index)

    assert index.key?(LEAH)
    assert_equal 1, @client_fog.probe_calls, "PLG-35's confirmation probe..."
    assert_equal 1, @client_fog.roles_calls, '...and its read, exactly once each'
    assert_equal 0, @pipeline_fog.probe_calls + @pipeline_fog.nodes_calls +
                   @pipeline_fog.rows_calls + @pipeline_fog.roles_calls,
                 'no listing, no pipeline traffic at all'
  end

  # ---- 7: the lane is claim-once and start-once, like every other hop ----

  def test_the_role_lane_starts_once_and_is_taken_once
    overlap = Overlap.new
    cr = build_cr(overlap: overlap)
    pipeline = ForemanHyperv::ListingPipeline.new([@pipeline_fog, @pipeline_fog, @pipeline_fog])

    assert_nil pipeline.take_role_lane, 'a listing that never gated cluster has no lane to take'

    reads = 0
    pipeline.start_role_lane do
      reads += 1
      %w[first]
    end
    pipeline.start_role_lane do
      reads += 1
      %w[second]
    end

    assert_equal %w[first], pipeline.take_role_lane, 'the first start wins; a re-evaluated gate cannot double-dial'
    assert_nil pipeline.take_role_lane, 'the answer is claimed once; a later consumer re-reads live'
    sleep 0.05
    assert_equal 1, reads, 'the second start ran nothing'
  end
end
