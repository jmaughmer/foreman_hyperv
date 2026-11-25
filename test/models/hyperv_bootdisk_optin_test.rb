# frozen_string_literal: true

require 'test_helper'
require 'active_support/test_case'

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

# bootdisk PR-5: the OPT-IN. Until this PR no host could even SAVE with
# provision_method 'bootdisk': Host::Managed#provision_method_in_capabilities
# (managed.rb:330, body :945-952) validates the chosen method against
# host.capabilities, and our compute resource answered only [:build]. This
# suite owns:
#
# (1) the :bootdisk word itself — appended AFTER :build, because core's
#     provision_method DEFAULT is capabilities.first (managed.rb:749), and
#     answered from static facts only, because the capability validation runs
#     on EVERY managed save — including /unattended/built — so a setting- or
#     endpoint-derived word strands in-flight hosts the moment an operator
#     flips it (plan round 7, blocking A). The precedent is foreman_bootdisk's
#     own proxmox ext, verbatim: `def capabilities; super + [:bootdisk]; end`.
#     The old-fog case needs NO gate here: the quartet's own PR-2 gates refuse
#     the ride with BOOTDISK_CAPABILITY_REFUSAL at build time — loud, and
#     never a validation that flaps.
# (2) the iso_upload_storage plumbing: foreman_bootdisk reads exactly
#     compute_attributes.dig(:iso_upload_storage) at orchestration time
#     (orchestration/compute.rb:76-78) and NOTHING in the gem writes it — the
#     input path is the API/hammer/console. So the key must PASS input
#     validation (the values are Windows volume paths; the default SAFE_TEXT
#     has no backslash, so TEXT_BY_KEY must pair it with SAFE_PATH, the exact
#     pattern datastore/path already use) and survive core's new_vm
#     mass-assign (FogExtensions::Hyperv::Server gains an attr_accessor — the
#     PLG-30/36 pattern; the create path is safe already because create_vm
#     builds servers.new from an explicit kwarg list).
# (3) Decision 5's create-time Secure-Boot refusal: the generated bootdisk ISO
#     boots through a shim this lab has NEVER booted under the default Gen2
#     MicrosoftWindows template (the acceptance VM ran with Secure Boot off),
#     so a bootdisk create that resolves to Secure Boot ON is refused before
#     any fog write — reading the CREATE ATTRS, because on a create there is
#     no VM to read (round 10, F9). The refusal sits after
#     apply_firmware_attributes so 'automatic' firmware is caught at its
#     RESOLVED value. (The live-machine half of this refusal rides
#     bootdisk_ride_check! and is pinned in hyperv_bootdisk_iso_test.rb.)
class HypervBootdiskOptinTest < ActiveSupport::TestCase
  UUID = '1c51c4ee-df90-4cee-a9f7-218888711248'
  CR_URL = 'https://hyperv.example.com:5985'

  def build_cr
    ForemanHyperv::Hyperv.new(name: 'lab-cr', url: CR_URL, user: 'u', password: 'p')
  end

  # ---- the :bootdisk word ------------------------------------------------------

  test 'capabilities answers [:build, :bootdisk]: the opt-in word APPENDED after the default' do
    cr = build_cr

    assert_equal [:build, :bootdisk], cr.capabilities,
                 'core defaults provision_method to capabilities.first (managed.rb:749) — putting ' \
                 ':bootdisk first would silently move every host that never set a provision_method ' \
                 'onto the bootdisk flow'
  end

  test 'capabilities answers without touching the endpoint or any setting: the capability validation runs on every managed save' do
    cr = build_cr
    # The validation provision_method_in_capabilities runs on EVERY managed
    # save including /unattended/built; a capabilities that dialed the WinRM
    # endpoint would put the endpoint on that path, and a setting-derived word
    # would refuse in-flight hosts the moment an operator removed it (round 7
    # blocking A). Any client touch must therefore be a loud failure here.
    cr.stubs(:client).raises(RuntimeError, 'capabilities reached the endpoint')

    assert_equal [:build, :bootdisk], cr.capabilities
  end

  # ---- iso_upload_storage: validation + fog mass-assign ------------------------

  test 'iso_upload_storage answers SAFE_PATH: a real Windows volume path passes where the default SAFE_TEXT refused' do
    # SAFE_TEXT (the TEXT_BY_KEY default) has no backslash — the value here is
    # C:\ClusterStorage\Volume1, so without the pair every honest value was
    # refused by validate_hash! (plan round 7, major C).
    ForemanHyperv::InputValidation.validate_hash!(
      { iso_upload_storage: 'C:\\ClusterStorage\\Volume1' }, context: :vm
    )
    ForemanHyperv::InputValidation.validate_hash!(
      { iso_upload_storage: '\\\\cluster.share\\volume' }, context: :vm
    )
  end

  test 'iso_upload_storage still refuses the shell metacharacters SAFE_PATH refuses elsewhere' do
    ['C:\\VMs"evil', 'C:\\VMs`x', 'C:\\VMs$x', 'C:\\VMs;x', 'C:\\VMs|x'].each do |value|
      assert_raises(ForemanHyperv::UnsafeIdentifier, "#{value.inspect} must not pass") do
        ForemanHyperv::InputValidation.validate_hash!({ iso_upload_storage: value }, context: :vm)
      end
    end
  end

  test 'the fog server model carries iso_upload_storage so core new_vm mass-assign survives it' do
    # Host.compute_attributes JSON is where foreman_bootdisk reads the key;
    # the key travels inside the hash core mass-assigns onto the fog model in
    # new_vm (core Host#vm / build-attribute rendering), and fog's
    # merge_attributes raises UnknownAttributeError for a key the model does
    # not know. The PLG-30/36 pattern: an accessor that exists so the form
    # value rides the model without fog ever persisting it.
    server = Fog::Hyperv::Compute::Server.new(iso_upload_storage: 'C:\\ClusterStorage\\Volume1')

    assert_equal 'C:\\ClusterStorage\\Volume1', server.iso_upload_storage
  end

  # ---- Decision 5: the create-time Secure-Boot refusal --------------------------

  # A create that gets past the refusal reaches build_client, which this stub
  # makes loud: the refusal must be decided BEFORE any fog model is built.
  def create_cr
    cr = build_cr
    cr.stubs(:enablement_supported?).returns(true)
    cr.stubs(:build_client).raises(RuntimeError, 'fog writes started: servers.new was reached')
    cr
  end

  def bootdisk_create_attrs(foreman_firmware: 'uefi_secure_boot', provision_method: 'bootdisk')
    {
      name: 'bd5.example.com',
      generation: 2,
      memory_startup: 1024,
      processor_count: 1,
      foreman_firmware: foreman_firmware,
      firmware_type: 'EFI',
      provision_method: provision_method,
      iso_upload_storage: 'C:\\ClusterStorage\\Volume1'
    }
  end

  test 'a bootdisk create that resolves to Secure Boot is refused before any fog write' do
    cr = create_cr

    error = assert_raises(ForemanHyperv::OperationRefused) { cr.create_vm(bootdisk_create_attrs) }

    assert_includes error.message, 'Secure Boot'
    assert_includes error.message, 'Nothing was created'
  end

  test 'the same create is NOT refused for provision_method build: Secure Boot stays the normal answer for every other flow' do
    cr = create_cr

    # The refusal keys on the bootdisk provision method ONLY — an ordinary
    # build host keeps its Secure Boot (its media is PXE/grub, a different
    # story the plan never touched).
    assert_raises(RuntimeError) { cr.create_vm(bootdisk_create_attrs(provision_method: 'build')) }
  end

  test 'the same create is NOT refused when the resolved firmware has Secure Boot off' do
    cr = create_cr

    assert_raises(RuntimeError) { cr.create_vm(bootdisk_create_attrs(foreman_firmware: 'uefi')) }
  end
end
