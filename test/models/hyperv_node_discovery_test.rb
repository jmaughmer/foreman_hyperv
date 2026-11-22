# frozen_string_literal: true

require 'test_helper'
require 'active_support/test_case'

# PLG-5b: the address the cluster gives its own nodes, and the hardened
# transports row (w) finally measured. The override stays the operator's
# word; discovery is the machine's — Get-ClusterNetworkInterface answers
# node→address for EVERY node from any node of the cluster (measured
# 2026-11-22, the (w) MSI row: three nodes, two cluster networks), and the
# pick rule is the measured one: an interface counts for placement traffic
# only when its cluster network carries Role = 3 (cluster AND client — the
# lab's management net; the internal-only net answered Role = 1 and holds
# the 10.90.x addresses no client can dial). Anything the rule cannot pick
# is REFUSED with the node named, never guessed: no interface, no
# client-role interface, an address that is not IPv4, or more than one
# candidate. The composition rule is the other half of the matrix: the
# measured http+negotiate transport composes for any identity; the measured
# https+negotiate transport composes ONLY for a name a certificate can be
# verified against — an IPv4 identity under https stays refused, because
# the (w) rows found no hostname-verified path to an IP endpoint and the
# fix for that (ssl_verify false) is exactly what this plugin refuses to
# force on an operator. The trust the https rows needed (row
# HTTPS-NEG-FQDN OK on all three nodes) came from an explicit CA file —
# fog's hyperv_ca_trust_path — so the compute resource carries one.
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

