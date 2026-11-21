# frozen_string_literal: true

require 'test_helper'
require 'active_support/test_case'

# PLG-21a: the fog role write is indeterminate once it has been sent — even a
# successful Add answers with Fog::JSON::DecodeError at the pinned fog — so the
# plugin proves success by reading the role back, keyed on the machine's id, as
# a cluster read on the compute resource's own endpoint. Anything short of
# finding the role raises StrandIndeterminate, whose contract is that NOTHING
# is torn down: no stop, no disk deletes, no destroy, no role removal. These
# tests need a booted Foreman (compute resources are Active Record), so the
# file looks for the app around the plugin and says so out loud where none
# exists, rather than pretending the tests ran.
ENV['RAILS_ENV'] = 'test'
# The refusals file defines the same constant when the suites run in one
# process; only the first of them gets to.
unless defined?(FOREMAN_BOOT)
  FOREMAN_BOOT = [
    File.expand_path('../../config/environment.rb', __dir__),
    File.expand_path('../../../config/environment.rb', __dir__),
    File.expand_path('../../../../config/environment.rb', __dir__)
  ].find { |path| File.exist?(path) }
end
require FOREMAN_BOOT if FOREMAN_BOOT && !(defined?(Rails) && Rails.application)

require 'fog/hyperv' if FOREMAN_BOOT || (defined?(Rails) && Rails.application)

