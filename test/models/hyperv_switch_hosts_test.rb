# frozen_string_literal: true

require 'test_helper'

# PLG-59: which switches a NODE answers is a per-node fact, said early, and
# never by silence.
#
# The three paths that answer "what switches are there" answered three
# different questions (measured baseline, sandbox pass 159): the NIC partial's
# dropdown rides switches(nil) — the ENDPOINT node's list with that node's
# GUIDs; available_networks answers the UNION of the cluster's node names and
# threw its per-node membership away after computing it (only a
# Rails.logger.warn saw it); and fog's Get-VMSwitch -Name on the owner node
# raised "No Ethernet switch could be found matching the specified criteria"
# — naming neither switch nor node — only AFTER the machine existed (fog
# evidence E12b, measured on builds 28 and 33.3). The operator's chosen fix
# (C+A-lite+B) keeps every answer where it belongs and adds what was missing:
#
#   * the fan-out now tells silence from emptiness — a node whose read raised
#     holds NIL in the answers, not the [] that used to pose as "this node
#     has no switches", which let one down node shrink available_networks'
#     shared set and log every switch as missing there;
#   * switch_hosts_map keeps the membership the union already computed, and
#     the plugin's first API route serves it (the endpoint read comes with it
#     as {id, name} pairs, because the dropdown carries GUIDs and only NAMES
#     survive to fog — PLG-26);
#   * validate_nic_switches_on_node! refuses, before any machine exists, an
#     attach to a switch the named owner node's COMPLETED read proves absent,
#     naming switch, node, and what the node does answer. Every silence —
#     no named node, a nil map entry, an unreadable endpoint list, a GUID the
#     endpoint does not hold — passes the create through with fog keeping the
#     last word: fail-open is one rule everywhere, and nil is never absence.
#
# What this suite pins, in order: the three-state answers of the read and of
# both new model methods; the shared-set and warning fixes for a silent node
# (the old bug stated as the negative assertion); every arm of the gate's
# pass/block matrix; the case-insensitive matching the real host names need;
# and that validate_placement! actually runs the gate — before its volumes
# early-return, so a cluster create with no disks still hears it.
class HypervSwitchHostsTest < ActiveSupport::TestCase
  HOST = 'hv-ep01'
  CR_URL = "http://#{HOST}:5985/wsman".freeze
  CLUSTER = 'lab-cluster'
  GUID_LAN = 'lan11111-1111-1111-1111-111111111111'
  GUID_1 = 'srv11111-1111-1111-1111-111111111111'
  GUID_2 = 'srv22222-2222-2222-2222-222222222222'
  GUID_3 = 'srv33333-3333-3333-3333-333333333333'

  # Fog switch-model stand-in: switches(host) maps #attributes on these
  # inside its cache block, and the endpoint loader below turns the hashes
  # into the name/id pair every consumer actually reads. (Same shapes the
  # PLG-55 suite proves out against the real read path.)
  SwitchModel = Struct.new(:attributes)
  ReadModel = Struct.new(:name, :id)
  NodeDouble = Struct.new(:name)
  ClusterDouble = Struct.new(:name, :nodes)

  class Switches
    def initialize(models, raise_error: nil)
      @models = models
      @raise_error = raise_error
    end

    def all(_filters = {})
      raise @raise_error if @raise_error

      @models
    end
  end

  # A node's host as cluster_backed_hosts hands it over: composed onto its
  # OWN fog client (service), so own_client_host passes it through unchanged.
  class NodeHost
    attr_reader :name
    attr_accessor :service, :switches

    def initialize(name:)
      @name = name
    end

    # available_hypervisors' cache block maps #attributes over the listing.
    def attributes
      { 'name' => name }
    end
  end

  class NodeFog
    attr_accessor :host

    def initialize(host = nil)
      @host = host
    end

    # hosts.first — the one read cluster_backed_hosts makes of a node client.
    def hosts
      self
    end

    def first
      @host
    end
  end

  # The resource's own client as far as the reads below see it. #switches
  # plays fog's collection: #load receives the attribute hashes the cache
  # block produced and hands back the models available_networks and the
  # helpers consume. #hosts answers the endpoint host (switches(nil) reads
  # hosts.first) and #new(name:) the name-only hosts fog-core injects a
  # service onto — the shape own_client_host swaps through.
  class MainFog
    attr_reader :endpoint_switches

    def initialize(endpoint_models:, endpoint_raise: nil)
      @endpoint_switches = Switches.new(endpoint_models, raise_error: endpoint_raise)
    end

    def switches
      Loader.new
    end

    def hosts
      HostCollection.new(self)
    end

    class Loader
      def load(models)
        models.map { |model| ReadModel.new(model['name'], model['id']) }
      end
    end

    class HostCollection
      def initialize(owner)
        @owner = owner
      end

      # switches(nil) reads hosts.first — the alias available_hypervisors —
      # which lists through #all inside the cache block and rebuilds models
      # through #load, so the endpoint's hosts double plays both arms.
      def all(_filters = {})
        [host_for(HOST.upcase)]
      end

      def load(attribute_hashes)
        attribute_hashes.map { |attrs| host_for(attrs['name']) }
      end

      def first
        host_for(HOST.upcase)
      end

      def new(name:)
        host_for(name)
      end

      private

      def host_for(name)
        NodeHost.new(name: name).tap do |host|
          host.service = @owner
          host.switches = @owner.endpoint_switches
        end
      end
    end
  end

  # Same staged-fog subclass the PLG-55 suite uses: cluster_backed_hosts'
  # per-node ladder resolves to the fogs named here, nothing else faked.
  class CrWithNodeFogs < ForemanHyperv::Hyperv
    attr_accessor :node_fogs

    def client_for_node(node_name)
      node_fogs.fetch(node_name.to_s.strip.downcase) do
        raise "no fog staged for node #{node_name}"
      end
    end
  end

  def switch_model(name, id)
    SwitchModel.new({ 'name' => name, 'id' => id })
  end

  # The endpoint's list — the exact pairs hyperv_networks builds the
  # dropdown from. GUIDs per name here; the nodes answer the SAME names with
  # their OWN GUIDs (PLG-26), which is why the gate maps GUID->name through
  # this listing and matches the nodes by name.
  def endpoint_models
    [switch_model('LAN', GUID_LAN), switch_model('SRV-1', GUID_1),
     switch_model('SRV-2', GUID_2), switch_model('SRV-3', GUID_3)]
  end

  def build_cr(node_raise: nil, endpoint_raise: nil, cluster: true)
    answers = {
      'HV-NODE1' => [switch_model('LAN', 'n1-lan'), switch_model('SRV-1', 'n1-srv')],
      'HV-NODE2' => [switch_model('LAN', 'n2-lan'), switch_model('SRV-2', 'n2-srv')],
      'HV-NODE3' => [switch_model('LAN', 'n3-lan'), switch_model('SRV-3', 'n3-srv')]
    }
    fogs = {}
    answers.each do |name, models|
      fog = NodeFog.new
      fog.host = NodeHost.new(name: name).tap do |host|
        host.service = fog
        host.switches = Switches.new(models, raise_error: name == node_raise)
      end
      fogs[name.downcase] = fog
    end

    cr = CrWithNodeFogs.new(name: "sw-hosts-#{object_id}", url: CR_URL, user: 'u', password: 'p')
    cr.stubs(:client).returns(MainFog.new(endpoint_models: endpoint_models, endpoint_raise: endpoint_raise))
    cr.stubs(:cluster_endpoint?).returns(false)
    cr.node_fogs = fogs
    cr.stubs(:cluster_named).returns(cluster ? ClusterDouble.new(CLUSTER, answers.keys.map { |n| NodeDouble.new(n) }) : nil)
    cr
  end

  # The PLG-55 suite's logger seam, same lesson: mocha block-capture is not
  # reliable on every seed, so warnings land in a plain recording object.
  class RecordingLogger
    attr_reader :warnings

    def initialize
      @warnings = []
    end

    def warn(msg = nil)
      @warnings << msg.to_s
    end

    def info(msg = nil)
      @warnings << msg.to_s
    end

    def debug(msg = nil)
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

  def nic_attr(switch_guid:, computer: 'HV-NODE1', cluster: CLUSTER, nested: false)
    iface = { switch_id: switch_guid }
    iface = { compute_attributes: iface } if nested
    { computer_name: computer, cluster_name: cluster, interfaces_attributes: { '0' => iface } }
  end

  # --- the three-state read -------------------------------------------------

  def test_a_node_whose_read_raises_holds_nil_in_the_map_never_an_empty_list
    cr = build_cr(node_raise: 'HV-NODE2')

    map = cr.switch_hosts_map(CLUSTER)

    assert_equal %w[LAN SRV-1], map['HV-NODE1']
    assert_nil map['HV-NODE2'], 'a silent node must hold nil, never the [] that poses as "no switches"'
    assert_equal %w[LAN SRV-3], map['HV-NODE3']
  end

  def test_a_complete_read_answers_names_even_when_the_node_has_no_switches
    # Only reachable by making one node answer [] legitimately: stage an
    # empty model list for node 3.
    cr = build_cr
    cr.node_fogs['hv-node3'].host.switches = Switches.new([])

    map = cr.switch_hosts_map(CLUSTER)

    assert_equal [], map['HV-NODE3'], 'a completed empty read is emptiness, and says so'
  end

  # --- the union fixes ------------------------------------------------------

  def test_a_silent_node_no_longer_shrinks_the_offered_union
    cr = build_cr(node_raise: 'HV-NODE2')
    silence_warnings

    names = cr.available_networks(CLUSTER).map(&:name)

    assert_includes names, 'SRV-1'
    assert_includes names, 'SRV-3'
    assert_not_includes names, 'SRV-2', 'the silent node contributes no names, as it always did'
  end

  def test_a_silent_node_is_no_longer_logged_as_missing_everything
    # The old honesty bug stated as its negative: folding silence into []
    # made the down node share every missing-where warning, rewriting the
    # cluster's facts for the outage's duration.
    cr = build_cr(node_raise: 'HV-NODE2')
    warnings = silence_warnings

    cr.available_networks(CLUSTER)

    srv1 = warnings.grep(/SRV-1 is missing from/).first
    assert srv1, 'SRV-1 is still truthfully missing from the nodes that answered without it'
    assert_includes srv1, 'HV-NODE3'
    assert_not_includes srv1, 'HV-NODE2', 'a node that never answered cannot be proven to lack it'

    srv3 = warnings.grep(/SRV-3 is missing from/).first
    assert srv3
    assert_includes srv3, 'HV-NODE1'
    assert_not_includes srv3, 'HV-NODE2'
  end

  # --- the new model answers --------------------------------------------------

  def test_switch_hosts_map_of_a_standalone_resource_answers_the_endpoint_alone
    cr = build_cr(cluster: false)

    map = cr.switch_hosts_map(nil)

    assert_equal [HOST.upcase], map.keys
    assert_equal %w[LAN SRV-1 SRV-2 SRV-3], map[HOST.upcase]
  end

  def test_switch_hosts_map_holds_nil_for_a_standalone_endpoint_that_did_not_answer
    cr = build_cr(cluster: false, endpoint_raise: SocketError)
    silence_warnings

    map = cr.switch_hosts_map(nil)

    assert_equal [HOST.upcase], map.keys
    assert_nil map[HOST.upcase]
  end

  def test_endpoint_switch_list_pairs_guids_with_names_and_answers_nil_on_silence
    cr = build_cr
    assert_equal [{ id: GUID_LAN, name: 'LAN' }, { id: GUID_1, name: 'SRV-1' },
                  { id: GUID_2, name: 'SRV-2' }, { id: GUID_3, name: 'SRV-3' }],
                 cr.endpoint_switch_list

    silent = build_cr(endpoint_raise: SocketError)
    silence_warnings
    assert_nil silent.endpoint_switch_list
  end

  # --- the create gate --------------------------------------------------------

  def test_the_gate_refuses_a_switch_the_named_nodes_completed_read_lacks
    cr = build_cr
    silence_warnings

    error = assert_raises(ForemanHyperv::OperationRefused) do
      cr.send(:validate_nic_switches_on_node!, nic_attr(switch_guid: GUID_3, computer: 'HV-NODE1'))
    end

    assert_includes error.message, 'SRV-3'
    assert_includes error.message, 'HV-NODE1'
    assert_includes error.message, 'LAN, SRV-1', 'the refusal names what the node DOES answer'
  end

  def test_the_gate_passes_a_switch_the_node_answers
    cr = build_cr
    silence_warnings

    cr.send(:validate_nic_switches_on_node!, nic_attr(switch_guid: GUID_2, computer: 'HV-NODE2'))
  end

  def test_the_gate_passes_every_silence_and_lets_fog_keep_the_last_word
    # Node silent: the map holds nil and absence cannot be proven.
    silent_node = build_cr(node_raise: 'HV-NODE2')
    silence_warnings
    silent_node.send(:validate_nic_switches_on_node!, nic_attr(switch_guid: GUID_3, computer: 'HV-NODE2'))

    # Endpoint list silent: GUIDs cannot be named at all.
    silent_endpoint = build_cr(endpoint_raise: SocketError)
    silence_warnings
    silent_endpoint.send(:validate_nic_switches_on_node!, nic_attr(switch_guid: GUID_3, computer: 'HV-NODE1'))

    # No named owner node (a plain API create onto the cluster).
    build_cr.send(:validate_nic_switches_on_node!, nic_attr(switch_guid: GUID_3, computer: nil))

    # No cluster (a stand-alone create: the dropdown IS the endpoint's list).
    build_cr.send(:validate_nic_switches_on_node!, nic_attr(switch_guid: GUID_3, cluster: nil))

    # A GUID the endpoint list does not hold: it escapes name evaluation and
    # the loud fog error stays its honest answer (PLG-26 doctrine).
    build_cr.send(:validate_nic_switches_on_node!, nic_attr(switch_guid: 'no-such-guid', computer: 'HV-NODE1'))

    # No switch asked (a blank selection).
    build_cr.send(:validate_nic_switches_on_node!, nic_attr(switch_guid: nil, computer: 'HV-NODE1'))
  end

  def test_the_gate_reads_the_compute_attributes_shape_too
    # The form rides interfaces_attributes[*][:compute_attributes]; the raw
    # API may ride the interface itself. validate_interfaces accepts both, so
    # the gate must see both.
    cr = build_cr
    silence_warnings

    assert_raises(ForemanHyperv::OperationRefused) do
      cr.send(:validate_nic_switches_on_node!, nic_attr(switch_guid: GUID_3, computer: 'HV-NODE1', nested: true))
    end
  end

  def test_the_gate_matches_the_node_name_case_insensitively
    # Placement matching is case-insensitive (the membership check compares
    # downcased names); a gate that only matched exact case would silently
    # skip creates the membership rules let through.
    cr = build_cr
    silence_warnings

    assert_raises(ForemanHyperv::OperationRefused) do
      cr.send(:validate_nic_switches_on_node!, nic_attr(switch_guid: GUID_3, computer: 'hv-node1'))
    end
  end

  def test_validate_placement_runs_the_gate_before_its_volumes_early_return
    # The wiring pin: with no volumes asked, validate_placement! used to
    # return after the membership checks — a create with zero disks still
    # hears the switch refusal, so the gate runs before that return.
    cr = build_cr
    cr.stubs(:placement_target_names).returns(['hv-ep01', 'hv-node1', 'hv-node2', 'hv-node3'])
    silence_warnings

    error = assert_raises(ForemanHyperv::OperationRefused) do
      cr.send(:validate_placement!, nic_attr(switch_guid: GUID_3, computer: 'HV-NODE1'))
    end
    assert_includes error.message, 'SRV-3'

    # And the same create with a deliverable switch passes placement untouched
    # (no volumes, so the early return is the end of the road).
    cr.send(:validate_placement!, nic_attr(switch_guid: GUID_1, computer: 'HV-NODE1'))
  end
end