class HypervNodeDiscoveryTest < ActiveSupport::TestCase
  alias assert_not refute

  CR_HOST = 'hv-node1.lab.maughmer.net'
  CR_URL = "http://#{CR_HOST}:5985/wsman".freeze
  CR_URL_TLS = "https://#{CR_HOST}:5986/wsman".freeze
  VM_GUID = '94f8b7b0-2a1d-4a1d-9f2e-6c0f1d2e3a4b'
  OWNER_NODE = 'HV-NODE2'
  DISCOVERED_IP = '192.168.1.67'
  CA_FILE = '/etc/pki/hv-lab/ca.crt'

  # The MSI row measured on HV-CL01 on 2026-11-22, verbatim in shape: three
  # nodes on the client-role (3) management net, the same three on the
  # internal-only (1) net, and the answering cluster named.
  MEASURED_ANSWER = {
    'clusterName' => 'HV-CL01',
    'interfaces' => [
      { 'node' => 'hv-node1', 'adapter' => 'hv-node1 - vEthernet (External)',
        'network' => 'Cluster Network 1', 'address' => '192.168.1.66', 'netRole' => 3 },
      { 'node' => 'hv-node2', 'adapter' => 'hv-node2 - vEthernet (External)',
        'network' => 'Cluster Network 1', 'address' => '192.168.1.67', 'netRole' => 3 },
      { 'node' => 'hv-node3', 'adapter' => 'hv-node3 - vEthernet (External)',
        'network' => 'Cluster Network 1', 'address' => '192.168.1.68', 'netRole' => 3 },
      { 'node' => 'hv-node1', 'adapter' => 'hv-node1 - Ethernet 2',
        'network' => 'Cluster Network 2', 'address' => '10.90.0.66', 'netRole' => 1 },
      { 'node' => 'hv-node2', 'adapter' => 'hv-node2 - Ethernet 2',
        'network' => 'Cluster Network 2', 'address' => '10.90.0.67', 'netRole' => 1 },
      { 'node' => 'hv-node3', 'adapter' => 'hv-node3 - Ethernet 2',
        'network' => 'Cluster Network 2', 'address' => '10.90.0.68', 'netRole' => 1 }
    ]
  }.freeze

  StdoutDouble = Struct.new(:stdout)
  RoleDouble = Struct.new(:owner_node)

  class RolesDouble
    def initialize(roles)
      @roles = roles
    end

    def all(**)
      @roles
    end
  end

  # The CR's own fog client. run_cmd answers with a canned stdout so the
  # suite drives the discovery parser through whatever shapes it likes;
  # everything unscripted is recorded, so "the address read never ran" is a
  # claim over the fog surface, not a guess.
  class CrFog
    attr_reader :fog_calls, :servers_get_calls, :run_cmd_calls

    def initialize(roles: nil, address_answer: nil)
      @roles = roles
      @address_answer = address_answer
      @fog_calls = []
      @servers_get_calls = []
      @run_cmd_calls = []
    end

    def supports_clusters?
      true
    end

    def cluster_virtual_machine_roles
      @fog_calls << [:cluster_virtual_machine_roles, []]
      @roles
    end

    def run_cmd(script, _skip_json: nil)
      @run_cmd_calls << script
      StdoutDouble.new(@address_answer)
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
      %i[servers get cluster_virtual_machine_roles supports_clusters? run_cmd].include?(name) || super
    end
  end

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
      skip 'Needs a booted Foreman (rake test:plugins): these cover model-level discovery semantics.'
    end
    begin
      require 'mocha/minitest'
    rescue LoadError
      skip 'mocha is not available outside the Foreman bundle.'
    end
  end

  def build_cr(overrides: nil, url: CR_URL, fog: CrFog.new, ca_trust_path: nil)
    cr = ForemanHyperv::Hyperv.new(name: 'lab-cr', url: url, user: 'u', password: 'p')
    cr.hyperv_node_overrides = overrides
    cr.hyperv_ca_trust_path = ca_trust_path if trust_column?
    cr.stubs(:client).returns(fog)
    [cr, fog]
  end

  def trust_column?
    return @trust_column unless @trust_column.nil?

    @trust_column = ComputeResource.column_names.include?('hyperv_ca_trust_path')
  end

  def measured_answer
    Marshal.load(Marshal.dump(MEASURED_ANSWER))
  end

  # ---- the script: one shell, a witness, both cluster legs, no measured-breaking pipelines ----

  def test_the_address_script_witnesses_the_answering_cluster_first
    script = ForemanHyperv::Hyperv.new.send(:cluster_node_address_script)
    assert_includes script, '$cluster = Get-Cluster'
    assert_includes script, 'clusterName = [string]$cluster.Name'
  end

  def test_the_address_script_reads_both_cluster_legs_and_breaks_no_measured_pipeline_rules
    script = ForemanHyperv::Hyperv.new.send(:cluster_node_address_script)
    assert_includes script, '@(Get-ClusterNetwork)'
    assert_includes script, '@(Get-ClusterNetworkInterface'
    assert_includes script, "$WarningPreference = 'SilentlyContinue'"
    assert_includes script, 'ConvertTo-Json -Compress -Depth 4'
    assert_not script.include?('Select-Object -First'), 'early termination kills cluster pipelines (evidence §2)'
    assert_includes script, 'node = [string]$_.Node'
    assert_not script.include?('$_.Node.Name'),
               'Node answers a STRING on the live cluster — .Node.Name read empty and dropped every row (live row)'
  end

  # ---- the pick rule, over the measured answer ----

  def test_the_measured_answer_yields_each_nodes_ipv4_on_the_client_role_network
    cr, = build_cr(fog: CrFog.new(address_answer: Fog::JSON.encode(measured_answer)))
    { 'hv-node1' => '192.168.1.66', 'hv-node2' => '192.168.1.67', 'hv-node3' => '192.168.1.68' }.each do |node, ip|
      assert_equal ip, cr.send(:discover_node_address, node)
    end
  end

  def test_names_match_case_insensitively_and_a_fqdn_is_read_by_its_first_label
    cr, = build_cr(fog: CrFog.new(address_answer: Fog::JSON.encode(measured_answer)))
    assert_equal DISCOVERED_IP, cr.send(:discover_node_address, OWNER_NODE)
    assert_equal DISCOVERED_IP, cr.send(:discover_node_address, 'hv-node2.lab.maughmer.net')
  end

  def test_a_node_only_on_internal_networks_is_refused_by_name_and_reason
    answer = measured_answer
    answer['interfaces'] = answer['interfaces'].reject { |i| i['node'] == 'hv-node3' && i['netRole'] == 3 }
    cr, = build_cr(fog: CrFog.new(address_answer: Fog::JSON.encode(answer)))
    error = assert_raises(ForemanHyperv::OperationRefused) { cr.send(:discover_node_address, 'HV-NODE3') }
    assert_includes error.message, 'hv-node3', 'the refusal must name the node it could not address'
    assert_includes error.message.downcase, 'client', 'the refusal must say the interfaces were not client-role'
  end

  def test_an_unknown_node_is_refused_by_name
    cr, = build_cr(fog: CrFog.new(address_answer: Fog::JSON.encode(measured_answer)))
    error = assert_raises(ForemanHyperv::OperationRefused) { cr.send(:discover_node_address, 'hv-node9') }
    assert_includes error.message, 'hv-node9'
  end

  def test_two_client_role_addresses_refuse_the_pick_and_name_both
    answer = measured_answer
    answer['interfaces'] << { 'node' => 'hv-node2', 'adapter' => 'hv-node2 - Backup',
                              'network' => 'Cluster Network 3', 'address' => '172.16.5.7', 'netRole' => 3 }
    answer['interfaces'] << { 'node' => 'hv-node2', 'adapter' => 'stale',
                              'network' => 'Cluster Network 9', 'address' => '172.16.9.9', 'netRole' => 3 }
    cr, = build_cr(fog: CrFog.new(address_answer: Fog::JSON.encode(answer)))
    error = assert_raises(ForemanHyperv::OperationRefused) { cr.send(:discover_node_address, 'hv-node2') }
    assert_includes error.message, '172.16.5.7'
    assert_includes error.message, '172.16.9.9', 'the refusal names the candidates it refused to choose between'
  end

  def test_a_non_ipv4_client_role_address_is_refused_not_dialed
    answer = measured_answer
    answer['interfaces'] = answer['interfaces'].map do |i|
      i['node'] == 'hv-node2' && i['netRole'] == 3 ? i.merge('address' => 'fe80::a1b2') : i
    end
    cr, = build_cr(fog: CrFog.new(address_answer: Fog::JSON.encode(answer)))
    error = assert_raises(ForemanHyperv::OperationRefused) { cr.send(:discover_node_address, 'hv-node2') }
    assert_includes error.message, 'fe80::a1b2', 'the refusal names the address it could not dial'
  end

  def test_the_address_read_runs_once_per_compute_resource_instance
    fog = CrFog.new(address_answer: Fog::JSON.encode(measured_answer))
    cr, = build_cr(fog: fog)
    cr.send(:discover_node_address, 'hv-node2')
    cr.send(:discover_node_address, 'hv-node3')
    assert_equal 1, fog.run_cmd_calls.size, 'the whole cluster answers one read; two lookups are not two reads'
  end

  # ---- envelope refusals: the same refuse-dont-guess discipline as the capacity read ----

  def test_silence_and_undecodable_answers_are_refused
    ['', '   ', 'Cluster Network 1', '{"clusterName": "HV-CL01" oops'].each do |answer|
      cr, = build_cr(fog: CrFog.new(address_answer: answer))
      assert_raises(ForemanHyperv::OperationRefused) { cr.send(:discover_node_address, OWNER_NODE) }
    end
  end

  def test_an_answer_without_the_answering_cluster_is_refused
    answer = measured_answer
    answer['clusterName'] = ''
    cr, = build_cr(fog: CrFog.new(address_answer: Fog::JSON.encode(answer)))
    error = assert_raises(ForemanHyperv::OperationRefused) { cr.send(:discover_node_address, OWNER_NODE) }
    assert_includes error.message.downcase, 'cluster'
  end

  def test_a_cluster_answering_no_interfaces_at_all_is_a_refused_contradiction
    [
      { 'clusterName' => 'HV-CL01', 'interfaces' => [] },
      { 'clusterName' => 'HV-CL01', 'interfaces' => nil },
      { 'clusterName' => 'HV-CL01' }
    ].each do |answer|
      cr, = build_cr(fog: CrFog.new(address_answer: Fog::JSON.encode(answer)))
      assert_raises(ForemanHyperv::OperationRefused) { cr.send(:discover_node_address, OWNER_NODE) }
    end
  end

  # ConvertTo-Json collapses a one-element array to a bare object on the
  # measured build (the same lesson the capacity read carries); the
  # single-homed cluster must still read as a list.
  def test_a_single_interface_answer_stays_a_list
    answer = measured_answer.merge('interfaces' => measured_answer['interfaces'].first)
    cr, = build_cr(fog: CrFog.new(address_answer: Fog::JSON.encode(answer)))
    assert_equal '192.168.1.66', cr.send(:discover_node_address, 'HV-NODE1')
  end

  # ---- the composition: override wins, discovery fills, R17 now names what it refuses ----

  def test_the_discovered_address_composes_the_http_endpoint
    cr, = build_cr(fog: CrFog.new(address_answer: Fog::JSON.encode(measured_answer)))
    assert_equal "http://#{DISCOVERED_IP}:5985/wsman", cr.send(:node_endpoint, OWNER_NODE)
  end

  def test_an_override_never_makes_the_address_read_run
    fog = CrFog.new(address_answer: nil)
    cr, = build_cr(overrides: "hv-node2 = #{DISCOVERED_IP}", fog: fog)
    assert_equal "http://#{DISCOVERED_IP}:5985/wsman", cr.send(:node_endpoint, OWNER_NODE)
    assert_empty fog.run_cmd_calls, 'the operator word wins without asking the cluster'
  end

  def test_the_https_resource_now_composes_a_named_override_endpoint
    skip 'the hyperv_ca_trust_path column has not been migrated in this test database' unless trust_column?
    cr, = build_cr(overrides: 'hv-node2 = hv-node2.lab.maughmer.net', url: CR_URL_TLS,
                   fog: CrFog.new(address_answer: nil), ca_trust_path: CA_FILE)
    assert_equal 'https://hv-node2.lab.maughmer.net:5986/wsman', cr.send(:node_endpoint, OWNER_NODE)
  end

  def test_an_https_resource_refuses_an_ip_override_and_names_the_verification_reason
    cr, = build_cr(overrides: "hv-node2 = #{DISCOVERED_IP}", url: CR_URL_TLS,
                   fog: CrFog.new(address_answer: nil))
    error = assert_raises(ForemanHyperv::OperationRefused) { cr.send(:node_endpoint, OWNER_NODE) }
    assert_includes error.message, "https://#{DISCOVERED_IP}:5986/wsman",
                    'the refusal names the composed endpoint it refused to dial'
    assert_includes error.message.downcase, 'hostname', 'the reason is certificate hostname verification (row (w))'
  end

  def test_an_https_resource_refuses_a_discovered_ip_address_for_the_same_reason
    cr, = build_cr(fog: CrFog.new(address_answer: Fog::JSON.encode(measured_answer)), url: CR_URL_TLS)
    error = assert_raises(ForemanHyperv::OperationRefused) { cr.send(:node_endpoint, OWNER_NODE) }
    assert_includes error.message.downcase, 'hostname'
  end

  # ---- the per-node instance: the trust the https row needed rides the fog option ----

  def test_the_per_node_client_carries_the_ca_trust_path_only_when_the_resource_names_one
    skip 'the hyperv_ca_trust_path column has not been migrated in this test database' unless trust_column?
    fog = CrFog.new(address_answer: Fog::JSON.encode(measured_answer))
    with_trust, = build_cr(fog: fog, ca_trust_path: CA_FILE)
    Fog::Compute.expects(:new).with do |options|
      options[:hyperv_ca_trust_path] == CA_FILE && options[:hyperv_endpoint] == "http://#{DISCOVERED_IP}:5985/wsman"
    end.returns(Object.new)
    with_trust.send(:client_for_node, OWNER_NODE)

    Fog::Compute.expects(:new).with { |options| !options.key?(:hyperv_ca_trust_path) }.returns(Object.new)
    without_trust, = build_cr(fog: fog)
    without_trust.send(:client_for_node, OWNER_NODE)
  end

  # ---- the read ladder: override, self, discovery, refusal ----

  def test_a_role_from_a_discovered_node_is_read_on_the_per_node_client_at_the_discovered_ip
    fog = CrFog.new(roles: RolesDouble.new([RoleDouble.new(OWNER_NODE)]),
                    address_answer: Fog::JSON.encode(measured_answer))
    cr, = build_cr(fog: fog)
    node_fog = NodeFog.new
    cr.stubs(:client_for_node).with(OWNER_NODE).returns(node_fog)

    vm = cr.send(:vm_from_cluster_owner, VM_GUID)

    assert_equal :node_vm, vm
    assert_equal [[VM_GUID, { computer_name: DISCOVERED_IP }]], node_fog.get_calls,
                 'the read goes to the per-node client addressed by the DISCOVERED address — the ' \
                 'unqualified name still never reaches fog\'s completion sink (R22)'
    assert_empty fog.servers_get_calls
  end

  def test_a_discovery_refusal_travels_up_naming_the_node_rather_than_faking_no_owner
    fog = CrFog.new(roles: RolesDouble.new([RoleDouble.new('HV-NODE9')]), address_answer: '')
    cr, = build_cr(fog: fog)
    error = assert_raises(ForemanHyperv::OperationRefused) { cr.send(:vm_from_cluster_owner, VM_GUID) }
    assert_includes error.message, 'hv-node9'
    assert_empty fog.servers_get_calls
  end

  def test_the_endpoint_serving_its_own_node_never_runs_the_address_read
    fog = CrFog.new(roles: RolesDouble.new([RoleDouble.new('HV-NODE1')]),
                    address_answer: Fog::JSON.encode(measured_answer))
    cr, = build_cr(fog: fog)
    vm = cr.send(:vm_from_cluster_owner, VM_GUID)
    assert_nil vm
    assert_equal [[VM_GUID, { computer_name: CR_HOST }]], fog.servers_get_calls,
                 'the self rung keeps reading on the CR client, addressed by the endpoint host'
    assert_empty fog.run_cmd_calls, 'a node the endpoint serves itself has nothing to discover'
  end

  # ---- the trust attribute: refused at save, not sanitized (the PLG-15 discipline) ----

  def test_the_trust_path_is_refused_at_save_unless_it_is_a_bare_absolute_path
    skip 'the hyperv_ca_trust_path column has not been migrated in this test database' unless trust_column?
    [CA_FILE].each do |value|
      cr, = build_cr(ca_trust_path: value)
      assert cr.valid?, "#{value.inspect} must validate: #{cr.errors.full_messages}"
    end
    ['relative/ca.crt', '/etc/pki/la`b/ca.crt', '/etc/pki/$(x)/ca.crt', '/etc/pki/la b/ca.crt',
     'ca.crt', '/etc/pki/../etc/ca.crt'].each do |value|
      cr, = build_cr(ca_trust_path: value)
      assert_not cr.valid?, "#{value.inspect} must be refused"
    end
  end

  def test_a_blank_trust_path_is_valid_and_reaches_no_error
    skip 'the hyperv_ca_trust_path column has not been migrated in this test database' unless trust_column?
    [nil, '', '   '].each do |value|
      cr, = build_cr(ca_trust_path: value)
      assert cr.valid?, "blank trust must validate (#{value.inspect}): #{cr.errors.full_messages}"
    end
  end
end
