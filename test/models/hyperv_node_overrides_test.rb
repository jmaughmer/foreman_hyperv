# frozen_string_literal: true

require 'test_helper'
require 'active_support/test_case'

# PLG-5a: the operator node→endpoint override. The override attribute is the
# ONLY source of FQDN/IP identity for a node the compute resource's own client
# does not serve (N5 — cluster reads return UNQUALIFIED names; node strings
# must never reach fog's completion sink). Shape: one `NODE = host[:port]`
# line per node; the value is a bare host or host:port — a scheme, a path,
# whitespace or a backtick is REFUSED at save, never sanitized. The per-node
# client is a SEPARATE Fog::Compute built from the COMPOSED endpoint: the CR
# supplies scheme, TLS and port, the override supplies the identity spliced in
# (N4); hyperv_host itself is never passed. R17: the check runs on the
# COMPOSED endpoint — a hardened (https) CR would compose an unvalidated
# transport, and PLG-5a refused every composition that was not the measured
# http+negotiate pattern until PLG-5b validated the matrix; PLG-5b has
# landed, so https now composes only for a named identity with an explicit
# CA trust path (see hyperv_node_discovery_test.rb), and unoverridden nodes
# go to the cluster's own address read. The read path
# this ships is vm_from_cluster_owner: with an override the owning node is
# addressed by the OVERRIDE HOST (fog re-splicing the unqualified name fails
# outright on the Foreman host, §45.3, or completes against the prefix cache
# and fakes a pass, R22); the endpoint's OWN node is addressed by the
# endpoint host — the identity that already resolves; any other node without
# an override fails closed, no fog call carrying its name at all.
ENV['RAILS_ENV'] = 'test'
unless defined?(FOREMAN_BOOT)
  FOREMAN_BOOT = [
    File.expand_path('../../config/environment.rb', __dir__),
    File.expand_path('../../../config/environment.rb', __dir__),
    File.expand_path('../../../../config/environment.rb', __dir__)
  ].find { |path| File.exist?(path) }
end
require FOREMAN_BOOT if FOREMAN_BOOT && !(defined?(Rails) && Rails.application)

require 'fog/hyperv' if FOREMAN_BOOT || (defined?(Rails) && Rails.application)

