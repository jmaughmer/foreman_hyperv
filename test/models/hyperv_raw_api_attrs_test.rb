# frozen_string_literal: true

require 'test_helper'

# Vhd rides the plugin's size_bytes= but is loaded nowhere at boot: the
# engine requires the server/network_adapter/hard_drive models, fog resolves
# Vhd through the instantiated client's own model machinery, and this suite
# stubs the client — so it names the file the way the engine names the
# others (mirrors lib/foreman_hyperv/engine.rb).
require 'fog/hyperv/compute/models/vhd'

# PLG-58: the raw API's compute attributes say what they did.
#
# The forms and the raw API do not send the same hashes. The compute form
# (compute_resources_vms/form/hyperv/_base.html.erb) carries a firmware radio
# and NO Secure-Boot checkbox, so a form rider never submits
# secure_boot_enabled on its own — the boolean the write receives is the one
# generate_secure_boot_settings resolved from the firmware name. It also
# never submits a per-volume datastore. A raw API creator documents BOTH keys
# (core documents datastore on volumes_attributes, and this plugin gives the
# key meaning: validate_placement! checks its membership against the
# cluster's own shared-volume listing and placement_storage composes the
# placement from it) and sends them as STRINGS — the shape every console
# produces. Three measured defects sat on that path, all hit by the first
# Server-2022 clustered ride (host 8, hvcl02-ride1, 2026-11-27):
#
#   1. the create path hands the submitted flag straight to fog_extensions'
#      secure_boot_enabled=, which read its TRUTHINESS — and '0', the string
#      for "off", is truthy Ruby. The create seam had already cast the same
#      string with Foreman::Cast.to_bool and answered off, so a create that
#      asked for Secure Boot off passed the bootdisk seam, wrote
#      -EnableSecureBoot On, and met the ride gate's refusal minutes later
#      (ERF84-3870, measured with the request that produced it). The cast now
#      sits in the setter, the one choke point every caller passes through;
#      these tests pin '0'/'false'/false to :Off and '1'/'true'/true to :On,
#      and pin the seam and the live write answering ONE string the same way.
#
#   2. save_vm gated the write on foreman_firmware being present, so a bare
#      secure_boot_enabled PUT answered 200 and changed nothing (measured
#      twice: the update came back 200, the endpoint kept reading
#      uefi_secure_boot). The key's presence is now the request: a bare
#      secure_boot_enabled write reaches the endpoint, and the
#      foreman_firmware branch — whose merged boolean wins over a stale
#      companion flag, round 23's F3 truth — is pinned unchanged.
#
#   3. volumes_attributes datastore died in new_vm's volume assignment with
#      NoMethodError (undefined method `datastore=' for
#      Fog::Hyperv::Compute::HardDrive — measured traceback, request
#      6bf7e44d) before placement was ever asked. The accessor on the
#      plugin's HardDrive extension makes the assignment survive; the value
#      is answered from the request hash, and fog never persists the key —
#      it is not a declared fog attribute, so it stays out of every request
#      the model composes (the iso_upload_storage pattern on Server).
class HypervRawApiAttrsTest < ActiveSupport::TestCase
  HOST = 'hv-node1'
  VOL1 = 'C:\ClusterStorage\Volume1'
  VOL2 = 'C:\ClusterStorage\Volume2'
  CR_URL = "http://#{HOST}:5985/wsman".freeze
  UUID = '7e5cfebe-e6f1-4923-bb32-7e471ed58a69'

  # The firmware collection exactly as the Server writer drives it: records
  # the verb it is given and counts the saves, so a test can tell a write
  # that reached the endpoint (Set-VMFirmware) from one that never left.
  class FirmwareRec
    attr_accessor :secure_boot
    attr_reader :saves

    def initialize(state = :On)
      @secure_boot = state
      @saves = 0
    end

    def save
      @saves += 1
    end
  end

  # A machine built the way fog's servers.new builds one — with the plugin's
  # REAL fog extension prepended, so the tests exercise the shipped writer
  # rather than a stub of it. Gen-2 like every machine the firmware apply
  # resolves today; the host answers Secure Boot ON for a fresh Gen-2
  # machine (measured), which is where the recorder starts; create()
  # persists exactly as fog's does.
  class RawApiVm
    prepend FogExtensions::Hyperv::Server

    attr_reader :new_attributes, :generation, :firmware, :create_kwargs
    attr_accessor :network_adapters, :hard_drives, :id, :notes, :processor_count,
                  :dynamic_memory_enabled, :memory_minimum, :memory_maximum, :placement_path

    def initialize(attributes = {}, persisted: false, firmware: :On)
      @new_attributes = (attributes || {}).dup
      # fog's declared hypervenum coerces the request's 1/2 to BIOS/UEFI at
      # construction; the double answers the same way.
      @generation = @new_attributes[:generation].to_i == 1 ? :BIOS : :UEFI
      @firmware = FirmwareRec.new(firmware)
      @persisted = persisted
    end

    def name
      @new_attributes[:name]
    end

    def computer_name
      @new_attributes[:computer_name]
    end

    def service
      nil
    end

    def persisted?
      @persisted
    end

    def dirty?
      false
    end

    def create(**attrs)
      @create_kwargs = attrs
      @persisted = true
    end

    def start; end
  end

  class RawApiServers
    attr_reader :built

    def new(attributes = nil)
      @built = RawApiVm.new(attributes)
    end
  end

  class RawApiInterfaces
    def new(attributes = nil)
      Fog::Hyperv::Compute::NetworkAdapter.new(attributes)
    end
  end

  class RawApiFog
    attr_reader :servers

    def initialize
      @servers = RawApiServers.new
    end

    # vm_instance_defaults asks it, exactly as the real client answers.
    def interfaces
      @interfaces ||= RawApiInterfaces.new
    end
  end

  def build_cr(fog: RawApiFog.new)
    cr = ForemanHyperv::Hyperv.new(name: 'lab-cr', url: CR_URL, user: 'u', password: 'p')
    cr.stubs(:client).returns(fog)
    cr.stubs(:hypervisor).returns(stub('hypervisor', name: HOST, virtual_machine_path: 'C:\VMs'))
    cr.stubs(:test_connection)
    cr.stubs(:validate_interfaces)
    cr.stubs(:validate_volumes)
    cr.stubs(:validate_placement!)
    cr.stubs(:create_interfaces)
    cr.stubs(:create_volumes)
    cr.stubs(:update_interfaces)
    cr.stubs(:update_volumes)
    [cr, fog]
  end

  # Stand-alone create args carrying the raw-API flags: strings exactly as a
  # console sends them, no foreman_firmware — the shape the 2026-11-27 ride
  # created with.
  def raw_create_attrs(extra = {})
    { name: 'plg58-row', start: '0', generation: 2,
      memory_startup: '512', memory_minimum: '0', memory_maximum: '0',
      processor_count: '1', dynamic_memory_enabled: '0' }.merge(extra)
  end

  def standalone_create(cr)
    cr.stubs(:enablement_supported?).returns(true)
    cr.stubs(:create_allowed?).returns(true)
    cr.stubs(:cluster_named).returns(nil)
    cr.stubs(:placement_storage).returns(nil)
  end

  # ---- 1. the Secure-Boot writer casts the submitted flag ------------------

  def test_a_string_zero_turns_secure_boot_off_through_the_shipped_writer
    vm = RawApiVm.new({ generation: 2 }, persisted: true)

    vm.secure_boot_enabled = '0'

    assert_equal :Off, vm.firmware.secure_boot,
                 "'0' is the string a console sends for off; truthiness called it On and the " \
                 'endpoint booted Secure Boot on a machine that asked out of it (measured 2026-11-27)'
    assert_equal 1, vm.firmware.saves, 'the cast verb still rides the same single Set-VMFirmware save'
    assert_not vm.secure_boot_enabled, 'the getter reads the machine back off'
  end

  def test_every_spelling_of_the_flag_lands_where_its_cast_lands
    { '0' => :Off, 'false' => :Off, false => :Off, nil => :Off,
      '1' => :On, 'true' => :On, true => :On }.each do |submitted, verb|
      vm = RawApiVm.new({ generation: 2 }, persisted: true)
      vm.secure_boot_enabled = submitted
      assert_equal verb, vm.firmware.secure_boot, "#{submitted.inspect} must write #{verb}"
      assert_equal 1, vm.firmware.saves, "#{submitted.inspect} must reach the endpoint once"
    end
  end

  def test_the_seam_and_the_live_write_answer_one_string_the_same_way
    cr, = build_cr
    vm = RawApiVm.new({ generation: 2 }, persisted: true)

    # The bootdisk create seam's question and the endpoint's verb, on the
    # same value: the ride-era split (seam off, endpoint On) is the bug.
    assert_not cr.send(:hyperv_secure_boot_resolved?, { secure_boot_enabled: '0', firmware: 'efi' }),
               'the seam casts: 0 means off'
    vm.secure_boot_enabled = '0'
    assert_equal :Off, vm.firmware.secure_boot,
                 'and the write says the same thing the seam said — one string, one answer'

    assert cr.send(:hyperv_secure_boot_resolved?, { secure_boot_enabled: '1', firmware: 'efi' })
    other = RawApiVm.new({ generation: 2 }, persisted: true)
    other.secure_boot_enabled = '1'
    assert_equal :On, other.firmware.secure_boot
  end

  def test_the_writer_still_moves_nothing_on_a_bios_or_unborn_machine
    # The doubles' firmware recorders start UNSpawned (nil) here, unlike the
    # ride-shaped doubles elsewhere: nil-vs-written is what proves the
    # guard, and saves==0 is the silent-no-op-proof pin beside it.
    bios = RawApiVm.new({ generation: 1 }, persisted: true, firmware: nil)
    bios.secure_boot_enabled = '1'
    assert_nil bios.firmware.secure_boot,
               'Secure Boot is a UEFI setting: a BIOS machine is not touched'
    assert_equal 0, bios.firmware.saves

    unborn = RawApiVm.new({ generation: 2 }, persisted: false, firmware: nil)
    unborn.secure_boot_enabled = '0'
    assert_nil unborn.firmware.secure_boot,
               'a model the host has not answered yet has nothing to write to'
    assert_equal 0, unborn.firmware.saves
  end

  # ---- 2. the create path rides the flag to the endpoint --------------------

  def test_a_raw_create_asking_for_secure_boot_off_writes_off
    fog = RawApiFog.new
    cr, = build_cr(fog: fog)
    standalone_create(cr)

    vm = cr.create_vm(raw_create_attrs(secure_boot_enabled: '0'))

    assert_equal :UEFI, vm.generation, 'the double rode the create as a Gen-2 machine'
    assert_equal :Off, vm.firmware.secure_boot,
                 'the create handed the setter the raw 0; the setter casts it — the endpoint ' \
                 'verb for a create that asked out of Secure Boot is EnableSecureBoot Off'
    assert_equal 1, vm.firmware.saves
  end

  # ---- 3. a bare secure_boot_enabled edit writes ---------------------------

  def save_attrs(vm, extra = {})
    { vm: vm, memory_startup: 2_147_483_648, memory_minimum: 1_073_741_824,
      memory_maximum: 4_294_967_296, processor_count: 2, dynamic_memory_enabled: '0' }.merge(extra)
  end

  def call_save_vm(cr, vm_attrs)
    cr.stubs(:find_vm_by_uuid).returns(vm_attrs[:vm])
    cr.save_vm(UUID, vm_attrs.except(:vm))
  end

  def test_a_bare_secure_boot_edit_reaches_the_endpoint
    vm = RawApiVm.new({ generation: 2 }, persisted: true)
    cr, = build_cr

    call_save_vm(cr, save_attrs(vm, secure_boot_enabled: '0'))

    assert_equal :Off, vm.firmware.secure_boot,
                 'the old gate required the form firmware selector, so a bare flag answered ' \
                 '200 and wrote nothing (measured twice 2026-11-27); the key is the request now'
    assert_equal 1, vm.firmware.saves
  end

  def test_an_explicit_null_names_off_through_the_same_door
    vm = RawApiVm.new({ generation: 2 }, persisted: true, firmware: nil)
    cr, = build_cr

    call_save_vm(cr, save_attrs(vm, secure_boot_enabled: nil))

    assert_equal :Off, vm.firmware.secure_boot,
                 'the key is present and its value casts off — the shared reading, pinned on ' \
                 'the save path beside the setter matrix'
    assert_equal 1, vm.firmware.saves
  end

  def test_automatic_firmware_resolves_through_the_pxe_loader_before_the_flag_is_read
    # The 'automatic' selector value, both resolutions: on an EFI-resolving
    # PXE loader the firmware resolves BEFORE generate_secure_boot_settings
    # is asked, so a merged boolean decides and a stale companion flag loses;
    # with nothing to resolve from no settings generate, the submitted flag
    # stands, and the cast is what reads it.
    extra = { foreman_firmware: 'automatic', firmware_type: 'efi', secure_boot_enabled: '1' }
    efi = RawApiVm.new({ generation: 2 }, persisted: true)
    cr, = build_cr
    call_save_vm(cr, save_attrs(efi, extra))
    assert_equal :Off, efi.firmware.secure_boot,
                 'automatic on an EFI loader resolves to plain UEFI; the stale On flag loses'
    assert_equal 1, efi.firmware.saves

    no_loader = { foreman_firmware: 'automatic', secure_boot_enabled: '0' }
    plain = RawApiVm.new({ generation: 2 }, persisted: true, firmware: nil)
    cr2, = build_cr
    call_save_vm(cr2, save_attrs(plain, no_loader))
    assert_equal :Off, plain.firmware.secure_boot,
                 'automatic with nothing to resolve generates no settings: the flag stands, ' \
                 'and the cast reads it off'
    assert_equal 1, plain.firmware.saves
  end

  def test_an_edit_without_the_flag_writes_no_firmware_at_all
    vm = RawApiVm.new({ generation: 2 }, persisted: true)
    cr, = build_cr

    call_save_vm(cr, save_attrs(vm))

    assert_equal :On, vm.firmware.secure_boot,
                 'an edit that names no Secure Boot leaves the machine alone'
    assert_equal 0, vm.firmware.saves
  end

  def test_the_firmware_selector_path_still_decides_secure_boot
    # The form path, byte-unchanged: the merged boolean from the firmware
    # name wins over any stale companion flag (round 23's F3), so a
    # plain-UEFI edit turns Secure Boot off even carrying the stale On flag,
    # and the Secure-Boot flavour turns it on even carrying the stale off one.
    plain = RawApiVm.new({ generation: 2 }, persisted: true)
    cr, = build_cr
    call_save_vm(cr, save_attrs(plain, foreman_firmware: 'uefi', secure_boot_enabled: '1'))
    assert_equal :Off, plain.firmware.secure_boot, 'the selector says plain UEFI; the stale flag loses'
    assert_equal 1, plain.firmware.saves

    booted = RawApiVm.new({ generation: 2 }, persisted: true)
    cr2, = build_cr
    call_save_vm(cr2, save_attrs(booted, foreman_firmware: 'uefi_secure_boot', secure_boot_enabled: '0'))
    assert_equal :On, booted.firmware.secure_boot, 'the selector says Secure Boot; the stale flag loses'
    assert_equal 1, booted.firmware.saves
  end

  # ---- 4. the documented datastore key survives assignment ------------------

  def test_new_vm_survives_the_datastore_key_and_the_volume_carries_it
    fog = RawApiFog.new
    cr, = build_cr(fog: fog)

    vm = cr.new_vm(raw_create_attrs(
                     volumes_attributes: { '0' => { name: 'disk0', size_bytes: '1073741824', datastore: VOL2 } }
                   ))

    disk = vm.hard_drives.first
    assert_equal VOL2, disk.datastore,
                 'the key died undefined-method before placement was ever asked (traceback ' \
                 '6bf7e44d); placement answers its volume from the request hash and the model ' \
                 'now simply carries what it was given'
  end

  def test_a_raw_create_carrying_the_datastore_and_string_flag_builds
    fog = RawApiFog.new
    cr, = build_cr(fog: fog)
    standalone_create(cr)

    vm = cr.create_vm(raw_create_attrs(
                        secure_boot_enabled: '0',
                        volumes_attributes: { '0' => { name: 'disk0', size_bytes: '1073741824', datastore: VOL2 } }
                      ))

    # create_vm builds through fog's whitelisted servers.new and hands the
    # volumes to create_volumes (stubbed here, pinned by the placement suite);
    # what this row pins is that the create that used to crash now BUILDS:
    # New-VM ran and the Secure-Boot verb rode the same request.
    assert_equal 'C:\VMs', vm.create_kwargs[:path]
    assert_equal :Off, vm.firmware.secure_boot
  end

  def test_the_accessor_rides_the_model_but_fog_never_persists_it
    disk = Fog::Hyperv::Compute::HardDrive.new
    disk.datastore = VOL1

    assert_equal VOL1, disk.datastore
    assert_not_includes Fog::Hyperv::Compute::HardDrive.attributes, :datastore,
                        'not a declared fog attribute: it stays out of every request the model composes'
    assert_not_includes disk.attributes.keys, :datastore, 'and out of the model own attributes hash'
  end
end
