# frozen_string_literal: true

require 'test_helper'
require 'active_support/test_case'

# PLG-25: the machine form's cluster/computer listing. cluster_backed_hosts is
# the listing the form leans on, and its per-node detail read must go through
# the SAME per-node client (client_for_node, N4) every other node operation
# uses: fog's exact_host_connection capability refuses to dial any name the
# compute resource's own client has not already spoken to, so a node.host read
# rides the resource client and refuses EVERY non-endpoint node — not because
# WinRM is down there, but because the plugin itself refuses to point its
# credentials at a host it did not compose. On 2026-11-22 the first clustered
# machine driven through the host form met exactly this: the VM tab died on
# `Refusing to connect to "hv-node2"`, the Cluster and Computer selects
# vanished with it, and the submitted machine carried no cluster_name.
# A node that is genuinely unreachable must still stay in the listing with
# only its name — the form lists the cluster's nodes whatever one of them is
# doing — but that rescue is for a real failure, not for the plugin's own
# routing.
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

class HypervClusterBackedHostsTest < ActiveSupport::TestCase
  alias assert_not refute

  CR_URL = 'http://hv-node1.lab.maughmer.net:5985/wsman'

  # A cluster node exactly as fog hands it over. #host is the fog read that
  # dials the node THROUGH THE CLIENT THAT OWNS THE CLUSTER READ — the
  # resource's own client — and under exact_host_connection that is the one
  # door a non-endpoint node cannot open; the refusal below is the production
  # text, verbatim in shape (the winrm builder's refuse_unknown_host).
  class FakeNode
    attr_reader :name, :host_calls

    def initialize(name)
      @name = name
      @host_calls = 0
    end

    def host
      @host_calls += 1
      raise Fog::Hyperv::Errors::PSError.new(
        Fog::Hyperv::Utils::Winrm::LocalExecOutput.new(
          '',
          "Refusing to connect to #{name.downcase.inspect}: it is neither the configured endpoint, nor one " \
          'of the names registered for it, nor a node under either.',
          1
        ),
        'When connecting to a host outside the configured endpoint set'
      )
    end
  end

  FakeHost = Struct.new(:name)

  # The per-node fog client: its endpoint IS the node, so hosts.first is that
  # node's Get-VMHost and the set check passes by construction.
  class FakeNodeClient
    def initialize(host)
      @host = host
    end

    def hosts
      self
    end

    def first
      @host
    end
  end

  # The resource's own fog client, only as far as this listing touches it:
  # hosts.new is the rescue's name-only stand-in.
  class FakeCrFog
    def hosts
      self
    end

    def new(**attrs)
      FakeHost.new(attrs[:name])
    end
  end

  FakeCluster = Struct.new(:name, :nodes)

  def cr
    @cr ||= begin
      resource = ForemanHyperv::Hyperv.new(name: 'lab-cr', url: CR_URL, user: 'u', password: 'p')
      resource.stubs(:client).returns(FakeCrFog.new)
      resource
    end
  end

  def test_per_node_reads_route_through_the_per_node_client
    nodes = %w[HV-NODE1 HV-NODE2 HV-NODE3].map { |name| FakeNode.new(name) }
    answered = {}
    nodes.each do |node|
      host = FakeHost.new(node.name.downcase)
      answered[node.name] = host
      cr.expects(:client_for_node).with(node.name).returns(FakeNodeClient.new(host))
    end

    hosts = cr.send(:cluster_backed_hosts, FakeCluster.new('HV-CL01', nodes))

    # The listing is the nodes' own hosts — the objects the per-node clients
    # answered — and the resource client's node-dialing fog read (node.host)
    # was never reached for any of them.
    assert_equal %w[hv-node1 hv-node2 hv-node3], hosts.map(&:name)
    assert_same answered['HV-NODE1'], hosts.first
    assert_same answered['HV-NODE2'], hosts[1]
    assert_same answered['HV-NODE3'], hosts[2]
    assert_equal [0, 0, 0], nodes.map(&:host_calls)
  end

  def test_a_node_that_will_not_answer_stays_in_the_listing_name_only
    nodes = [FakeNode.new('HV-NODE1'), FakeNode.new('HV-NODE2')]
    cr.expects(:client_for_node).with('HV-NODE1').returns(FakeNodeClient.new(FakeHost.new('hv-node1')))
    # A real failure this time — the node client dialed and WinRM did not answer.
    cr.expects(:client_for_node).with('HV-NODE2').raises(
      Fog::Hyperv::Errors::PSError.new(
        Fog::Hyperv::Utils::Winrm::LocalExecOutput.new('', 'WinRM cannot complete the request', 1), 'wsman'
      )
    )

    hosts = cr.send(:cluster_backed_hosts, FakeCluster.new('HV-CL01', nodes))

    assert_equal %w[hv-node1 HV-NODE2], hosts.map(&:name)
  end

  # The form's entry point: the named cluster gets the resilient listing, no
  # cluster name gets the resource's own listing, and fog's heavy
  # Cluster#hosts — the one that dials every node through the resource client
  # and takes the whole listing down with the first refusal — is not what the
  # form renders.
  def test_form_computers_routes_by_cluster_name
    cluster = FakeCluster.new('HV-CL01', [FakeNode.new('HV-NODE1')])
    cr.stubs(:cluster_named).with('HV-CL01').returns(cluster)
    cr.expects(:cluster_backed_hosts).with(cluster).returns([FakeHost.new('hv-node1'), FakeHost.new('hv-node2')])
    assert_equal %w[hv-node1 hv-node2], cr.form_computers('HV-CL01').map(&:name)

    cr.stubs(:cluster_named).with(nil).returns(nil)
    cr.stubs(:hosts).returns([FakeHost.new('hv-node1')])
    assert_equal ['hv-node1'], cr.form_computers(nil).map(&:name)
  end
end
