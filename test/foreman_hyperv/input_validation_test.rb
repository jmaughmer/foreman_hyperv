# frozen_string_literal: true

require 'test_helper'
require 'active_support/test_case'

# The two refusal classes live under app/ and autoload inside a booted Foreman
# app; the pure validator tests supply stand-ins when the app is not booted,
# so the module's decisions are pinned either way.
unless ForemanHyperv.const_defined?(:UnsafeIdentifier)
  ForemanHyperv.const_set(:UnsafeIdentifier, Class.new(StandardError))
  ForemanHyperv.const_set(:OperationRefused, Class.new(StandardError))
end

class InputValidationTest < ActiveSupport::TestCase
  # Foreman's own test helper ships assert_not; bare ActiveSupport stops at
  # assert_not_equal and the plugin's minimal helper ships neither, so this
  # one alias is owned here and the file runs in every one of those worlds.
  alias assert_not refute
  IV = ForemanHyperv::InputValidation

  # v4 GUID — the shape fog's own constant demands.
  GUID = '6cc7ff7b-2d34-4b52-8f97-5f0fef77e04e'

  # The red-test character set: quote, double-quote, subexpression, semicolon,
  # backtick, newline, and the provider wildcards.
  EVIL = [
    "x';whoami;'",
    'evil"quote',
    'x$(whoami)',
    'x;y',
    'x`y`',
    "x\n';whoami;'",
    'x[1]',
    'x]y',
    'x*y',
    'x?'
  ].freeze

  def test_guid_predicate_is_fogs_own_anchored_test
    assert IV.guid?(GUID)
    assert_not IV.guid?('some-vm-name')
    assert_not IV.guid?('')
    assert_not IV.guid?("#{GUID}\n';whoami;'")
    # A ^…$ anchor would let the newline case through; \A..\z does not.
    assert_raises(ForemanHyperv::UnsafeIdentifier) { IV.validate_id!("#{GUID}\n';whoami;'") }
    IV.validate_id!(GUID)
  end

  def test_ids_everywhere_must_be_guids
    assert_raises(ForemanHyperv::UnsafeIdentifier) { IV.validate_id!("a'b") }
    assert_raises(ForemanHyperv::UnsafeIdentifier) { IV.validate_id!('plain-name') }
    IV.validate_id!(GUID)

    assert_raises(ForemanHyperv::UnsafeIdentifier) { IV.validate_hash!({ vm_id: "a'b" }) }
    assert_raises(ForemanHyperv::UnsafeIdentifier) { IV.validate_hash!({ identity: 'name-not-id' }) }
    IV.validate_hash!({ vm_id: GUID, identity: GUID })

    # The nested device ids the forms round-trip stay legal when they are real.
    IV.validate_hash!({ volumes_attributes: { '0' => { id: GUID, _delete: '1' } } })
    assert_raises(ForemanHyperv::UnsafeIdentifier) do
      IV.validate_hash!({ volumes_attributes: { '0' => { id: "a'b" } } })
    end
  end

  def test_script_text_refused_in_every_text_field
    fields = [
      %i[vm name], %i[vm notes], %i[vm computer_name], %i[vm cluster_name],
      %i[nic name], %i[nic switch_name], %i[nic mac],
      %i[hdd basename], %i[hdd path], %i[hdd datastore],
      %i[dvd path]
    ]
    fields.each do |context, key|
      EVIL.each do |value|
        error = assert_raises(ForemanHyperv::UnsafeIdentifier,
                              "#{context}##{key} accepted #{value.inspect}") do
          IV.validate_hash!({ key => value }, context: context)
        end
        # The message names the field and never echoes the attacker's string.
        assert_not_includes error.message, 'whoami'
      end
    end
  end

  def test_machine_hash_never_carries_path_or_service
    assert_raises(ForemanHyperv::UnsafeIdentifier) { IV.validate_hash!({ path: 'C:\\ClusterStorage\\Volume1' }) }
    assert_raises(ForemanHyperv::UnsafeIdentifier) { IV.validate_hash!({ service: 'anything' }) }
    # Blank copies are what the existing code deletes before use; they are not a
    # value fog would ever interpolate.
    IV.validate_hash!({ path: '', service: nil })
  end

  def test_nested_device_hashes_refuse_keys_outside_the_fixed_lists
    # computer_name is never a device field, however innocent its value.
    assert_raises(ForemanHyperv::UnsafeIdentifier) do
      IV.validate_hash!({ interfaces_attributes: { '0' => { computer_name: 'hv-node1' } } })
    end
    assert_raises(ForemanHyperv::UnsafeIdentifier) do
      IV.validate_hash!({ interfaces_attributes: { '0' => { 'x;whoami' => 'y' } } })
    end
    assert_raises(ForemanHyperv::UnsafeIdentifier) do
      IV.validate_hash!({ volumes_attributes: { '0' => { computer_name: 'hv-node1' } } })
    end
  end

  def test_unknown_nested_hash_keys_are_refused
    assert_raises(ForemanHyperv::UnsafeIdentifier) do
      IV.validate_hash!({ some_block: { 'bad key;' => 'x' } })
    end
    IV.validate_hash!({ some_block: { fine_key: 'plain value' } })
  end

  def test_legitimate_hashes_pass
    IV.validate_hash!(
      name: 'lab-vm01.lab.maughmer.net',
      notes: 'Built by CI: ok (lab) #42 count=7 & more',
      computer_name: 'hv-node1.lab.maughmer.net',
      cluster_name: 'HVCLUSTER',
      generation: 2,
      processor_count: 2,
      memory_startup: 1_073_741_824,
      dynamic_memory_enabled: '1',
      secure_boot_enabled: false,
      boot_device: 'NetworkAdapter',
      foreman_firmware: 'uefi_secure_boot',
      start: true,
      interfaces_attributes: {
        '0' => {
          mac: '00:15:5D:01:02:03',
          switch_name: 'WSL (Hyper-V firewall)',
          compute_attributes: {
            id: GUID,
            switch_id: GUID,
            vlan_operation_mode: 'Trunk',
            native_vlan_id: '10',
            allowed_vlan_ids: '1-5,7'
          }
        }
      },
      volumes_attributes: {
        '0' => { basename: 'Disk 1', size_bytes: 134_217_728, datastore: 'C:\\ClusterStorage\\Volume1' },
        '1' => { id: GUID, size_bytes: 268_435_456 }
      }
    )

    # The API/hammer list shapes meet the same model lists.
    IV.validate_hash!(interfaces_attributes: [{ name: 'Network Adapter', mac_address: '00155D0A0B0C' }])
    IV.validate_hash!(volumes_attributes: [{ basename: 'Disk', size: 1024 }])
    IV.validate_hash!({ mac: '00155D0A0B0C' }, context: :nic)
    IV.validate_hash!({ path: 'C:\\ClusterStorage\\Volume3\\iso\\cd.iso' }, context: :dvd)
  end

  # PLG-24: core's ComputeResource#host_interfaces_attrs merges ip: and ip6:
  # onto every physical NIC's compute_attributes — so a UI create carries them
  # even though they name nothing Hyper-V is asked to do (create_interfaces
  # excepts them before fog's setters). On 2026-11-22 the first clustered
  # machine driven through the host form died here, on the value the operator
  # had typed into IPv4 address, before fog sent anything. The keys are
  # legitimate form traffic; their characters still meet the allowlist.
  def test_nic_context_accepts_cores_passthrough_ip_keys
    IV.validate_hash!(
      interfaces_attributes: {
        '0' => {
          _destroy: '0',
          identity: '',
          switch_id: '',
          vlan_operation_mode: 'Untagged',
          ip: '192.168.55.5/24',
          ip6: ''
        }
      }
    )
    IV.validate_hash!({ ip: '10.0.2.7' }, context: :nic)
    IV.validate_hash!({ ip6: 'fe80::a00:27ff:fe4e:66a1' }, context: :nic)
    assert_raises(ForemanHyperv::UnsafeIdentifier) { IV.validate_hash!({ ip: "1.2.3.4';whoami;'" }, context: :nic) }
    assert_raises(ForemanHyperv::UnsafeIdentifier) { IV.validate_hash!({ ip6: 'fe80::$(id)' }, context: :nic) }
  end

  def test_refuse_text_single_value
    assert_raises(ForemanHyperv::UnsafeIdentifier) { IV.refuse_text!(:cluster_name, "x';whoami;'") }
    IV.refuse_text!(:cluster_name, 'HVCLUSTER')
  end
end
