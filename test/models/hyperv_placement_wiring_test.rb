# frozen_string_literal: true

require 'test_helper'

# PLG-16: the placement becomes fog's, and the WinRM waits become said.
#
# FOG-17 (fog PR #8, evidence §51) made fog the ONE place that composes a
# machine's disk folder: the declared placement_path replaces the node's disk
# root outright when absolute, and every shape that used to answer a RELATIVE
# join — a relative placement folder, a host answering no disk/config root, an
# unresolvable computer — is refused there by name instead. But under Foreman
# the plugin's own prepended fog_extensions shim still answered placement_path
# through a plain attr_accessor and joined the disk path itself, so fog's
# refused join only ever ran for machines WITHOUT placement. The Pass-36
# C:\plg22-row disk was that shim's join fed a placement folder with no root
# in it (§51's mechanism disclosure). This suite pins the retirement:
#
#   1. the placement rides the model through fog's own declared attribute —
#      named in the servers.new attributes, before the machine is built —
#      and re-asserted exactly once when the host create answer merges back
#      over the model and erases it (measured: without the re-assert the
#      first PLG-16 live row put the disk at the host's own disk root);
#   2. the plugin shim answers NOTHING for placement: no accessor, no
#      build_vhd_path override, and the build_vhd_path a prepended server
#      carries is fog's own method again;
#   3. the stand-alone machine names no placement and keeps fog's host-root
#      default (and the hypervisor-path config fallback) exactly as PLG-14
#      left it;
#   4. every Fog::Compute the resource composes — its own client and each
#      per-node client — says the WinRM waits fog only ever sends when
#      configured (evidence §37.6): the gem's own 60/70 s caps sat under the
#      >=90 s margin the plan chose over the measured NTLM/fresh-connection
#      worst case, and a stalled cold cluster read must END (partial, and
#      then refused) at this cap rather than at whatever the gem guesses.
class HypervPlacementWiringTest < ActiveSupport::TestCase
  HOST = 'hv-node1'
  VOL1 = 'C:\ClusterStorage\Volume1'
  VM_NAME = 'plg16-row'
  CR_URL = "http://#{HOST}:5985/wsman".freeze

  # The machine fog's servers.new builds. It records the CONSTRUCTOR
  # attributes exactly as they arrived (that is the PLG-16 claim), carries
  # placement the way fog-core does (a declared attribute merged at
  # construction), has create() answer the way FOG-17's really does — the
  # host's New-VM reply merges back over the model and knows no placement,
  # so the merge erases it (measured by the first PLG-16 live row: the disk
  # fell to the host's own disk root) — and records every placement_path=
  # writer call after construction.
  class PlacementVm
    # PLG-28: the plugin's fog extension gives every fog server this accessor;
    # a double of that class answers to it too.
    attr_accessor :switch_name_resolver
    attr_reader :new_attributes, :create_kwargs, :placement_writes, :generation, :placement_path

    def initialize(attributes)
      @new_attributes = (attributes || {}).dup
      @placement_writes = []
      @placement_path = @new_attributes[:placement_path]
      @generation = :BIOS
    end

    def name
      @new_attributes[:name]
    end

    def computer_name
      @new_attributes[:computer_name]
    end

    def placement_path=(value)
      @placement_writes << value
      @placement_path = value
    end

    def create(**attrs)
      @create_kwargs = attrs
      # fog's create merges the host answer over the model by return fields,
      # and the host answers placement as an EMPTY STRING (measured by the
      # PLG-16 trace row) — empty is fog's own "no placement", so the merge
      # erases the named folder.
      @placement_path = ''
    end

    def persisted?
      true
    end

    def start; end
  end

  class PlacementServers
    attr_reader :built

    def new(attributes = nil)
      @built = PlacementVm.new(attributes)
    end
  end

  class PlacementFog
    attr_reader :servers

    def initialize
      @servers = PlacementServers.new
    end
  end

  def build_cr(fog: PlacementFog.new, overrides: nil)
    cr = ForemanHyperv::Hyperv.new(name: 'lab-cr', url: CR_URL, user: 'u', password: 'p')
    cr.hyperv_node_overrides = overrides if overrides
    cr.stubs(:client).returns(fog)
    cr.stubs(:hypervisor).returns(stub('hypervisor', name: HOST, virtual_machine_path: 'C:\VMs',
                                                     virtual_hard_disk_path: 'C:\VMs\Disks'))
    cr.stubs(:validate_interfaces)
    cr.stubs(:validate_volumes)
    cr.stubs(:create_interfaces)
    cr.stubs(:create_volumes)
    [cr, fog]
  end

  # ---- 1. the placement rides the declared fog attribute at construction ----

  def test_a_clustered_create_names_the_placement_in_the_servers_new_attributes
    fog = PlacementFog.new
    cr, = build_cr(fog: fog)
    cr.stubs(:cluster_named).returns(stub('cluster', name: 'lab-cluster'))
    cr.stubs(:placement_storage).returns(
      ForemanHyperv::Hyperv::ApiStorageDomain.new('Cluster Volume1', VOL1, 100, 50, 50)
    )
    cr.stubs(:enablement_supported?).returns(true)
    cr.stubs(:validate_placement!)
    cr.stubs(:clusterize?).returns(false)

    cr.create_vm(name: VM_NAME, cluster_name: 'lab-cluster', start: '0', generation: 2,
                 memory_startup: '512', processor_count: '1',
                 dynamic_memory_enabled: '0', notes: 'plg16')

    placed = fog.servers.built.new_attributes[:placement_path]
    assert_equal "#{VOL1}\\#{VM_NAME}", placed,
                 'the placement folder rides the model the moment it is built, so fog — not a ' \
                 'plugin join — composes the disk path from the one attribute it refuses'
    assert_equal [placed], fog.servers.built.placement_writes,
                 'the host create answer erases the named placement when it merges over the ' \
                 'model; the compute resource re-asserts it through fog own declared writer, ' \
                 'exactly once, before the disks are built'
    assert_equal placed, fog.servers.built.placement_path,
                 'the placement is still named when the disks of the machine are built'
  end

  # ---- 3. stand-alone semantics ride unchanged ----

  def test_a_standalone_create_names_no_placement_and_keeps_the_host_default
    fog = PlacementFog.new
    cr, = build_cr(fog: fog)
    cr.stubs(:create_allowed?).returns(true)

    cr.create_vm(name: 'plg16-standalone', start: '0', generation: 2,
                 memory_startup: '512', processor_count: '1',
                 dynamic_memory_enabled: '0', notes: 'plg16')

    assert_nil fog.servers.built.new_attributes[:placement_path],
               'a stand-alone machine names no placement: fog answers its host-root default'
    assert_empty fog.servers.built.placement_writes,
                 'nothing writes placement onto a stand-alone machine'
    assert_equal 'C:\VMs', fog.servers.built.create_kwargs[:path],
                 'the stand-alone config fallback rides exactly as PLG-14 left it'
  end

  # ---- 2. the plugin shim answers nothing for placement ----

  def test_the_plugin_shim_no_longer_answers_placement_itself
    shim = FogExtensions::Hyperv::Server
    %i[placement_path placement_path= build_vhd_path].each do |answered|
      assert_not_includes shim.instance_methods(false), answered,
                          "the prepended shim must not answer #{answered}: FOG-17 made fog the one " \
                          'place that composes and refuses a disk folder'
    end
  end

  def test_the_prepended_server_carries_fogs_own_disk_path_join
    fog_class = Fog::Hyperv::Compute::Server
    assert_includes fog_class.attributes, :placement_path,
                    'the deployed fog declares placement_path (FOG-17) — the pin this retirement stands on'
    assert_equal fog_class, fog_class.instance_method(:build_vhd_path).owner,
                 'a prepended server must run fog own refused join, not a plugin override'
  end

  # ---- 4. the WinRM waits are said on every composed client ----

  def test_the_resource_client_sets_the_winrm_waits_fog_only_sends_when_configured
    # built WITHOUT the usual :client stub — this test IS about what the
    # real client hands to Fog::Compute.new
    cr = ForemanHyperv::Hyperv.new(name: 'lab-cr', url: CR_URL, user: 'u', password: 'p')
    Fog::Compute.expects(:new).once.with do |options|
      options[:hyperv_endpoint] == CR_URL &&
        options[:hyperv_operation_timeout] == 90 &&
        options[:hyperv_receive_timeout] == 120
    end.returns(Object.new)

    cr.send(:client)
  end

  def test_the_per_node_client_sets_the_same_waits
    cr = ForemanHyperv::Hyperv.new(name: 'lab-cr', url: CR_URL, user: 'u', password: 'p')
    cr.hyperv_node_overrides = 'hv-node2 = 192.168.1.67'
    Fog::Compute.expects(:new).once.with do |options|
      options[:hyperv_endpoint] == 'http://192.168.1.67:5985/wsman' &&
        options[:hyperv_operation_timeout] == 90 &&
        options[:hyperv_receive_timeout] == 120
    end.returns(Object.new)

    cr.send(:client_for_node, 'HV-NODE2')
  end
end
