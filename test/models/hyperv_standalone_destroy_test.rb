# frozen_string_literal: true

require 'test_helper'
require 'active_support/test_case'

# PLG-15c: the stand-alone destroy unlock. A destroy is now allowed when, and
# only when, every one of these answers on this attempt: the endpoint carries
# NO sticky cluster sighting in the insert-only ledger; arm (a) reads
# not-clustered; BOTH configured markers (the ClusSvc PARAMS registry key and
# the cluster database file) answer the not-found exception; the clusapi
# service-state read (GetNodeClusterState) is one of the measured stand-alone
# shapes — state 1 with the service record present, or state 0 with the
# service record AND the cluster directory also answering not-found — and the
# machine's computer name re-read at destroy time is the name the endpoint
# gives itself. rc≠0 or a raising P-Invoke is ALWAYS indeterminate (N2), never
# a feature-absent reading; joined (19) and maintenance (3) states refuse with
# the canonical sentence, and so does a sticky sighting, a present marker or a
# role the machine reports. An allowed destroy detaches drives and Remove-VMs
# only: no VHDX deletes, no folder deletes — those belong to PLG-22. These
# need a booted Foreman (compute resources are Active Record), so the file
# looks for the app around the plugin and says so out loud where none exists.
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
# The gate's indeterminate class is populated by exactly the WinRM faults this
# suite scripts; fog only requires winrm when a real client connects.
require 'winrm' if FOREMAN_BOOT || (defined?(Rails) && Rails.application)