# ActiveSupport::TestCase (not bare Minitest) because these cover model-level
# semantics with Active Record compute resources. Rails/RefuteMethods in this
# repo's RuboCop prefers the assert_not_* family over refute_*: assert_not_includes
# ships with ActiveSupport itself, and bare assert_not ships with Foreman's test
# helper, so it is aliased here for the same reason the sister suite aliases it.
class HypervRoleReadbackTest < ActiveSupport::TestCase
  alias assert_not refute

  STRAND_GUID = '94f8b7b0-2a1d-4a1d-9f2e-6c0f1d2e3a4b'
  VM_NAME = 'plg21a-vm'

  # Records the fog client's calls. The Add and the role readback get scripted
  # behaviors; every other fog call lands in fog_calls, so a teardown call that
  # must not happen on an indeterminate create is visible as a failure.
  class FogDouble
    attr_accessor :add_behavior, :role_values, :role_error, :servers_default
    attr_reader :add_calls, :role_calls, :fog_calls

    def initialize
      @add_calls = []
      @role_calls = []
      @role_values = []
      @fog_calls = []
      @add_defined = false
    end

    # The plugin asks client.respond_to?(:add_cluster_virtual_machine_role)
    # before it sends; no respond_to? override is needed: define_add answers
    # true through the real singleton method, and respond_to_missing? answers
    # false for a fog that never got one.
    def define_add
      @add_defined = true
      fog = self
      singleton_class.define_method(:add_cluster_virtual_machine_role) do |**kwargs|
        fog.add_calls << kwargs
        fog.add_behavior&.call
        true
      end
    end

    def method_missing(name, *args)
      case name
      when :servers
        servers_default
      when :cluster_virtual_machine_roles
        self
      when :all
        role_calls << args.first
        raise role_error if role_error

        role_values
      else
        fog_calls << [name, args]
        nil
      end
    end

    def respond_to_missing?(name, include_all = false)
      %i[servers cluster_virtual_machine_roles all].include?(name) || super
    end

    # Any fog call that would take the machine apart. A strand answer must
    # leave this empty; the deterministic rollback is expected to use it.
    def teardown_calls
      fog_calls.select { |(name, _args)| name.to_s.match?(/destroy|remove|delete|stop|shutdown/) }
    end
  end

  # fog's servers collection: create_vm builds the machine through
  # client.servers.new(attributes), which hands back the unsaved Server — the
  # double answers with the VmDouble that records every lifecycle step after.
  # The attributes are recorded so the create can be pinned on what it
  # actually asked fog for.
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

  # The machine fog's servers.new builds: enough of the Server interface for
  # create_vm, with every lifecycle step recorded.
  class VmDouble
    attr_accessor :id, :name, :computer_name, :path, :generation
    attr_reader :calls

    def initialize
      @id = STRAND_GUID
      @name = VM_NAME
      @computer_name = 'hv-node1.lab.maughmer.net'
      @path = "C:\\ClusterVolume\\{#{VM_NAME}}"
      @generation = :BIOS
      @calls = []
      @persisted = false
    end

    def create(*_args)
      @calls << :create
      @persisted = true
    end

    def persisted?
      @persisted
    end

    def start
      @calls << :start
    end

    def stop
      @calls << :stop
    end

    def destroy(underlying = nil)
      @calls << [:destroy, underlying]
    end

    def hard_drives
      @calls << :hard_drives
      []
    end

    def placement_path=(value)
      @calls << [:placement_path=, value]
    end
  end

  # One fog role row, shaped like Fog's ClusterVirtualMachineRole model.
  RoleDouble = Struct.new(:virtual_machine_id, :name, :owner_node)

  # Captures the log lines the strand record is asserted on. The error sink
  # exists because PLG-21b's strand record also writes the sightings ledger,
  # and a database without that migration answered must surface as a logged
  # error, not as a crash of the touch-nothing contract.
  class LogRecorder
    attr_reader :warnings, :infos, :errors

    def initialize
      @warnings = []
      @infos = []
      @errors = []
    end

    def warn(message)
      @warnings << message.to_s
    end

    def info(message)
      @infos << message.to_s
    end

    def error(message)
      @errors << message.to_s
    end

    def debug(message); end
  end

  def setup
    unless FOREMAN_BOOT || (defined?(Rails) && Rails.application)
      skip 'Needs a booted Foreman (rake test:plugins): these cover model-level role semantics.'
    end
    begin
      require 'mocha/minitest'
    rescue LoadError
      skip 'mocha is not available outside the Foreman bundle.'
    end
  end

  # A compute resource whose whole fog world is the double, with the create
  # path's non-role steps stubbed out: NIC, volume and placement behaviour is
  # pinned by the PLG-15 suite, and this file is about the role write and its
  # readback. create_allowed? is stubbed true because PLG-15b keeps the gate
  # closed on the stand-alone reads this double cannot answer — and the
  # cluster create path stays refused until PLG-15c anyway — so only the
  # stub keeps these tests on the role-write contract itself; enablement is
  # not what they pin.
  def build_cr(fog: FogDouble.new, vm: VmDouble.new, log: LogRecorder.new, add_defined: true)
    fog.servers_default = ServersDouble.new(vm)
    fog.define_add if add_defined

    cr = ForemanHyperv::Hyperv.new(
      name: 'lab-cr', url: 'http://hv-node1.lab.maughmer.net:5985/wsman', user: 'u', password: 'p'
    )
    cr.stubs(:client).returns(fog)
    cr.stubs(:hypervisor).returns(
      stub('hypervisor', name: 'hv-node1.lab.maughmer.net', virtual_machine_path: 'C:\\VMs')
    )
    cr.stubs(:create_allowed?).returns(true)
    cr.stubs(:cluster_named).returns(stub('cluster'))
    cr.stubs(:placement_storage).returns(nil)
    cr.stubs(:validate_interfaces)
    cr.stubs(:validate_volumes)
    cr.stubs(:create_interfaces)
    cr.stubs(:create_volumes)
    cr.stubs(:sleep)
    cr.stubs(:logger).returns(log)
    [cr, fog, vm, log]
  end

  def create_attrs
    {
      name: VM_NAME,
      start: '1',
      generation: 2,
      memory_startup: '1024',
      processor_count: '1',
      dynamic_memory_enabled: '0',
      notes: 'plg21a readback tests'
    }
  end

  # --- the indeterminate class: fog raised after the send ---------------------

  # The measured fog behaviour: the Add SUCCEEDS remotely and raises
  # Fog::JSON::DecodeError on the empty reply. With the readbacks still not
  # finding the role the outcome is indeterminate — and nothing may be touched.
  def test_decode_error_with_empty_readback_leaves_everything_untouched
    fog = FogDouble.new
    fog.add_behavior = -> { raise Fog::JSON::DecodeError, "could not parse reply: %s and 'quoted' \e[31m" }
    cr, fog, vm, log = build_cr(fog: fog)

    error = assert_raises(ForemanHyperv::StrandIndeterminate) { cr.create_vm(create_attrs) }

    assert_equal 1, fog.add_calls.size, 'the Add must have been attempted once'
    assert_equal 3, fog.role_calls.size, 'three readback attempts before the outcome counts as unknown'
    fog.role_calls.each { |filters| assert_equal STRAND_GUID, filters[:vm_id] }

    assert_includes vm.calls, :create
    assert_not_includes vm.calls, :stop
    assert_not_includes vm.calls, :start
    assert_not vm.calls.any? { |call| call.is_a?(Array) && call.first == :destroy },
               'an indeterminate create must never destroy the machine'
    assert_not vm.calls.include?(:hard_drives), 'must not even enumerate drives to delete them'
    assert_empty fog.teardown_calls, 'no fog teardown call may reach the client on an indeterminate create'

    # The strand record: operator-visible, quoting the failure in safe text.
    strand_lines = log.warnings.grep(/cluster role strand/)
    assert_equal 1, strand_lines.size
    assert_includes strand_lines.first, STRAND_GUID
    assert_includes strand_lines.first, 'Fog::JSON::DecodeError'

    # Rendering must not raise: Foreman::Exception sprintfs its template with
    # these params at render time, so no percent may survive anywhere. Fog's own
    # text is quoted sanitized — percent tokens neutralised, control characters
    # removed, capped — and the words themselves stay readable for the operator,
    # which is what the design promises and what the log and the UI can carry
    # safely (this text is never interpolated into anything that executes).
    message = error.message
    assert_includes message, STRAND_GUID
    assert_includes message, 'Fog::JSON::DecodeError'
    assert_includes message, 'could not parse reply', 'the first line survives, sanitized'
    assert_not_includes message, '%'
    assert_not_includes message, "\e", 'terminal escapes must not reach the log line or the UI'
    assert_includes message, 'could not parse reply: s and',
                    'the percent token inside the quoted first line is neutralised, the text survives'
  end

  # N4: EVERY exception class after the send is indeterminate — transport
  # faults and timeouts with partial stdout included.
  def test_every_post_send_error_class_is_indeterminate
    [
      Fog::JSON::DecodeError.new('could not parse reply'),
      Fog::Hyperv::Errors::ServiceError.new('WSManFault: the WS-Management service cannot complete the operation'),
      Timeout::Error.new('WinRM receive timed out after 70s with partial stdout')
    ].each do |failure|
      fog = FogDouble.new
      fog.add_behavior = -> { raise failure }
      cr, fog, vm, _log = build_cr(fog: fog)

      strand = assert_raises(ForemanHyperv::StrandIndeterminate, "for #{failure.class}") do
        cr.create_vm(create_attrs)
      end
      assert_includes strand.message, failure.class.name
      assert_not_includes vm.calls, :stop
      assert_not(vm.calls.any? { |call| call.is_a?(Array) && call.first == :destroy })
      assert_empty fog.teardown_calls
      assert_equal 3, fog.role_calls.size
    end
  end

  # A readback that cannot answer is not an absent readback: the attempt is
  # spent and the outcome stays indeterminate. Nothing is touched here either.
  def test_raising_readback_is_indeterminate_and_touches_nothing
    fog = FogDouble.new
    fog.role_error = Fog::Hyperv::Errors::ServiceError.new('Get-ClusterVirtualMachineRole: 0x80070005')
    cr, fog, vm, log = build_cr(fog: fog)

    strand = assert_raises(ForemanHyperv::StrandIndeterminate) { cr.create_vm(create_attrs) }

    assert_equal 3, fog.role_calls.size
    assert_not vm.calls.include?(:stop)
    assert_empty fog.teardown_calls
    assert_includes strand.message, 'Fog::Hyperv::Errors::ServiceError'
    assert(log.warnings.any? { |line| line.include?('cluster role strand') })
  end

  # --- the proof: a readback that FINDS the role ------------------------------

  def test_role_found_by_id_proves_success_and_starts_the_machine
    fog = FogDouble.new
    fog.role_values = [RoleDouble.new(STRAND_GUID.upcase, "Virtual Machine #{VM_NAME}", 'hv-node2')]
    cr, fog, vm, log = build_cr(fog: fog)

    result = cr.create_vm(create_attrs)

    assert_same vm, result
    assert_equal 1, fog.servers.new_calls.size,
                 'the create must build its machine through the fog servers collection'
    assert_equal VM_NAME, fog.servers.new_calls.first[:name]
    assert_includes vm.calls, :start, 'a proven role must not strand the create before its start'
    assert_equal 1, fog.role_calls.size, 'the first proof ends the retries'
    assert_not(log.warnings.any? { |line| line.include?('cluster role strand') })
    assert_empty fog.teardown_calls
  end

  # The role's VM-id property is reported but undocumented, so a blank id with
  # the documented role name is the fallback proof.
  def test_role_found_by_name_when_id_property_is_blank_still_proves_success
    fog = FogDouble.new
    fog.role_values = [RoleDouble.new(nil, "virtual machine #{VM_NAME}", 'hv-node1')]
    cr, _fog, vm, _log = build_cr(fog: fog)

    assert_same vm, cr.create_vm(create_attrs)
    assert_includes vm.calls, :start
  end

  # A clean "absent" is also not a proof: the Add may simply not have committed
  # yet. It strands, it does not roll back (B3 pins exactly this shape).
  def test_silently_clean_absent_readback_strands_rather_than_rolls_back
    fog = FogDouble.new
    fog.role_values = []
    cr, fog, vm, log = build_cr(fog: fog)

    strand = assert_raises(ForemanHyperv::StrandIndeterminate) { cr.create_vm(create_attrs) }

    assert_equal 3, fog.role_calls.size
    assert_not vm.calls.include?(:stop)
    assert_empty fog.teardown_calls
    assert_includes strand.message, 'readback-empty'
    assert_not_includes strand.message, '%'
    assert(log.warnings.any? { |line| line.include?('readback-empty') })
  end

  # Somebody else's roles in the answer are an absent answer for us.
  def test_unrelated_roles_do_not_prove_anything
    fog = FogDouble.new
    fog.role_values = [
      RoleDouble.new('11b62f52-3c60-4b8e-a5d1-8f2b7c9d0e41', 'Virtual Machine other-vm', 'hv-node1'),
      RoleDouble.new(nil, 'Cluster Group', 'hv-node1')
    ]
    cr, fog, vm, _log = build_cr(fog: fog)

    assert_raises(ForemanHyperv::StrandIndeterminate) { cr.create_vm(create_attrs) }
    assert_equal 3, fog.role_calls.size
    assert_empty fog.teardown_calls
    assert_not vm.calls.include?(:stop)
  end

  # --- retry shape ------------------------------------------------------------

  def test_three_attempts_wait_the_reviewed_interval_between_them
    fog = FogDouble.new
    fog.role_values = []
    cr, _fog, _vm, _log = build_cr(fog: fog)

    # Exactly two waits for three attempts: none before the first read and
    # none after the last one condemns the create.
    cr.stubs(:sleep).with(ForemanHyperv::Hyperv::ROLE_READBACK_INTERVAL).times(2)

    assert_raises(ForemanHyperv::StrandIndeterminate) { cr.create_vm(create_attrs) }
  end

  # --- the deterministic pre-send path keeps its rollback ---------------------

  # fog too old to add roles raises BEFORE anything is sent: that failure is
  # deterministic, the machine certainly never joined, and the original
  # full-teardown rollback must survive PLG-21a's indeterminate rule.
  def test_pre_send_refusal_still_rolls_back_completely
    vm = VmDouble.new
    cr, _fog, _vm, _log = build_cr(vm: vm, add_defined: false)

    error = assert_raises(Foreman::Exception) { cr.create_vm(create_attrs) }
    assert_not error.is_a?(ForemanHyperv::StrandIndeterminate),
               'the deterministic pre-send refusal is not a strand'
    assert_includes vm.calls, :stop, 'deterministic failures keep rollback'
    assert(vm.calls.any? { |call| call.is_a?(Array) && call.first == :destroy },
           'deterministic failures keep rollback')
  end

  # The refusal classes must survive the rescue lists they were placed outside
  # of: an indeterminate create may never be folded into a reported success.
  def test_strand_class_sits_outside_the_folding_rescues
    assert_operator ForemanHyperv::StrandIndeterminate, :<, Foreman::Exception
    assert_not ForemanHyperv::StrandIndeterminate < ActiveRecord::RecordNotFound
    assert_not ForemanHyperv::StrandIndeterminate < Fog::Errors::NotFound
  end
end