class HypervNodeOverridesTest < ActiveSupport::TestCase
  alias assert_not refute

  CR_HOST = 'hv-node1.lab.maughmer.net'
  CR_URL = "http://#{CR_HOST}:5985/wsman".freeze
  VM_GUID = '94f8b7b0-2a1d-4a1d-9f2e-6c0f1d2e3a4b'
  OWNER_NODE = 'HV-NODE2'
  OVERRIDE_HOST = '192.168.1.67'

  # The role fog answers for a clustered machine, reduced to the field this
  # path reads.
  RoleDouble = Struct.new(:owner_node)

  class RolesDouble
    attr_reader :all_calls

    def initialize(roles)
      @roles = roles
      @all_calls = []
    end

    def all(vm_id: nil)
      @all_calls << vm_id
      @roles
    end
  end

  # The CR's own fog client. Anything the suite has not given an explicit
  # method for is recorded, so "no fog call carried the node" is a real claim
  # over every entry point, not a guess about which method matters.
  class CrFog
    attr_reader :fog_calls, :servers_get_calls

    def initialize(roles: nil, supports_clusters: true)
      @roles = roles
      @supports_clusters = supports_clusters
      @fog_calls = []
      @servers_get_calls = []
    end

    def supports_clusters?
      @supports_clusters
    end

    def cluster_virtual_machine_roles
      @fog_calls << [:cluster_virtual_machine_roles, []]
      @roles
    end

    def servers
      self
    end

    def get(id, **kwargs)
      @servers_get_calls << [id, kwargs]
      nil
    end

    def method_missing(name, *args)
      @fog_calls << [name, args]
      nil
    end

    def respond_to_missing?(name, include_all = false)
      %i[servers get cluster_virtual_machine_roles supports_clusters?].include?(name) || super
    end
  end

  # A per-node client double: its own servers.get, recorded separately so the
  # suite can tell WHICH instance the read went to.
  class NodeFog
    attr_reader :get_calls

    def initialize(vm = :node_vm)
      @vm = vm
      @get_calls = []
    end

    def servers
      self
    end

    def get(id, **kwargs)
      @get_calls << [id, kwargs]
      @vm
    end
  end

  def setup
    unless FOREMAN_BOOT || (defined?(Rails) && Rails.application)
      skip 'Needs a booted Foreman (rake test:plugins): these cover model-level override semantics.'
    end
    begin
      require 'mocha/minitest'
    rescue LoadError
      skip 'mocha is not available outside the Foreman bundle.'
    end
    skip 'the hyperv_node_overrides column has not been migrated in this test database' unless overrides_column?
  end

  def overrides_column?
    return @overrides_column unless @overrides_column.nil?

    @overrides_column = ComputeResource.column_names.include?('hyperv_node_overrides')
  end

  def build_cr(overrides: nil, url: CR_URL, fog: CrFog.new(roles: nil))
    cr = ForemanHyperv::Hyperv.new(name: 'lab-cr', url: url, user: 'u', password: 'p')
    cr.hyperv_node_overrides = overrides
    cr.stubs(:client).returns(fog)
    [cr, fog]
  end

  # ---- the attribute's shape: parsed, case-insensitive, refused at save ----

  def test_override_lines_parse_case_insensitively_on_node_names
    cr, = build_cr(overrides: "  hv-node2 = #{OVERRIDE_HOST}\nHV-NODE3.lab.maughmer.net = 192.168.1.68:5985\n")
    assert cr.valid?, "clean overrides must validate: #{cr.errors.full_messages}"
    assert_equal OVERRIDE_HOST, cr.send(:node_override, 'HV-NODE2')
    assert_equal '192.168.1.68:5985', cr.send(:node_override, 'hv-node3.lab.maughmer.net')
    assert_nil cr.send(:node_override, 'HV-NODE9')
  end

  def test_blank_overrides_are_valid_and_answer_no_override
    [nil, '', "  \n\n"].each do |value|
      cr, = build_cr(overrides: value)
      assert cr.valid?, "blank overrides must validate (#{value.inspect}): #{cr.errors.full_messages}"
      assert_nil cr.send(:node_override, 'HV-NODE2')
    end
  end

  # R17 strictness at the door: only a bare host or host:port is a value.
  # The refused line's node is named in the error verbatim — the operator is
  # told WHICH line, never silently repaired.
  def test_override_values_beyond_host_or_host_port_are_refused_not_sanitized
    refused = [
      'hv-node2 = https://192.168.1.67',
      'hv-node2 = 192.168.1.67/wsman',
      'hv-node2 = 192.168.1.67:abc',
      'hv-node2 = 192.168.1.67:0',
      'hv-node2 = 192.168.1.67:70000',
      'hv-node2 = two hosts',
      'hv-node2 = ho`st',
      'hv-node2 = 192.168.1.67\\trailing',
      'hv-node2 =',
      'hv-node2',
      '= 192.168.1.67'
    ]
    refused.each do |line|
      cr, = build_cr(overrides: line)
      assert_not cr.valid?, "#{line.inspect} must be refused"
      assert_includes cr.errors.full_messages.join(' '), line.split('=').first.strip,
                      "the refusal must name the offending node (#{line.inspect})"
    end
  end

  # ---- the COMPOSED endpoint: scheme/port from the CR, identity from the override ----

  def test_the_composed_endpoint_splices_the_override_identity_into_the_cr_scheme_and_port
    cr, = build_cr(overrides: "hv-node2 = #{OVERRIDE_HOST}")
    assert_equal "http://#{OVERRIDE_HOST}:5985/wsman", cr.send(:node_endpoint, OWNER_NODE)
  end

  def test_the_override_port_wins_over_the_cr_port
    cr, = build_cr(overrides: "hv-node2 = #{OVERRIDE_HOST}:5986")
    assert_equal "http://#{OVERRIDE_HOST}:5986/wsman", cr.send(:node_endpoint, OWNER_NODE)
  end

  # PLG-5b changed this rung: an unoverridden node is now ASKED OF THE CLUSTER
  # (Get-ClusterNetworkInterface). A client that cannot answer the address read
  # leaves nothing to dial, and the refusal names the node — the fail-closed
  # is unchanged, the silence is not.
  def test_an_unoverridden_node_is_asked_of_the_cluster_and_refused_when_it_cannot_answer
    cr, fog = build_cr(overrides: 'hv-node9 = 10.0.0.9')
    error = assert_raises(ForemanHyperv::OperationRefused) { cr.send(:node_endpoint, OWNER_NODE) }
    assert_includes error.message.downcase, 'hv-node2', 'the refusal must name the node it could not address'
    assert_empty fog.fog_calls, 'a client that cannot answer the address read is refused without calling it'
  end

  # R17, post-PLG-5b: the matrix row is measured, so the check names its
  # measured reason instead of a pending PR. An IPv4 identity under https has
  # no hostname for the certificate to verify against (row (w): no verified
  # path to an IP endpoint), so the composition stays refused.
  def test_a_hardened_cr_refuses_an_ip_identity_for_hostname_verification
    cr, fog = build_cr(
      overrides: "hv-node2 = #{OVERRIDE_HOST}",
      url: 'https://hv-node1.lab.maughmer.net:5986/wsman'
    )
    error = assert_raises(ForemanHyperv::OperationRefused) { cr.send(:node_endpoint, OWNER_NODE) }
    assert_includes error.message, OVERRIDE_HOST, 'the refusal must name the endpoint it refused to compose'
    assert_includes error.message.downcase, 'hostname', 'the reason is certificate hostname verification (row (w))'
    assert_empty fog.fog_calls, 'the refusal happens before anything reaches fog'
  end

  # ---- the per-node instance: composed endpoint in, hyperv_host NEVER ----

  def test_the_per_node_client_is_built_from_the_composed_endpoint_and_carries_no_hyperv_host
    cr, = build_cr(overrides: "hv-node2 = #{OVERRIDE_HOST}")
    sentinel = Object.new
    Fog::Compute.expects(:new).once.with do |options|
      options[:provider] == :HyperV &&
        options[:hyperv_endpoint] == "http://#{OVERRIDE_HOST}:5985/wsman" &&
        options[:hyperv_username] == 'u' &&
        options[:hyperv_password] == 'p' &&
        !options.key?(:hyperv_host)
    end.returns(sentinel)
    assert_same sentinel, cr.send(:client_for_node, OWNER_NODE)
  end

  def test_per_node_clients_are_cached_per_node_and_never_touch_the_cr_client
    cr, fog = build_cr(overrides: "hv-node2 = #{OVERRIDE_HOST}\nhv-node3 = 192.168.1.68")
    first = Object.new
    second = Object.new
    # Exact-hash expectations, no block matchers: the complete options hash IS
    # the claim (hyperv_host absent by construction), and mocha's count stays
    # honest — a third Fog::Compute.new anywhere is an unexpected invocation.
    Fog::Compute.expects(:new)
                .with(provider: :HyperV, hyperv_endpoint: "http://#{OVERRIDE_HOST}:5985/wsman",
                      hyperv_username: 'u', hyperv_password: 'p')
                .returns(first)
    Fog::Compute.expects(:new)
                .with(provider: :HyperV, hyperv_endpoint: 'http://192.168.1.68:5985/wsman',
                      hyperv_username: 'u', hyperv_password: 'p')
                .returns(second)
    node2 = cr.send(:client_for_node, OWNER_NODE)
    assert_same first, node2
    assert_same first, cr.send(:client_for_node, 'hv-node2'),
                'same node, same instance — a cache miss would surface as an unexpected third build'
    node3 = cr.send(:client_for_node, 'HV-NODE3')
    assert_same second, node3
    assert_not_same first, second, 'different nodes are different instances'
    assert_equal CR_URL, cr.url, 'the compute resource endpoint itself is untouched'
    assert_empty fog.fog_calls, 'building clients must not make fog calls'
  end

  # ---- vm_from_cluster_owner: the read path the override actually serves ----

  def role_owner(owner)
    RolesDouble.new([RoleDouble.new(owner)])
  end

  def test_a_role_from_an_overridden_node_is_read_on_the_per_node_client_at_the_override_host
    roles = role_owner(OWNER_NODE)
    fog = CrFog.new(roles: roles)
    cr, = build_cr(overrides: "hv-node2 = #{OVERRIDE_HOST}", fog: fog)
    node_fog = NodeFog.new
    cr.stubs(:client_for_node).with(OWNER_NODE).returns(node_fog)

    vm = cr.send(:vm_from_cluster_owner, VM_GUID)

    assert_equal :node_vm, vm
    assert_equal [[VM_GUID, { computer_name: OVERRIDE_HOST }]], node_fog.get_calls,
                 'the read goes to the per-node client, addressed by the OVERRIDE HOST: ' \
                 'fog re-splicing the unqualified name could complete against the prefix cache and fake a pass (R22)'
    assert_empty fog.servers_get_calls, 'the CR client must not be asked for a node it does not serve'
  end

  # PLG-5b: the unoverridden node is discovered — and when the cluster read
  # cannot answer (this double has no run_cmd), the refusal travels up naming
  # the node, still with no fog call carrying its unqualified name.
  def test_a_role_from_an_unoverridden_node_the_cluster_cannot_address_fails_closed_naming_it
    fog = CrFog.new(roles: role_owner(OWNER_NODE))
    cr, = build_cr(overrides: 'hv-node9 = 10.0.0.9', fog: fog)

    error = assert_raises(ForemanHyperv::OperationRefused) { cr.send(:vm_from_cluster_owner, VM_GUID) }
    assert_includes error.message.downcase, 'hv-node2', 'the refusal names the node it could not address'
    assert_empty fog.servers_get_calls,
                 'fail closed means NO fog call carries the node — not a name fog will ' \
                 'prefix-cache into the CR endpoint'
  end

  def test_a_hardened_composition_raises_through_the_cluster_owner_read_rather_than_faking_nil
    fog = CrFog.new(roles: role_owner(OWNER_NODE))
    cr, = build_cr(
      overrides: "hv-node2 = #{OVERRIDE_HOST}",
      url: 'https://hv-node1.lab.maughmer.net:5986/wsman',
      fog: fog
    )
    assert_raises(ForemanHyperv::OperationRefused) { cr.send(:vm_from_cluster_owner, VM_GUID) }
    assert_empty fog.servers_get_calls
  end

  def test_the_endpoint_serving_its_own_node_is_addressed_by_the_endpoint_host
    [['HV-NODE1', 'the NETBIOS short name the role carries'],
     ['HV-NODE1.LAB.MAUGHMER.NET', 'the same node fully qualified']].each do |owner, why|
      fog = CrFog.new(roles: role_owner(owner))
      cr, = build_cr(overrides: nil, fog: fog)

      assert_nil cr.send(:vm_from_cluster_owner, VM_GUID)
      assert_equal [[VM_GUID, { computer_name: CR_HOST }]], fog.servers_get_calls,
                   "the endpoint's own node (#{why}) keeps the CR client, addressed by the " \
                   'ENDPOINT HOST — the unqualified name is what fails to resolve on the Foreman host (§45.3)'
    end
  end

  def test_override_lookup_makes_no_ledger_or_gate_reads
    fog = CrFog.new(roles: nil)
    cr, = build_cr(overrides: "hv-node2 = #{OVERRIDE_HOST}", fog: fog)
    assert_nil cr.send(:node_override, 'HV-NODE9')
    assert_empty fog.fog_calls
  end
end
