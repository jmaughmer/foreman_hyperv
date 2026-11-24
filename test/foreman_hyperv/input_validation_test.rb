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

  # PLG-37: the edit form round-trips identifiers the MACHINE is not addressed
  # by — a NIC identity and a disk id are WMI device paths exactly as the host's
  # WMI layer reports them (the NIC's is the two-segment adapter path, the
  # disk's carries controller, target, and drive letter). The bare-GUID rule
  # applied to these keys wherever they appeared, so the first host-edit POST
  # since the rule (2026-11-24, PLG-36 acceptance, production.log b4391aed)
  # died in validate_hash! before fog was asked anything; create never carried
  # these keys, so create could not see it. The machine is still addressed by
  # the bare GUID demanded up front, an unmatched device id simply matches
  # nothing, and the injection sinks these values can reach stay gated by the
  # endpoint's own shapes: GUIDs, numeric form row ids, and `Microsoft:` WMI
  # paths whose segments are GUIDs, controller numbers, or drive letters.
  def test_edit_roundtrip_device_ids_pass
    # The measured save_vm shapes: the host form's NIC rows arrive complete
    # (hyperv_add_attributes copies the interface columns in, PLG-24's ip/ip6
    # precedent) carrying the device identity in nested compute_attributes;
    # the disk rows carry the five-segment WMI device path.
    wmi_nic = 'Microsoft:1C51C4EE-DF90-4CEE-A9F7-218888711248\\D07B9966-E6F1-4C58-9F4B-C420EBE2A804'
    wmi_disk = 'Microsoft:1C51C4EE-DF90-4CEE-A9F7-218888711248\\D0D76B44-1269-4F42-8150-8D9261FFD283\\0\\0\\D'
    wmi_dvd = 'Microsoft:1C51C4EE-DF90-4CEE-A9F7-218888711248\\D07B9966-E6F1-4C58-9F4B-C420EBE2A804\\0\\1\\E'
    IV.validate_hash!(
      interfaces_attributes: {
        '0' => {
          _destroy: '0', id: '6', identifier: '', name: 'leah-navia',
          domain_id: '1', subnet_id: '1', ip: '', ip6: '',
          managed: '1', primary: '1', provision: '1', execution: '1',
          tag: '', attached_to: '',
          compute_attributes: { identity: wmi_nic, switch_id: GUID, vlan_operation_mode: 'Untagged' }
        }
      },
      volumes_attributes: {
        '0' => { id: wmi_disk, basename: 'Disk', size_bytes: '1073741824' },
        '1' => { id: wmi_dvd }
      }
    )
    # The bare shapes that already passed keep passing.
    IV.validate_hash!({ id: GUID }, context: :nic)
    IV.validate_hash!({ identity: GUID }, context: :nic)
    IV.validate_hash!({ id: '6' }, context: :nic)
  end

  def test_machine_addressing_keys_stay_bare_guid
    # switch_id and vm_id name machines and switches on the wire — fog takes
    # its by-id branch on exactly the GUID shape, so a device path or a row id
    # there is a bug, not round-trip traffic.
    assert_raises(ForemanHyperv::UnsafeIdentifier) do
      IV.validate_hash!({ vm_id: 'Microsoft:1C51C4EE-DF90-4CEE-A9F7-218888711248' })
    end
    assert_raises(ForemanHyperv::UnsafeIdentifier) { IV.validate_hash!({ vm_id: '6' }) }
    assert_raises(ForemanHyperv::UnsafeIdentifier) { IV.validate_hash!({ switch_id: '6' }) }
    assert_raises(ForemanHyperv::UnsafeIdentifier) { IV.validate_hash!({ switch_id: 'hv-node1' }) }
  end

  def test_device_id_keys_still_refuse_script_text_and_forged_paths
    bad = [
      "6';whoami;'", 'x$(whoami)', '6;id', 'C:\\ClusterStorage\\Volume1',
      "Microsoft:#{GUID}';whoami;'", "Microsoft:#{GUID}\\..\\..\\windows",
      'Microsoft:1C51C4EE-DF90-4CEE-A9F7-218888711248\\../../x', 'Microsoft:',
      "Microsoft:#{GUID}\\hv-node1", 'hv-node1', 'x[1]'
    ]
    bad.each do |value|
      assert_raises(ForemanHyperv::UnsafeIdentifier, "id accepted #{value.inspect}") do
        IV.validate_hash!({ id: value })
      end
      assert_raises(ForemanHyperv::UnsafeIdentifier, "identity accepted #{value.inspect}") do
        IV.validate_hash!({ identity: value })
      end
    end
  end
end
