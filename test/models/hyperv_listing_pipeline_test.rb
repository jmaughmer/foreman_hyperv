# frozen_string_literal: true

require 'test_helper'

# PLG-33b: the listing's endpoint-side reads run CONCURRENTLY, and the page
# consumes exactly what it started.
#
# The measured reason (production.log + stage probe): the VM tab runs FIVE
# hops before its fan-out even begins — cluster probe (0.67 s warm, 22–44 s
# cold), cluster node list (2.6 s), endpoint Get-VM (0.7 s), then the
# already-parallel other-node reads (PLG-33). Cold loads pay the SUM of the
# cold hops (measured 172.9 s = 44 s probe + 124 s listing); fusing the
# endpoint-side hops into the fan-out window turns a page into its SLOWEST
# single hop instead.
#
# What this suite pins, in the order the claims get stronger:
#
#   1. the three endpoint-side reads OVERLAP — fakes count the maximum reads
#      active at any instant and the sequential ladder measures exactly 1;
#   2. the listing CONSUMES what it started: the node list and endpoint rows
#      come from the speculative reads (the resource's own client answers
#      ZERO remote reads for them) — no read is done twice;
#   3. the gate is the PROBE: the tri-state is answered from the probe future
#      (once), and stand-alone still gets the UNTOUCHED fog collection with
#      the speculative reads silently discarded (a failed speculative node
#      list must not warn on a resource that has no cluster);
#   4. the safety valves: non-default filters never ride a speculative read;
#      a pipeline that cannot compose degrades to today's sequential path
#      verbatim; ClusterNodeServers built directly knows nothing of the
#      pipeline; a failed probe hop is RE-ASKED on the thread (PLG-44),
#      named once, and only a re-ask that itself raises folds to
#      stand-alone with the established text;
#   5. the unbounded Future#value pop (the page thread's wait) is only safe
#      because EVERY pipeline hop client carries the PLG-16 WinRM waits —
#      pinned so a future wire-option change cannot silently strip them and
#      leave a page thread blocked forever on a stalled cold hop.
class HypervListingPipelineTest < ActiveSupport::TestCase
  HOST = 'hv-node1'
  CR_URL = "http://#{HOST}:5985/wsman".freeze
  ELENA = '3323c48a-a1bb-4609-b25d-b02013bc701f'
  PLAIN = 'cccc1111-2222-3333-4444-555566667777'
  NODE2_VM = '77771111-2222-3333-4444-555566667777'

  VmDouble = Struct.new(:id, :name, keyword_init: true)
  NodeDouble = Struct.new(:name)

  # Rails.logger is Foreman::SilencedLogger (a SimpleDelegator over the
  # Logging gem's logger), and neither a Mocha stub on it nor one on its
  # delegate intercepts Rails.logger.warn in this harness (both were tried on
  # the CT; the generated level methods SUPER around them). The mechanism
  # that demonstrably works is a singleton redefinition of warn on the
  # delegate — record, then call the original — plus a thread-local level lift
  # so the delegator's level check cannot swallow the call first (the same
  # trick SilencedLogger#silence uses). Restored in ensure either way.
  def capture_warns
    warns = []
    outer = Rails.logger
    delegate = outer.respond_to?(:__getobj__) ? outer.__getobj__ : outer
    delegate.singleton_class.send(:alias_method, :__p33b_orig_warn__, :warn)
    delegate.singleton_class.send(:define_method, :warn) do |*args, &block|
      warns << (args.first || block&.call).to_s
      __p33b_orig_warn__(*args, &block)
    end
    previous = outer.local_level if outer.respond_to?(:local_level)
    outer.local_level = Logger::DEBUG if outer.respond_to?(:local_level=)
    yield warns
    warns
  ensure
    outer.local_level = previous if outer.respond_to?(:local_level=)
    if delegate.singleton_class.method_defined?(:__p33b_orig_warn__)
      delegate.singleton_class.send(:alias_method, :warn, :__p33b_orig_warn__)
      delegate.singleton_class.send(:remove_method, :__p33b_orig_warn__)
    end
  end

  # Overlap accounting shared by the fakes of one listing (same shape as the
  # PLG-33 suite: max active readers at any instant; sequential measures 1).
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

  # One fake fog answering the three endpoint-side reads, each tracked
  # (overlap + call counts + optional sleep/raise), plus the same per-node
  # endpoint read the PLG-33 suite tracks.
  class EndpointFog
    attr_reader :probe_calls, :nodes_calls, :rows_calls

    def initialize(overlap:, machines:, node_names:, sleep_s: 0.15,
                   supports: true, nodes_error: nil, probe_error: nil)
      @overlap = overlap
      @machines = machines
      @node_names = node_names
      @sleep_s = sleep_s
      @supports = supports
      @nodes_error = nodes_error
      @probe_error = probe_error
      @probe_calls = 0
      @nodes_calls = 0
      @rows_calls = 0
      @servers = ServersCollection.new(self)
    end

    def servers(_attrs = {})
      @servers
    end

    def cluster_nodes
      @nodes_calls += 1
      read do
        raise @nodes_error if @nodes_error

        @node_names.map { |n| NodeDouble.new(n) }
      end
    end

    def supports_clusters?
      @probe_calls += 1
      read do
        raise @probe_error if @probe_error

        @supports
      end
    end

    def all_rows
      @rows_calls += 1
      read { @machines }
    end

    private

    def read
      @overlap.enter
      begin
        sleep @sleep_s
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
  end

  # CR with the endpoint fog and the per-node ladder resolved to fakes. The
  # RESOURCE's own client and the PIPELINE's fresh clients are DISTINCT fake
  # instances: a pin on the pipeline's fog cannot pass in base code, which
  # never composes a second client.
  class PipelineCr < ForemanHyperv::Hyperv
    attr_accessor :client_fog, :pipeline_fog, :node_fogs, :fresh_client_error

    def client_for_node(node_name)
      node_fogs.fetch(node_name.to_s.downcase) do
        raise "no fog staged for node #{node_name}"
      end
    end

    def fresh_endpoint_client
      raise @fresh_client_error if @fresh_client_error

      @pipeline_fog
    end
  end

  def endpoint_machines
    [VmDouble.new(id: ELENA, name: 'elena.maughmer.net'),
     VmDouble.new(id: PLAIN, name: 'plain.maughmer.net')]
  end

  def node2_machines
    [VmDouble.new(id: NODE2_VM.upcase, name: 'on-node2.maughmer.net')]
  end

  def build_cr(overlap:, supports: true, nodes_error: nil, probe_error: nil,
               sleep_s: 0.15, fresh_client_error: nil)
    nodes = %w[HV-NODE1 HV-NODE2]
    @client_fog = EndpointFog.new(overlap: overlap, machines: endpoint_machines,
                                  node_names: nodes, sleep_s: sleep_s, supports: supports,
                                  nodes_error: nodes_error, probe_error: probe_error)
    @pipeline_fog = EndpointFog.new(overlap: overlap, machines: endpoint_machines,
                                    node_names: nodes, sleep_s: sleep_s, supports: supports,
                                    nodes_error: nodes_error, probe_error: probe_error)
    node_fogs = {
      'hv-node2' => EndpointFog.new(overlap: overlap, machines: node2_machines,
                                    node_names: nodes, sleep_s: sleep_s)
    }
    cr = PipelineCr.new(name: 'lab-cr', url: CR_URL, user: 'u', password: 'p')
    cr.client_fog = @client_fog
    cr.pipeline_fog = @pipeline_fog
    cr.node_fogs = node_fogs
    cr.fresh_client_error = fresh_client_error
    cr.stubs(:client).returns(@client_fog)
    cr
  end

  def listed_ids(cr, filters = {})
    cr.vms.all(filters).map { |vm| vm.id.to_s.downcase }
  end

  # PLG-44: the stand-alone leg here answers the gate no, which is now
  # re-asked once across a pause; the suite stubs the pause so the doctrine
  # runs without the clock.
  setup do
    ForemanHyperv::Hyperv.any_instance.stubs(:flap_pause)
  end

  # ---- 1: the endpoint-side reads overlap ----

  def test_the_probe_the_node_list_and_the_endpoint_rows_are_read_at_the_same_time
    overlap = Overlap.new
    cr = build_cr(overlap: overlap)

    ids = listed_ids(cr)

    assert_includes ids, NODE2_VM
    assert_operator overlap.max_active, :>=, 3,
                    'probe + node list + endpoint rows must be in flight together; ' \
                    'the sequential ladder measures exactly 1 — that is the cold-hop SUM ' \
                    'the workstation user waits through'
  end

  # ---- 2: the listing consumes what it started ----

  def test_the_node_list_and_endpoint_rows_are_read_once_on_the_pipeline_client
    overlap = Overlap.new
    cr = build_cr(overlap: overlap)

    listed_ids(cr)

    assert_equal 1, @pipeline_fog.nodes_calls, 'the speculative node list is the listing answer'
    assert_equal 1, @pipeline_fog.rows_calls, 'the speculative endpoint rows are the listing rows'
    assert_equal 0, @client_fog.nodes_calls,
                 'the resource client must not re-read what the pipeline already read'
    assert_equal 0, @client_fog.rows_calls, 'likewise the endpoint rows'
  end

  # ---- 3: the gate is the probe; stand-alone is honored, not taxed ----

  def test_the_gate_is_answered_by_the_probe_future_exactly_once
    overlap = Overlap.new
    cr = build_cr(overlap: overlap)

    listed_ids(cr)

    assert_equal 1, @pipeline_fog.probe_calls,
                 'the tri-state consumes the speculative probe — it is never re-asked'
  end

  def test_a_stand_alone_endpoint_still_gets_the_untouched_collection_and_no_warns
    overlap = Overlap.new
    cr = build_cr(overlap: overlap, supports: false, nodes_error: RuntimeError)
    result = nil

    warns = capture_warns { result = cr.vms }

    assert_same @client_fog.servers, result,
                'the stand-alone answer stays the live fog collection, assert_same verbatim'
    assert_equal [], warns,
                 'a discarded speculative failure must not warn on a resource the gate ' \
                 'says has no cluster'
  end

  def test_a_failed_node_list_warns_once_with_the_established_text_when_the_gate_says_cluster
    overlap = Overlap.new
    cr = build_cr(overlap: overlap, nodes_error: RuntimeError)
    ids = nil

    warns = capture_warns { ids = listed_ids(cr) }

    assert_equal [ELENA, PLAIN], ids, 'a node list that cannot answer degrades to the endpoint rows'
    assert_equal 1, warns.count { |m| m.include?('could not be read') && m.include?('lab-cr') },
                 "the deferred warn fires exactly once, on consumption, with the known text; got: #{warns.inspect}"
  end

  # ---- 4: safety valves ----

  def test_non_default_filters_never_ride_a_speculative_read
    overlap = Overlap.new
    cr = build_cr(overlap: overlap)

    ids = listed_ids(cr, host: 'somewhere')

    assert_equal [ELENA, PLAIN, NODE2_VM], ids, 'the union still forms from a filtered call'
    assert_equal 1, @pipeline_fog.rows_calls, 'the speculative read happened...'
    assert_equal 1, @client_fog.rows_calls,
                 '...but the filtered listing re-read through the resource client, fresh'
  end

  def test_a_pipeline_that_cannot_compose_degrades_to_todays_sequential_path
    overlap = Overlap.new
    cr = build_cr(overlap: overlap, fresh_client_error: Foreman::Exception)
    ids = nil

    warns = capture_warns { ids = listed_ids(cr) }

    assert_equal [ELENA, PLAIN, NODE2_VM], ids, "the answer is today's answer, verbatim"
    assert_equal 0, @pipeline_fog.probe_calls + @pipeline_fog.nodes_calls + @pipeline_fog.rows_calls,
                 'with no pipeline to run, the resource client answers every read as today'
    assert_equal 1, @client_fog.probe_calls
    assert_equal 1, @client_fog.nodes_calls
    assert_equal 1, @client_fog.rows_calls
    assert_equal 1, warns.count { |m| m.include?('listing pipeline') && m.include?('could not start') },
                 'the degrade is loud once — the operator can see the overlap was given up'
  end

  def test_a_cluster_node_servers_built_directly_knows_nothing_of_the_pipeline
    overlap = Overlap.new
    cr = build_cr(overlap: overlap)

    ids = ForemanHyperv::ClusterNodeServers.new(cr).all.map { |vm| vm.id.to_s.downcase }

    assert_equal [ELENA, PLAIN, NODE2_VM], ids
    assert_equal 0, @pipeline_fog.probe_calls + @pipeline_fog.nodes_calls + @pipeline_fog.rows_calls,
                 'direct instantiation reads exactly as PLG-33 left it'
    assert_equal 1, @client_fog.nodes_calls
    assert_equal 1, @client_fog.rows_calls
  end

  def test_a_failing_probe_asked_directly_yes_keeps_the_cluster_page
    overlap = Overlap.new
    cr = build_cr(overlap: overlap, probe_error: Timeout::Error)
    # PLG-44: the failed hop is a could-not-answer, not a no. Asked directly
    # ONCE (a yes pays no re-ask), the endpoint stays a cluster and the page
    # keeps the listing it should always have had — the fold this replaces
    # cached an empty one for up to three hours (review F12).
    @client_fog.expects(:supports_clusters?).once.returns(true)
    ids = nil

    warns = capture_warns { ids = listed_ids(cr) }

    assert_includes ids, NODE2_VM, 'a probe that cannot answer is asked of the endpoint, not answered false'
    assert_equal 1, warns.count { |m| m.include?('pipelined cluster probe for lab-cr failed') },
                 'the failed hop is named once with its own words'
    assert_equal 0, warns.count { |m| m.include?('cluster support for lab-cr could not be read') },
                 'an answered yes is not a fold'
  end

  def test_a_failing_probe_re_asked_no_twice_answers_standalone
    overlap = Overlap.new
    cr = build_cr(overlap: overlap, probe_error: Timeout::Error)
    # The re-ask is the doctrine: ONE more ask, and two consistent noes are
    # the verdict — the stand-alone collection exactly as before PLG-44.
    @client_fog.expects(:supports_clusters?).twice.returns(false)
    result = nil

    warns = capture_warns { result = cr.vms }

    assert_same @client_fog.servers, result,
                'asked directly and re-asked, two noes are the stand-alone page, unchanged'
    assert_equal 1, warns.count { |m| m.include?('pipelined cluster probe for lab-cr failed') },
                 'the failed hop is named even when the re-ask resolves it'
  end

  def test_a_failing_probe_asked_directly_and_raising_folds_to_standalone_as_today
    overlap = Overlap.new
    # Both the hop and the thread's own first ask raise (build_cr gives both
    # fogs the probe error), so there is no re-ask at all: fog outside its
    # swallow-everything contract keeps the established fold and the
    # established words.
    cr = build_cr(overlap: overlap, probe_error: Timeout::Error)
    result = nil

    warns = capture_warns { result = cr.vms }

    assert_same @client_fog.servers, result,
                'an ask that RAISES is fog outside the contract — the established fold'
    assert_equal 1, warns.count { |m| m.include?('pipelined cluster probe for lab-cr failed') },
                 'the failed hop is named with its own words'
    assert_equal 1, warns.count { |m| m.include?('cluster support for lab-cr could not be read') },
                 'the established words still close the raise leg'
  end

  def test_a_failing_probe_re_asked_no_then_raising_folds_to_standalone
    overlap = Overlap.new
    # The leg the gate's comment documents and the legs above left unrun:
    # the hop raises, the direct ask answers NO, and the RE-ASK — the one
    # the pause comes before — is what raises. It rides the same outer
    # rescue: the established fold, the established words, on top of the
    # named hop.
    cr = build_cr(overlap: overlap, probe_error: Timeout::Error)
    # twice: the direct ask (NO) and the re-ask (the raise) are the two
    # invocations this leg drives; mocha's default is exactly one.
    @client_fog.expects(:supports_clusters?).twice.returns(false).raises(Timeout::Error)
    result = nil

    warns = capture_warns { result = cr.vms }

    assert_same @client_fog.servers, result,
                'a re-ask that RAISES folds exactly like a first ask that raises'
    assert_equal 1, warns.count { |m| m.include?('pipelined cluster probe for lab-cr failed') },
                 'the failed hop is still named with its own words'
    assert_equal 1, warns.count { |m| m.include?('cluster support for lab-cr could not be read') },
                 'the established words close the re-ask leg too'
  end

  # ---- 5: the unbounded pop has a bounded reason (review observation 3) ----

  # A fog client for the composition pin. It answers the ONE call
  # fresh_endpoint_client's naming step makes (note_endpoint_self_names reads
  # local_host_names when the client answers it) and nothing else — the hops
  # themselves run into NoMethodError on this double, which is exactly right:
  # this test is about the WIRE each hop client was composed with, and the
  # futures answer (complete or fail_with) either way, so no consumer can
  # block while mocha verifies the compositions.
  class PipelineHopClient
    def local_host_names
      []
    end
  end

  # The pop in ListingPipeline::Future#value carries NO timeout of its own —
  # the operator accepted it (review observation 3, 2026-11-25) on the
  # invariant that no hop can run unbounded, because every client the pipeline
  # rides carries the PLG-16 waits. (Queue#pop's own timeout keyword is not on
  # this runtime either — the CT's ruby is 3.0 — so even a defensive pop
  # would be a second guess on top of the waits' one.) The four clients all
  # come through fresh_endpoint_client -> fog_client_options; this pins that
  # the wire the pipeline speculates on is the SAME waited wire the sequential
  # page dials, so the pop-site comment can keep its promise and a factory
  # that ever drops a wait fails HERE, not as a hung page thread later.
  def test_every_pipeline_hop_client_carries_the_winrm_waits
    cr = ForemanHyperv::Hyperv.new(name: 'lab-cr', url: CR_URL, user: 'u', password: 'p')
    composed = []
    Fog::Compute.expects(:new).times(4).with do |options|
      composed << options
      true
    end.returns(PipelineHopClient.new)

    pipeline = ForemanHyperv::ListingPipeline.start(cr)
    assert_not_nil pipeline, 'the pin needs the pipeline to exist at all'

    assert_equal 4, composed.size,
                 'the pipeline composes FOUR clients at start: probe, node list, endpoint rows, ' \
                 'and the one held for the role lane the probe thread may start'
    composed.each_with_index do |options, hop|
      assert_equal ForemanHyperv::Hyperv::WINRM_OPERATION_TIMEOUT, options[:hyperv_operation_timeout],
                   "pipeline hop #{hop + 1} was composed WITHOUT the PLG-16 operation wait: the " \
                   'unbounded Future#value pop is only safe while every hop is bounded by the waits'
      assert_equal ForemanHyperv::Hyperv::WINRM_RECEIVE_TIMEOUT, options[:hyperv_receive_timeout],
                   "pipeline hop #{hop + 1} was composed WITHOUT the PLG-16 receive wait: the " \
                   'unbounded Future#value pop is only safe while every hop is bounded by the waits'
    end
  end
end
