# frozen_string_literal: true

require 'test_helper'
require 'active_support/test_case'

# PLG-15b + PLG-21b: the standalone create unlock. The create path answers
# stand-alone now — arm (a) must read not-clustered on the endpoint, BOTH
# configured markers (the ClusSvc PARAMS registry key and the cluster
# database file) must answer the not-found exception through a server-side
# typed try/catch token, and the machine's computer name must be the name the
# endpoint gives itself. Every unknown — a clustered row, a denied read, an
# unparsable token, an endpoint that cannot name itself — refuses, and the
# rollback on a deterministic failure detaches drives and Remove-VMs only:
# no file deletes, no folder deletes, no underlying store. These need a
# booted Foreman (compute resources are Active Record), so the file looks for
# the app around the plugin — the Foreman tree's rake test:plugins task, or a
# development install — and says so out loud where none exists, rather than
# pretending the tests ran.
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
# fog does not require winrm until a real client connects, and fog's winrm
# utilities are lazy too: the fault classes this suite scripts come from the
# winrm gem itself, so name the dependency the suite actually uses.
require 'winrm' if FOREMAN_BOOT || (defined?(Rails) && Rails.application)

# ActiveSupport::TestCase (not bare Minitest) because these cover model-level
# semantics with Active Record compute resources. The Rails/RefuteMethods
# preference for assert_not_* is honoured the same way the sister suites do
# it: assert_not aliased, assert_not_* from ActiveSupport proper.
class HypervStandaloneCreateTest < ActiveSupport::TestCase
  alias assert_not refute

  VM_NAME = 'plg15b-vm'
  VM_GUID = '94f8b7b0-2a1d-4a1d-9f2e-6c0f1d2e3a4b'
  HOST = 'hv-node1.lab.maughmer.net'

  # What fog's run_cmd hands back (the same three fields fog's own shell
  # return struct carries): the marker read answers in stdout.
  ShellOut = Struct.new(:stdout, :stderr, :exitcode)

  # The fog answers, shaped like one marker token. The not-found answer the
  # gate acts on carries the exact exception class row (v) will assert.
  ITEM_NOT_FOUND = 'System.Management.Automation.ItemNotFoundException'
  ABSENT = ShellOut.new(
    %({"result":"absent","type":"#{ITEM_NOT_FOUND}"}), '', 0
  ).freeze

  # The fog world of this suite: the two gate reads (run_wql, run_cmd) are
  # scripted and recorded, servers.new hands back the VmDouble, and anything
  # else would be a surprise the recorded fog_calls make visible as a failure.
  class GateFog
    attr_accessor :wql_rows, :wql_error, :params_out, :clusdb_out, :servers_default
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
      out = script.include?('ClusSvc') ? params_out : clusdb_out
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
      %i[servers].include?(name) || super
    end

    def fog_calls_named(*names)
      fog_calls.select { |(name, _args)| names.include?(name) }
    end
  end

  # fog's servers collection: records what the create asked the model to be.
  class ServersDouble
    attr_reader :new_calls

    def initialize(vm)
      @vm = vm
      @new_calls = []
    end

    def new(attributes = nil)
      @new_calls << attributes
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

  # The machine fog's servers.new builds: enough of the Server interface for
  # create_vm, with every lifecycle step recorded — including the underlying
  # argument the rollback must never set true.
  class VmDouble
    attr_accessor :id, :name, :computer_name, :path, :generation
    attr_reader :calls

    def initialize
      @id = VM_GUID
      @name = VM_NAME
      @computer_name = HOST
      @path = "C:\\VMs\\#{VM_NAME}"
      @generation = :BIOS
      @calls = []
      @persisted = false
      @hard_drives = [HddDouble.new, HddDouble.new]
    end

    def create(*args)
      @calls << [:create, args]
      @persisted = true
    end

    def persisted?
      @persisted
    end

    def start
      @calls << :start
    end

    def stop(**_kwargs)
      @calls << :stop
    end

    def destroy(underlying = nil)
      @calls << [:destroy, underlying]
    end

    def hard_drives
      @calls << :hard_drives
      @hard_drives
    end

    def placement_path=(value)
      @calls << [:placement_path=, value]
    end
  end

  class LogRecorder
    attr_reader :warnings, :errors

    def initialize
      @warnings = []
      @errors = []
    end

    def warn(message)
      @warnings << message.to_s
    end

    def error(message)
      @errors << message.to_s
    end

    def info(message); end

    def debug(message); end
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

  # The ledger rows can only be asserted where the plugin migration has run;
  # the suite says so out loud instead of pretending the insert was checked.
  def sightings_table?
    return @sightings_table unless @sightings_table.nil?

    @sightings_table = begin
      ActiveRecord::Base.connection.table_exists?('foreman_hyperv_cluster_sightings')
    rescue ActiveRecord::ActiveRecordError
      false
    end
  end

  # A CR whose gate is fully live: nothing between create_vm and the fog
  # double is stubbed except the form-path validations (pinned by the PLG-15
  # suite) and the name the endpoint gives itself. The hypervisor name differs
  # in case from the machine's computer name on purpose: the self rung is
  # case-insensitive, and every green create in this file proves it.
  def build_cr(fog: GateFog.new, vm: VmDouble.new, host_name: HOST.upcase, url: "http://#{HOST}:5985/wsman")
    fog.servers_default = ServersDouble.new(vm)
    cr = ForemanHyperv::Hyperv.new(name: 'lab-cr', url: url, user: 'u', password: 'p')
    cr.stubs(:client).returns(fog)
    cr.stubs(:hypervisor).returns(stub('hypervisor', name: host_name, virtual_machine_path: 'C:\\VMs'))
    cr.stubs(:validate_interfaces)
    cr.stubs(:validate_volumes)
    cr.stubs(:create_interfaces)
    cr.stubs(:create_volumes)
    [cr, fog, vm]
  end

  def tok(result, type = nil)
    type_json = type ? "\"#{type}\"" : 'null'
    ShellOut.new(%({"result":"#{result}","type":#{type_json}}), '', 0)
  end

  def create_attrs(extra = {})
    {
      name: VM_NAME,
      start: '0',
      generation: 2,
      memory_startup: '1024',
      processor_count: '1',
      dynamic_memory_enabled: '0',
      notes: 'plg15b gate tests'
    }.merge(extra)
  end

  # The fog answers of a clean stand-alone host: no membership rows (the 1359
  # fault the measured not-joined machine raises) and both markers answering
  # the not-found exception.
  def allow_standalone(fog)
    fog.wql_error = WinRM::WinRMWSManFault.new(
      'WSMan Fault: [WSMAN ERROR CODE: 1359]', ForemanHyperv::Hyperv::WIRE_CODE_CLUSTER_UNAVAILABLE
    )
    fog.params_out = ABSENT
    fog.clusdb_out = ABSENT
    fog
  end

  # --- arm (a): the classifier --------------------------------------------------

  def test_arm_a_pins_the_query_string_and_the_namespace
    cr, fog, _vm = build_cr(fog: allow_standalone(GateFog.new))

    assert cr.send(:create_allowed?)
    assert_equal [['SELECT Name FROM MSCluster_Cluster', 'root/mscluster']], fog.wql_calls,
                 'arm (a) is exactly the reviewed query on the reviewed namespace, fog appending the /* itself'
  end

  def test_a_cluster_row_refuses_and_appends_the_sighting
    skip 'the sightings table has not been migrated in this test database' unless sightings_table?
    fog = GateFog.new
    fog.wql_rows = { name: 'hv-cluster' }
    fog.params_out = tok('absent')
    fog.clusdb_out = tok('absent')
    cr, _fog, _vm = build_cr(fog: fog)

    before = ForemanHyperv::ClusterSighting.count
    assert_not cr.send(:create_allowed?)
    assert_equal before + 1, ForemanHyperv::ClusterSighting.count, 'every cluster-row sighting appends'
    row = ForemanHyperv::ClusterSighting.order(:id).last
    assert_equal 'sighting', row.kind
    assert_equal HOST, row.endpoint_host, 'the ledger stores the endpoint host normalized'
    assert_equal 'hv-cluster', row.cluster_name
    assert_empty fog.cmd_calls, 'a clustered reading is refused before any marker is asked'
  end

  def test_the_feature_absent_wire_code_reads_as_not_clustered
    fog = allow_standalone(GateFog.new)
    fog.wql_error = WinRM::WinRMWMIError.new(
      'Invalid class', ForemanHyperv::Hyperv::WIRE_CODE_FEATURE_ABSENT
    )
    cr, _fog, _vm = build_cr(fog: fog)

    assert cr.send(:create_allowed?)
  end

  def test_other_wire_codes_and_other_error_classes_are_indeterminate
    fog = allow_standalone(GateFog.new)
    cr, _fog, _vm = build_cr(fog: fog)

    [
      WinRM::WinRMWSManFault.new('other fault', 1358),
      WinRM::WinRMWMIError.new('Invalid class', 2_150_858_799),
      WinRM::WinRMAuthorizationError.new,
      EOFError.new('the WinRM receive died')
    ].each do |error|
      fog.wql_error = error
      assert_not cr.send(:create_allowed?), "#{error.class} says nothing about membership"
      assert_empty fog.cmd_calls, 'an unreadable classifier is refused before the markers'
    end
  end

  # The PSError chain: the same 1359 answer arriving one layer up, as a fog
  # command failure whose captured streams quote the wire code, is the same
  # reading. A PSError that quotes neither code is not.
  def test_pserror_streams_carrying_a_wire_code_read_as_not_clustered
    fog = allow_standalone(GateFog.new)
    fog.wql_error = nil
    fog.wql_rows = nil
    cr, _fog, _vm = build_cr(fog: fog)

    with_code = Fog::Hyperv::Errors::PSError.new(
      ShellOut.new('', 'Get-WmiObject : [WSMAN ERROR CODE: 1359]: the RPC server is unavailable', 1),
      'When executing Get-WmiObject'
    )
    assert cr.send(:arm_a_consistent_wire_error?, with_code)

    without_code = Fog::Hyperv::Errors::PSError.new(
      ShellOut.new('', 'Get-WmiObject : Access denied', 1), 'When executing Get-WmiObject'
    )
    assert_not cr.send(:arm_a_consistent_wire_error?, without_code)
  end

  def test_a_provider_answering_rows_without_a_name_is_indeterminate
    fog = allow_standalone(GateFog.new)
    fog.wql_error = nil
    fog.wql_rows = { name: '' }
    cr, _fog, _vm = build_cr(fog: fog)

    assert_not cr.send(:create_allowed?)
  end

  # --- B2: the dual-marker read ---------------------------------------------------

  def test_marker_scripts_name_the_open_read_primitives_and_the_full_exception_classes
    cr, _fog, _vm = build_cr

    registry = cr.send(:marker_read_script, :params_registry)
    clusdb = cr.send(:marker_read_script, :clusdb_file)

    # Two halves of the one contiguous wire string (a whole-line assert would
    # cross RuboCop's line length; together these pin it end to end).
    assert_includes registry, "Get-ItemProperty -LiteralPath 'HKLM:\\SYSTEM\\CurrentControlSet"
    assert_includes registry, "\\Services\\ClusSvc\\Parameters' -ErrorAction Stop"
    assert_includes clusdb, "Get-Content -LiteralPath 'C:\\Windows\\Cluster\\CLUSDB' -TotalCount 1 -ErrorAction Stop"
    assert_not_includes registry, '-TotalCount', 'the registry read has no content count'
    [registry, clusdb].each do |script|
      assert_not_includes script, 'Test-Path', 'the named primitive is an open/read, never an existence check'
      assert_includes script, 'catch [System.Management.Automation.ItemNotFoundException]',
                      'the only absent branch is the not-found exception'
      assert_includes script, 'catch [System.Security.SecurityException]'
      assert_includes script, 'catch [System.UnauthorizedAccessException]'
      assert_includes script, 'catch [System.IO.IOException]'
      assert_includes script, '$_.Exception.GetType().FullName',
                      'the full exception class name rides every token for the row-(v) assertions'
      assert_includes script, 'ConvertTo-Json -Compress'
    end
  end

  # result → expected gate answer; a lone marker read is checked directly so
  # the token branches are pinned without the whole create path.
  MARKER_TOKEN_BRANCHES = {
    'present' => :present,
    'absent' => :absent,
    'denied' => :indeterminate,
    'unreadable' => :indeterminate
  }.freeze

  def test_every_marker_token_branch_reads_as_expected
    cr, fog, _vm = build_cr
    MARKER_TOKEN_BRANCHES.each do |result, expected|
      fog.params_out = tok(result, 'Some.Exception')
      assert_equal expected, cr.send(:marker_state, :params_registry)
    end
  end

  def test_short_of_a_well_formed_token_is_always_indeterminate
    cr, fog, _vm = build_cr

    [
      ShellOut.new('', '', 0),                                     # fog's nil-on-empty-stdout shape
      ShellOut.new('   ', '', 0),                                  # whitespace is not an answer either
      ShellOut.new('Get-Content : boom', '', 0),                   # not JSON
      ShellOut.new('{"result":null,"type":null}', '', 0),          # JSON with no answer in it
      RuntimeError.new('the WinRM receive timed out with partial stdout') # fog raising at all
    ].each_with_index do |out, index|
      fog.params_out = out
      assert_equal :indeterminate, cr.send(:marker_state, :params_registry), "branch #{index}"
    end
  end

  def test_the_gate_needs_both_markers_absent_and_acts_on_nothing_else
    absent = ABSENT
    present = tok('present')
    denied = tok('denied', 'System.Security.SecurityException')

    fog = allow_standalone(GateFog.new)
    cr, _fog, _vm = build_cr(fog: fog)
    assert cr.send(:create_allowed?), 'both absent opens the gate'

    fog.clusdb_out = present
    assert_not cr.send(:create_allowed?), 'a concordant not-clustered classifier does not outrank a present marker'

    fog.clusdb_out = denied
    assert_not cr.send(:create_allowed?), 'a denied read is not an absent read'

    fog.clusdb_out = absent
    fog.params_out = present
    assert_not cr.send(:create_allowed?), 'the same holds mirrored on the registry marker'
  end

  # --- N6: the self rung -----------------------------------------------------------

  def test_a_target_that_is_not_the_endpoint_itself_is_refused_before_anything_is_sent
    fog = allow_standalone(GateFog.new)
    vm = VmDouble.new
    vm.computer_name = 'hv-node2.lab.maughmer.net'
    cr, _fog, vm = build_cr(fog: fog, vm: vm)

    error = assert_raises(ForemanHyperv::OperationRefused) { cr.create_vm(create_attrs) }
    assert_includes error.message, 'did not match the machine'
    assert_not_includes vm.calls.map { |call| call.is_a?(Array) ? call.first : call }, :create,
                        'the self rung lands before vm.create: servers.new sent nothing'
  end

  def test_a_machine_without_a_computer_name_is_refused
    fog = allow_standalone(GateFog.new)
    vm = VmDouble.new
    vm.computer_name = nil
    cr, _fog, _vm = build_cr(fog: fog, vm: vm)

    assert_raises(ForemanHyperv::OperationRefused) { cr.create_vm(create_attrs) }
  end

  def test_an_endpoint_that_cannot_name_itself_is_refused
    fog = allow_standalone(GateFog.new)
    cr, _fog, vm = build_cr(fog: fog)
    cr.stubs(:hypervisor).raises(Fog::Hyperv::Errors::PSError.new(ShellOut.new('', 'gone', 1), 'Get-VMHost'))

    # computer_name is carried in the attrs so the only hypervisor read on
    # the path is the self rung's — and the one the endpoint cannot answer.
    error = assert_raises(ForemanHyperv::OperationRefused) do
      cr.create_vm(create_attrs(computer_name: vm.computer_name))
    end
    assert_includes error.message, 'other than this compute resource'
    assert_not_includes vm.calls.map { |call| call.is_a?(Array) ? call.first : call }, :create
  end

  # --- create_vm through the opened gate --------------------------------------------

  def test_a_standalone_create_runs_and_the_start_is_honored
    fog = allow_standalone(GateFog.new)
    cr, fog, vm = build_cr(fog: fog)

    result = cr.create_vm(create_attrs(start: '1'))

    assert_same vm, result
    assert_equal 1, fog.servers.new_calls.size
    assert_equal VM_NAME, fog.servers.new_calls.first[:name]
    assert_includes vm.calls, :start
    assert(vm.calls.any? { |call| call.is_a?(Array) && call.first == :create }, 'the machine was created')
    assert_equal 2, fog.cmd_calls.size, 'both markers were read'
    assert_empty fog.fog_calls_named(:remove_item, :remove_vm), 'nothing destructive went out'
  end

  # N4/rollback: a deterministic failure after the machine exists still rolls
  # back — but scoped to this transaction's own fog objects. Drives detach
  # (underlying: false); the machine is Remove-VM'd without its store
  # (destroy(false)); the folder and file deletes stay refused territory.
  def test_rollback_detaches_drives_and_removes_the_vm_without_underlying_deletes
    fog = allow_standalone(GateFog.new)
    cr, _fog, vm = build_cr(fog: fog)
    boom = RuntimeError.new('the volume create failed')
    cr.stubs(:create_volumes).raises(boom)

    error = assert_raises(RuntimeError) { cr.create_vm(create_attrs) }
    assert_same boom, error

    assert_includes vm.calls, :stop
    assert_includes vm.calls, [:destroy, false]
    assert_not_includes vm.calls, [:destroy, true], 'the underlying store is never deleted by a rollback'
    vm.hard_drives.each do |hdd|
      assert_includes hdd.calls, [:destroy, false], 'a rollback detaches; it does not delete the VHDX'
      assert_not_includes hdd.calls, [:destroy, true]
    end
  end

  def test_a_cluster_create_is_refused_before_anything_is_asked
    fog = GateFog.new
    cr, _fog, _vm = build_cr(fog: fog)

    error = assert_raises(ForemanHyperv::OperationRefused) do
      cr.create_vm(create_attrs(cluster_name: 'hv-cluster'))
    end
    assert_includes error.message, 'refused in code until FOG-10, PLG-15b and PLG-21b have merged'
    assert_empty fog.wql_calls
    assert_empty fog.cmd_calls
    assert_empty fog.fog_calls, 'the cluster create refusal lands before any fog call'
  end

  # --- B6: the ledger -------------------------------------------------------------

  def test_a_sighting_recorded_without_a_parseable_endpoint_is_a_refusal
    fog = allow_standalone(GateFog.new)
    fog.wql_error = nil
    fog.wql_rows = { name: 'hv-cluster' }
    cr, _fog, _vm = build_cr(fog: fog, url: 'not a uri at all')

    error = assert_raises(ForemanHyperv::OperationRefused) { cr.send(:create_allowed?) }
    assert_includes error.message, 'the sightings record could not be written'
  end

  def test_the_strand_record_logs_even_when_the_ledger_cannot_take_the_row
    skip 'the sightings table has not been migrated in this test database' unless sightings_table?
    fog = allow_standalone(GateFog.new)
    cr, _fog, vm = build_cr(fog: fog)
    log = LogRecorder.new
    cr.stubs(:logger).returns(log)

    cr.send(:record_role_strand, vm, nil)
    assert(log.warnings.any? { |line| line.include?('cluster role strand') })

    strand_rows = ForemanHyperv::ClusterSighting.where(kind: 'strand', vm_uuid: VM_GUID)
    if strand_rows.exists?
      assert_equal 1, strand_rows.count
      assert_equal 'readback-empty', strand_rows.last.reason
    else
      # The table exists (the guard above) but the write failed: the contract
      # is that the raise still follows and the failed write is said out loud.
      assert(log.errors.any? { |line| line.include?('could not be written') })
    end
  end

  # --- the model: insert-only by construction ---------------------------------------

  def test_a_valid_sighting_inserts_once
    skip 'the sightings table has not been migrated in this test database' unless sightings_table?
    row = ForemanHyperv::ClusterSighting.create!(endpoint_host: HOST, kind: 'sighting', cluster_name: 'hv-cluster')

    assert row.persisted?
    # A sighting that could be rewritten is not a sighting, and one that
    # could be deleted could erase a cluster for a later destroy.
    assert_raises(ActiveRecord::ActiveRecordError) { row.update!(cluster_name: 'rewritten') }
    assert_raises(ActiveRecord::ActiveRecordError) { row.destroy! }
    assert ForemanHyperv::ClusterSighting.exists?(row.id), 'the refused mutation left the row exactly as it was'
  end

  def test_the_model_refuses_hosts_that_are_not_normalized_and_kinds_it_does_not_know
    skip 'the sightings table has not been migrated in this test database' unless sightings_table?
    unnormalized = ForemanHyperv::ClusterSighting.new(endpoint_host: ' HV-Node1.Lab ', kind: 'sighting')
    assert_not unnormalized.valid?
    assert_includes unnormalized.errors[:endpoint_host].join, 'normalized',
                    'the ledger is read back by endpoint host, so the stored shape is fixed at write time'

    unknown_kind = ForemanHyperv::ClusterSighting.new(endpoint_host: HOST, kind: 'guess')
    assert_not unknown_kind.valid?
    assert_includes unknown_kind.errors.details[:kind].map { |detail| detail[:error] }, :inclusion
  end
end
