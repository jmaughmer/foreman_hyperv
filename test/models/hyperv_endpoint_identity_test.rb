# frozen_string_literal: true

require 'test_helper'

# PLG-43 (review F11): one canonical rule answers "is this cluster node the
# machine behind this compute-resource URL?" — the endpoint's SELF-REPORTED
# names (fog answers them from FOG-27) first, the URL host and its first
# label always as the fallback. Before this PR the bootdisk ride and the
# owner-node read compared the URL host's first label (so an IP endpoint
# answers '10' for any node) and the cluster listing compared the URL host
# exactly, without even that rule — both missed the endpoint's own node on
# IP and CNAME URLs, live in production at the time this was written.
#
# The names are READ, never dialed for: they are noted on the resource when
# an ENDPOINT client is composed (the memo and the pipeline's fresh copies;
# never a node client — a node client's report names that node), so every
# consumer, which has necessarily already dialed the endpoint to be asking
# at all, sees them, and a listing backed by the pipeline's copies is not
# made to dial a fifth serial client just to learn an identity.
class HypervEndpointIdentityTest < ActiveSupport::TestCase
  IP_URL = 'http://10.0.0.5:5985/wsman'.freeze
  NAMES = ['hv-node1', 'hv-node1.lab.example'].freeze

  # A fog from FOG-27: it carries what the endpoint reported for itself.
  class ReportingFog
    attr_reader :local_host_names

    def initialize(names)
      @local_host_names = names.freeze
    end
  end

  # A fog before FOG-27: the self-report vocabulary does not exist on it.
  class SilentFog; end

  def build_cr(url: IP_URL)
    ForemanHyperv::Hyperv.new(name: 'lab-cr', url: url, user: 'u', password: 'p')
  end

  # mocha 2.x ignores blocks given to stubs, so Fog::Compute.new is replaced
  # by a singleton recorder answering from a queue and restored in teardown.
  # The recorder's method body runs with SELF on Fog::Compute, so everything
  # it touches is a closure local, never an @ivar of this test.
  def stage_compositions(*fogs)
    composed = []
    @composed = composed
    queue = fogs.dup
    @original_new = Fog::Compute.method(:new)
    Fog::Compute.define_singleton_method(:new) do |opts = {}|
      fog = queue.shift or raise "no fog staged for #{opts[:hyperv_endpoint]}"
      composed << fog
      fog
    end
  end

  def teardown
    Fog::Compute.singleton_class.send(:remove_method, :new) if @original_new
    @original_new = nil
  end

  def serves?(cr, node)
    cr.send(:endpoint_serves_node?, node)
  end

  # --- the canonical rule ---------------------------------------------------

  def test_the_names_the_endpoint_reported_match_where_the_ip_url_misses
    cr = build_cr
    stage_compositions(ReportingFog.new(NAMES))
    cr.send(:client)

    assert serves?(cr, 'HV-NODE1'), 'the NETBIOS name the machine itself answered must match over an IP URL'
    assert serves?(cr, 'hv-node1.lab.example'), 'the machine’s own FQDN is its name too'
  end

  def test_the_url_rule_still_answers_beside_the_reported_names
    cr = build_cr
    stage_compositions(ReportingFog.new(NAMES))
    cr.send(:client)

    assert serves?(cr, '10.0.0.5'), 'the URL host itself keeps matching exactly as before'
    assert serves?(cr, '  hv-node1  '), 'surrounding whitespace is stripped before matching'
    refute serves?(cr, 'HV-NODE2'), 'a node nobody reported is not the endpoint'
    refute serves?(cr, ''), 'the blank name answers false'
    refute serves?(cr, nil), 'nil answers false'
  end

  def test_an_old_fog_keeps_exactly_the_url_rule
    cr = build_cr
    stage_compositions(SilentFog.new)
    cr.send(:client)

    assert_nil cr.instance_variable_get(:@endpoint_self_names), 'a fog with no self-report vocabulary leaves no note'
    refute serves?(cr, 'HV-NODE1'), 'with old fog the IP miss is kept — the capability gate degrades, it does not guess'
    assert serves?(cr, '10'), 'the first-label rule survives exactly as it was'
    assert serves?(cr, '10.0.0.5'), 'the whole URL host matches, as it did'
  end

  def test_a_report_of_no_names_leaves_the_rule_on_the_url
    # Discovery failed (or an old fog answering the method with an empty
    # list): the note is not written and the answer is the URL rule alone.
    cr = build_cr
    stage_compositions(ReportingFog.new([]))
    cr.send(:client)

    assert_nil cr.instance_variable_get(:@endpoint_self_names), 'the empty report notes nothing'
    refute serves?(cr, 'HV-NODE1')
  end

  def test_the_rule_never_dials_to_answer
    # The listing may sit behind the pipeline's fresh copies; answering this
    # question must never become a fifth serial dial (see the note method).
    compositions = 0
    @original_new = Fog::Compute.method(:new)
    Fog::Compute.define_singleton_method(:new) do |_opts = {}|
      compositions += 1
      ReportingFog.new(NAMES)
    end
    cr = build_cr

    refute serves?(cr, 'HV-NODE1'), 'with no endpoint dialed yet the rule answers from the URL alone'
    assert_equal 0, compositions, 'the rule composed no client to answer'
  end

  def test_the_pipeline_fresh_copy_records_the_names_it_composes
    # PLG-33b: with the pipeline the resource's own client may never be
    # dialed, yet the listing still must recognize the endpoint's own node.
    cr = build_cr
    stage_compositions(ReportingFog.new(NAMES))

    cr.send(:fresh_endpoint_client)

    assert serves?(cr, 'HV-NODE1'), 'the identity a fresh endpoint copy learned belongs to the endpoint'
  end

  def test_a_node_client_composition_is_not_an_endpoint_report
    cr = build_cr
    endpoint_fog = ReportingFog.new(NAMES)
    node_fog = ReportingFog.new(['hv-node2'])
    stage_compositions(endpoint_fog, node_fog)
    cr.send(:client)
    cr.stubs(:node_endpoint).returns('http://10.0.0.9:5985/wsman')

    cr.send(:client_for_node, 'HV-NODE2')

    assert_equal NAMES, cr.instance_variable_get(:@endpoint_self_names),
                 'a node client’s self-report names that node, never the endpoint'
    refute serves?(cr, 'HV-NODE2'), 'the endpoint does not serve a node only a NODE client reported'
  end

  # --- the listing consumer (the double-dial F11 names) ---------------------

  VmDouble = Struct.new(:id, :name, keyword_init: true)
  NodeDouble = Struct.new(:name)

  class ServersCounter
    attr_reader :calls

    def initialize(machines)
      @machines = machines
      @calls = 0
    end

    def all(filters = {})
      @calls += 1
      @machines
    end
  end

  class EndpointCounterFog
    attr_reader :servers_collection, :local_host_names

    def initialize(servers, node_names, names: nil)
      @servers_collection = servers
      @nodes = node_names.map { |n| NodeDouble.new(n) }
      @local_host_names = names
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

  class ListingCr < ForemanHyperv::Hyperv
    attr_accessor :node_fogs

    def client_for_node(node_name)
      node_fogs.fetch(node_name.to_s.strip.downcase) do
        raise "no fog staged for node #{node_name}"
      end
    end
  end

  ENDPOINT_VM = '11111111-1111-1111-1111-111111111111'
  NODE2_VM = '22222222-2222-2222-2222-222222222222'

  # IP URL; the endpoint fog answers names only when the caller asks for a
  # FOG-27 endpoint. Each node's ladder entry is a fog whose servers counter
  # records every read.
  def build_listing_cr(endpoint_names:)
    endpoint_servers = ServersCounter.new([VmDouble.new(id: ENDPOINT_VM, name: 'a.example')])
    node1 = EndpointCounterFog.new(ServersCounter.new([VmDouble.new(id: ENDPOINT_VM, name: 'a.example')]), [], names: nil)
    node2 = EndpointCounterFog.new(ServersCounter.new([VmDouble.new(id: NODE2_VM, name: 'b.example')]), [], names: nil)
    fog = EndpointCounterFog.new(endpoint_servers, ['HV-NODE1', 'HV-NODE2'], names: endpoint_names)
    stage_compositions(fog)
    cr = ListingCr.new(name: 'lab-cr', url: IP_URL, user: 'u', password: 'p')
    cr.node_fogs = { 'hv-node1' => node1, 'hv-node2' => node2 }
    [cr, endpoint_servers, node1, node2]
  end

  def listing_ids(rows)
    rows.map(&:id).sort
  end

  def test_the_listing_reads_the_endpoints_own_node_once_when_fog_reports_names
    cr, endpoint_servers, node1, node2 = build_listing_cr(endpoint_names: NAMES)

    rows = ForemanHyperv::ClusterNodeServers.new(cr).all({})

    assert_equal 1, endpoint_servers.calls, 'the endpoint is read exactly once'
    assert_equal 0, node1.servers_collection.calls, 'the endpoint’s own node is not dialed a second time for the same answer'
    assert_equal 1, node2.servers_collection.calls, 'the other node is still read'
    assert_equal [ENDPOINT_VM, NODE2_VM], listing_ids(rows), 'the union keeps each machine once'
  end

  def test_the_listing_on_an_old_fog_degrades_to_the_url_rule
    # The capability gate's other half: with old fog the IP miss — and the
    # second read of the same machine — is KEPT, exactly as before PLG-43.
    cr, endpoint_servers, node1, node2 = build_listing_cr(endpoint_names: nil)

    rows = ForemanHyperv::ClusterNodeServers.new(cr).all({})

    assert_equal 1, endpoint_servers.calls
    assert_equal 1, node1.servers_collection.calls, 'old fog keeps the pre-PLG-43 second read'
    assert_equal 1, node2.servers_collection.calls
    assert_equal [ENDPOINT_VM, NODE2_VM], listing_ids(rows)
  end
end
