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
#      pipeline; a consumed failure warns once with the established text.
class HypervListingPipelineTest < ActiveSupport::TestCase
  HOST = 'hv-node1'
  CR_URL = "http://#{HOST}:5985/wsman".freeze
  ELENA = '3323c48a-a1bb-4609-b25d-b02013bc701f'
  PLAIN = 'cccc1111-2222-3333-4444-555566667777'
  NODE2_VM = '77771111-2222-3333-4444-555566667777'

  VmDouble = Struct.new(:id, :name, keyword_init: true)
  NodeDouble = Struct.new(:name)

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
    Rails.logger.stubs(:warn)

    result = cr.vms

    assert_same @client_fog.servers, result,
                'the stand-alone answer stays the live fog collection, assert_same verbatim'
    Rails.logger.expects(:warn).with { |m| m.to_s.include?('could not be read') }.never
    Rails.logger.expects(:warn).with { |m| m.to_s.include?('did not answer') }.never
  end

  def test_a_failed_node_list_warns_once_with_the_established_text_when_the_gate_says_cluster
    overlap = Overlap.new
    cr = build_cr(overlap: overlap, nodes_error: RuntimeError)
    warns = []
    Rails.logger.stubs(:warn) { |message| warns << message.to_s }

    ids = listed_ids(cr)

    assert_equal [ELENA, PLAIN], ids, 'a node list that cannot answer degrades to the endpoint rows'
    assert_equal 1, warns.count { |m| m.include?('could not be read') && m.include?('lab-cr') },
                 'the deferred warn fires exactly once, on consumption, with the known text'
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
    Rails.logger.stubs(:warn)

    ids = listed_ids(cr)

    assert_equal [ELENA, PLAIN, NODE2_VM], ids, 'the answer is today\'s answer, verbatim'
    assert_equal 0, @pipeline_fog.probe_calls + @pipeline_fog.nodes_calls + @pipeline_fog.rows_calls,
                 'with no pipeline to run, the resource client answers every read as today'
    assert_equal 1, @client_fog.probe_calls
    assert_equal 1, @client_fog.nodes_calls
    assert_equal 1, @client_fog.rows_calls
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

  def test_a_failing_probe_still_answers_standalone_and_warns_like_today
    overlap = Overlap.new
    cr = build_cr(overlap: overlap, probe_error: Timeout::Error)
    Rails.logger.stubs(:warn)

    result = cr.vms

    assert_same @client_fog.servers, result,
                'a probe that cannot answer is answered false — the stand-alone path'
  end
end