class HypervStandaloneDestroyTest < ActiveSupport::TestCase
  alias assert_not refute

  VM_NAME = 'plg15c-vm'
  VM_GUID = '94f8b7b0-2a1d-4a1d-9f2e-6c0f1d2e3a4b'
  HOST = 'hv-node1.lab.maughmer.net'

  ShellOut = Struct.new(:stdout, :stderr, :exitcode)

  ITEM_NOT_FOUND = 'System.Management.Automation.ItemNotFoundException'
  ABSENT = ShellOut.new(
    %({"result":"absent","type":"#{ITEM_NOT_FOUND}"}), '', 0
  ).freeze

  # The gate's three fog commands: the two marker reads carry their paths, and
  # the service-state read carries the P/Invoke name. Routing on those keeps
  # the scripted answers honest about which command asked.
  class GateFog
    attr_accessor :wql_rows, :wql_error, :params_out, :clusdb_out, :service_out, :servers_default
    attr_reader :wql_calls, :cmd_calls, :fog_calls

    def initialize
      @wql_calls = []
      @cmd_calls = []
      @fog_calls = []
    end

    def run_wql(query, **kwargs)
      @wql_calls << [query, kwargs.fetch(:_namespace)]
      raise @wql_error if @wql_error

      @wql_rows
    end

    def run_cmd(script, _skip_json: false)
      @cmd_calls << script
      out = if script.include?('GetNodeClusterState')
              @service_out
            elsif script.include?('CLUSDB')
              @clusdb_out
            else
              @params_out
            end
      raise out if out.is_a?(Exception)

      out
    end

    def servers
      @servers_default
    end

    def method_missing(name, *args)
      @fog_calls << [name, args]
      nil
    end

    def respond_to_missing?(name, include_all = false)
      name == :servers || super
    end

    def fog_calls_named(*names)
      fog_calls.select { |(name, _args)| names.include?(name) }
    end
  end

  # fog's servers collection, including the get the destroy path starts from.
  class ServersDouble
    attr_reader :new_calls, :get_calls

    def initialize(vm)
      @vm = vm
      @new_calls = []
      @get_calls = []
    end

    def all(*_args)
      [@vm].compact
    end

    def new(attributes = nil)
      @new_calls << attributes
      @vm
    end

    def get(id, *_args)
      @get_calls << id
      @vm
    end
  end

  class HddDouble
    attr_reader :calls

    def initialize
      @calls = []
    end

    def destroy(underlying: false)
      @calls << [:destroy, underlying]
    end
  end

  # The machine fog's servers.get hands back, with every lifecycle step and
  # every destroy-side argument recorded — including the underlying flags the
  # gate must never set true and the role flag the belt reads.
  class VmDouble
    attr_accessor :id, :name, :computer_name, :path, :clustered
    attr_reader :calls

    def initialize
      @id = VM_GUID
      @name = VM_NAME
      @computer_name = HOST
      @path = "C:\\VMs\\#{VM_NAME}"
      @clustered = false
      @calls = []
      @hard_drives = [HddDouble.new, HddDouble.new]
    end

    def clustered?
      @clustered
    end

    def stop(**kwargs)
      @calls << [:stop, kwargs]
    end

    def destroy(underlying = nil)
      @calls << [:destroy, underlying]
    end

    def hard_drives
      @calls << :hard_drives
      @hard_drives
    end
  end

  def setup
    unless FOREMAN_BOOT || (defined?(Rails) && Rails.application)
      skip 'Needs a booted Foreman (rake test:plugins): these cover model-level gate semantics.'
    end
    begin
      require 'mocha/minitest'
    rescue LoadError
      skip 'mocha is not available outside the Foreman bundle.'
    end
  end

  def sightings_table?
    return @sightings_table unless @sightings_table.nil?

    @sightings_table = begin
      ActiveRecord::Base.connection.table_exists?('foreman_hyperv_cluster_sightings')
    rescue ActiveRecord::ActiveRecordError
      false
    end
  end

  # The sticky leg is about the LEDGER, and it is read for real: this suite
  # never writes a sighting for HOST except in the tests that mean to (the
  # transaction rolls them back). The self rung reads the endpoint's own name
  # case-insensitively, on purpose, so the hypervisor answers uppercase.
  def build_cr(fog: GateFog.new, vm: VmDouble.new, host_name: HOST.upcase, url: "http://#{HOST}:5985/wsman")
    fog.servers_default = ServersDouble.new(vm)
    cr = ForemanHyperv::Hyperv.new(name: 'lab-cr', url: url, user: 'u', password: 'p')
    cr.stubs(:client).returns(fog)
    cr.stubs(:hypervisor).returns(stub('hypervisor', name: host_name))
    [cr, fog, vm]
  end

  def tok(result, type = nil)
    type_json = type ? "\"#{type}\"" : 'null'
    ShellOut.new(%({"result":"#{result}","type":#{type_json}}), '', 0)
  end

  # The service-state token, built through the same JSON the machine answers
  # with. The legs keep the shapes fog's ConvertTo-Json produces.
  def service_tok(clusapi:, svc: leg('present'), cdir: leg('present'))
    ShellOut.new(Fog::JSON.encode('clusapi' => clusapi, 'svc' => svc, 'cdir' => cdir), '', 0)
  end

  def leg(result, type = nil)
    { 'result' => result, 'type' => type }
  end

  def clusapi_ok(rc, state)
    { 'result' => 'ok', 'rc' => rc, 'state' => state, 'type' => nil }
  end

  def clusapi_error(type)
    { 'result' => 'error', 'rc' => nil, 'state' => nil, 'type' => type }
  end

  # The answers of a clean stand-alone host, measured shape for shape: the 1359
  # fault, both markers not-found, clusapi state 1 with the service record
  # present (the never-joined row of the §45.2 table).
  def allow_standalone(fog)
    fog.wql_error = WinRM::WinRMWSManFault.new(
      'WSMan Fault: [WSMAN ERROR CODE: 1359]', ForemanHyperv::Hyperv::WIRE_CODE_CLUSTER_UNAVAILABLE
    )
    fog.params_out = ABSENT
    fog.clusdb_out = ABSENT
    fog.service_out = service_tok(clusapi: clusapi_ok(0, ForemanHyperv::Hyperv::CLUSAPI_NOT_CONFIGURED))
    fog
  end

  def destroy_refused(cr, message_fragment)
    error = assert_raises(ForemanHyperv::OperationRefused) { cr.destroy_vm(VM_GUID) }
    assert_includes error.message, message_fragment
    error
  end

  # --- the gate's reading order ----------------------------------------------------

  def test_a_sticky_sighting_refuses_before_anything_is_asked_of_the_host
    cr, fog, vm = build_cr(fog: allow_standalone(GateFog.new))
    cr.stubs(:sticky_cluster_sighting?).returns(true)

    destroy_refused(cr, 'refused in code until FOG-10, PLG-15b and PLG-21b have merged')
    assert_empty fog.wql_calls
    assert_empty fog.cmd_calls
    assert_empty vm.calls, 'a sticky endpoint is refused before its machine is touched'
  end

  def test_a_stored_sighting_for_the_endpoint_makes_it_sticky
    skip 'the sightings table has not been migrated in this test database' unless sightings_table?
    cr, _fog, _vm = build_cr
    ForemanHyperv::ClusterSighting.create!(endpoint_host: HOST, kind: 'sighting', cluster_name: 'hv-cluster')

    assert cr.send(:sticky_cluster_sighting?)
  end

  def test_a_strand_row_alone_does_not_make_the_endpoint_sticky
    skip 'the sightings table has not been migrated in this test database' unless sightings_table?
    cr, _fog, _vm = build_cr
    ForemanHyperv::ClusterSighting.create!(endpoint_host: HOST, kind: 'strand', vm_uuid: VM_GUID, reason: 'x')

    assert_not cr.send(:sticky_cluster_sighting?),
               'a strand is a machine with an unresolved write, not an endpoint that answered as a cluster'
  end

  def test_an_endpoint_that_does_not_parse_to_a_host_is_sticky
    cr, _fog, _vm = build_cr(url: 'not a uri at all')

    assert cr.send(:sticky_cluster_sighting?), 'an unnamed endpoint cannot be proven clean'
  end

  def test_a_machine_that_reports_a_cluster_role_is_refused_before_the_wire
    fog = allow_standalone(GateFog.new)
    vm = VmDouble.new
    vm.clustered = true
    cr, fog, vm = build_cr(fog: fog, vm: vm)

    destroy_refused(cr, 'refused in code until FOG-10, PLG-15b and PLG-21b have merged')
    assert_empty fog.wql_calls
    assert_empty fog.cmd_calls
    assert_empty vm.calls
  end

  def test_a_clustered_membership_reading_refuses_and_appends_the_sighting
    skip 'the sightings table has not been migrated in this test database' unless sightings_table?
    fog = allow_standalone(GateFog.new)
    fog.wql_error = nil
    fog.wql_rows = { name: 'hv-cluster' }
    cr, fog, vm = build_cr(fog: fog)

    before = ForemanHyperv::ClusterSighting.count
    destroy_refused(cr, 'refused in code until FOG-10, PLG-15b and PLG-21b have merged')
    assert_equal before + 1, ForemanHyperv::ClusterSighting.count
    assert_empty fog.cmd_calls, 'a clustered reading is refused before any marker is asked'
    assert_empty vm.calls
  end

  def test_an_unreadable_membership_read_refuses_before_the_markers
    fog = allow_standalone(GateFog.new)
    fog.wql_error = WinRM::WinRMAuthorizationError.new
    cr, fog, vm = build_cr(fog: fog)

    destroy_refused(cr, 'did not read as a stand-alone Hyper-V host')
    assert_empty fog.cmd_calls
    assert_empty vm.calls
  end

  # --- the dual markers, destroy side ------------------------------------------------

  def test_a_present_marker_refuses_as_a_cluster_compute_resource
    fog = allow_standalone(GateFog.new)
    fog.clusdb_out = tok('present')
    cr, _fog, vm = build_cr(fog: fog)

    # Concordant markers are exactly the d22 maintenance shape: the membership
    # read can answer 1359 while CLUSDB and PARAMS stay present. Not proven
    # stand-alone is the definition of a cluster compute resource.
    destroy_refused(cr, 'refused in code until FOG-10, PLG-15b and PLG-21b have merged')
    assert_empty vm.calls
  end

  def test_a_denied_or_unreadable_marker_refuses_as_an_unknown
    %w[denied unreadable].each do |result|
      fog = allow_standalone(GateFog.new)
      fog.params_out = tok(result, 'System.Security.SecurityException')
      cr, _fog, vm = build_cr(fog: fog)

      destroy_refused(cr, 'did not read as a stand-alone Hyper-V host')
      assert_empty vm.calls
    end
  end

  # --- the service-state read ----------------------------------------------------------

  def test_the_service_script_names_its_primitives_and_carries_the_classes
    cr, _fog, _vm = build_cr

    script = cr.send(:cluster_service_read_script)

    assert_includes script, 'GetNodeClusterState'
    assert_includes script, 'clusapi.dll'
    assert_includes script, 'CharSet.Unicode', 'the W is not the char set the measured P/Invoke used'
    assert_includes script, "Get-ItemProperty -LiteralPath 'HKLM:\\SYSTEM\\CurrentControlSet\\Services\\ClusSvc'"
    assert_includes script, "Get-Item -LiteralPath 'C:\\Windows\\Cluster'"
    assert_not_includes script, 'Test-Path', 'both stores are opened through the named primitive'
    2.times do
      assert_includes script, 'catch [System.Management.Automation.ItemNotFoundException]',
                      'absent is only ever the not-found exception'
    end
    %w[System.Security.SecurityException System.UnauthorizedAccessException System.IO.IOException].each do |klass|
      assert_includes script, "catch [#{klass}]"
    end
    assert_includes script, '$_.Exception.GetType().FullName'
    assert_includes script, 'ConvertTo-Json -Compress'
  end

  def test_joined_and_maintenance_states_refuse_with_the_canonical_sentence
    [ForemanHyperv::Hyperv::CLUSAPI_RUNNING, ForemanHyperv::Hyperv::CLUSAPI_NOT_RUNNING].each do |state|
      fog = allow_standalone(GateFog.new)
      fog.service_out = service_tok(clusapi: clusapi_ok(0, state))
      cr, _fog, vm = build_cr(fog: fog)

      destroy_refused(cr, 'refused in code until FOG-10, PLG-15b and PLG-21b have merged')
      assert_empty vm.calls, "state #{state} refused before the machine was touched"
    end
  end

  def test_a_nonzero_return_code_is_always_indeterminate
    # The d23 cell: mid-removal, GetNodeClusterState answers rc=2. N2: rc≠0 is
    # never a feature-absent reading, whatever else says.
    fog = allow_standalone(GateFog.new)
    fog.service_out = service_tok(clusapi: clusapi_ok(2, 0), svc: leg('absent', ITEM_NOT_FOUND),
                                  cdir: leg('absent', ITEM_NOT_FOUND))
    cr, _fog, vm = build_cr(fog: fog)

    destroy_refused(cr, 'did not read as a stand-alone Hyper-V host')
    assert_empty vm.calls
  end

  def test_a_raising_pinvoke_is_indeterminate_never_feature_absent
    fog = allow_standalone(GateFog.new)
    fog.service_out = service_tok(clusapi: clusapi_error('System.DllNotFoundException'),
                                  svc: leg('absent', ITEM_NOT_FOUND),
                                  cdir: leg('absent', ITEM_NOT_FOUND))
    cr, _fog, vm = build_cr(fog: fog)

    destroy_refused(cr, 'did not read as a stand-alone Hyper-V host')
    assert_empty vm.calls
  end

  def test_state_one_is_standalone_only_with_the_service_record_present
    fog = allow_standalone(GateFog.new)
    fog.service_out = service_tok(clusapi: clusapi_ok(0, ForemanHyperv::Hyperv::CLUSAPI_NOT_CONFIGURED),
                                  svc: leg('absent', ITEM_NOT_FOUND))
    cr, _fog, vm = build_cr(fog: fog)

    # clusapi=1 with the record missing is a shape the plan names as
    # indeterminate, and it is not one of the measured cells either.
    destroy_refused(cr, 'did not read as a stand-alone Hyper-V host')
    assert_empty vm.calls
  end

  def test_state_zero_is_accepted_only_with_every_store_answered_gone
    absent_leg = leg('absent', ITEM_NOT_FOUND)
    fog = allow_standalone(GateFog.new)
    zero = clusapi_ok(0, ForemanHyperv::Hyperv::CLUSAPI_NO_CLUSTER_SERVICE)

    # d23g: state 0, service record absent, cluster directory absent (and both
    # markers absent, which allow_standalone already answers) — the broken node
    # accepted on argument.
    fog.service_out = service_tok(clusapi: zero, svc: absent_leg, cdir: absent_leg)
    cr, _fog, vm = build_cr(fog: fog)
    cr.destroy_vm(VM_GUID)
    assert_includes vm.calls, [:stop, { turn_off: true }]

    # ...but the acceptance dies on any other cdir answer, and on a present
    # service record: state 0 with a record is not a measured shape.
    [
      service_tok(clusapi: zero, svc: absent_leg, cdir: leg('present')),
      service_tok(clusapi: zero, svc: absent_leg, cdir: leg('denied', 'System.Security.SecurityException')),
      service_tok(clusapi: zero, svc: leg('present'), cdir: absent_leg),
      service_tok(clusapi: zero, svc: leg('unreadable', 'Other.Exception'), cdir: absent_leg)
    ].each_with_index do |out, index|
      fog.service_out = out
      cr2, _fog2, vm2 = build_cr(fog: fog)
      destroy_refused(cr2, 'did not read as a stand-alone Hyper-V host')
      assert_empty vm2.calls, "branch #{index}"
    end
  end

  def test_unknown_states_are_indeterminate
    [2, 5, 18, 20].each do |state|
      fog = allow_standalone(GateFog.new)
      fog.service_out = service_tok(clusapi: clusapi_ok(0, state))
      cr, _fog, vm = build_cr(fog: fog)

      destroy_refused(cr, 'did not read as a stand-alone Hyper-V host')
      assert_empty vm.calls
    end
  end

  def test_short_of_a_well_formed_service_token_is_always_indeterminate
    [
      ShellOut.new('', '', 0),                                    # fog's nil-on-empty-stdout shape
      ShellOut.new('Add-Type : boom', '', 0),                     # not JSON
      ShellOut.new('{"result":"absent"}', '', 0),                 # the marker shape, not this one
      ShellOut.new('{"clusapi":{"result":"ok","rc":0,"state":1},"svc":null,"cdir":null}', '', 0),
      RuntimeError.new('the WinRM receive died')                  # fog raising at all
    ].each_with_index do |out, index|
      fog = allow_standalone(GateFog.new)
      fog.service_out = out
      cr, _fog, vm = build_cr(fog: fog)

      destroy_refused(cr, 'did not read as a stand-alone Hyper-V host')
      assert_empty vm.calls, "branch #{index}"
    end
  end

  # --- N6: the self rung at destroy time -------------------------------------------------

  def test_a_machine_on_another_node_is_refused_by_the_self_rung
    fog = allow_standalone(GateFog.new)
    vm = VmDouble.new
    vm.computer_name = 'hv-node2.lab.maughmer.net'
    cr, _fog, vm = build_cr(fog: fog, vm: vm)

    destroy_refused(cr, 'other than this compute resource')
    assert_empty vm.calls, 'the self rung lands before anything is stopped or deleted'
  end

  def test_a_machine_without_a_computer_name_is_refused
    fog = allow_standalone(GateFog.new)
    vm = VmDouble.new
    vm.computer_name = nil
    cr, _fog, vm = build_cr(fog: fog, vm: vm)

    destroy_refused(cr, 'other than this compute resource')
    assert_empty vm.calls
  end

  def test_an_endpoint_that_cannot_name_itself_refuses_the_destroy
    fog = allow_standalone(GateFog.new)
    cr, _fog, vm = build_cr(fog: fog)
    cr.stubs(:hypervisor).raises(Fog::Hyperv::Errors::PSError.new(ShellOut.new('', 'gone', 1), 'Get-VMHost'))

    destroy_refused(cr, 'other than this compute resource')
    assert_empty vm.calls
  end

  # --- through the opened gate --------------------------------------------------------------

  def test_an_allowed_destroy_detaches_and_removes_the_vm_only
    fog = allow_standalone(GateFog.new)
    cr, fog, vm = build_cr(fog: fog)

    cr.destroy_vm(VM_GUID)

    assert_equal [VM_GUID], fog.servers_default.get_calls
    assert_includes vm.calls, [:stop, { turn_off: true }]
    assert_includes vm.calls, [:destroy, false]
    assert_not_includes vm.calls, [:destroy, true], 'the config folder is PLG-22’s to delete'
    vm.hard_drives.each do |hdd|
      assert_includes hdd.calls, [:destroy, false], 'the destroy detaches; it does not delete the VHDX'
      assert_not_includes hdd.calls, [:destroy, true]
    end
    assert_equal 3, fog.cmd_calls.size, 'both markers and the service-state read were asked'
    assert_empty fog.fog_calls_named(:remove_item, :remove_vm)
  end

  def test_a_machine_fog_cannot_find_is_the_same_nothing_as_not_found
    fog = allow_standalone(GateFog.new)
    cr, _fog, vm = build_cr(fog: fog)
    # After build_cr, because build_cr wires its own machine in: the fog now
    # answers no machine at all for any lookup.
    fog.servers_default = ServersDouble.new(nil)

    assert_equal true, cr.destroy_vm(VM_GUID)
    assert_empty vm.calls, 'nothing was touched: there was nothing to touch'
  end
end
