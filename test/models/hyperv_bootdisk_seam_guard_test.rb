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

# bootdisk PR-5: the Host::Managed-side SEAM the opt-in opens. Two pieces.
#
# (1) Decision 1's payload-staleness guard, on in-memory state, refusing
#     exactly the case where a step will write an address the ALREADY-GENERATED
#     ISO cannot carry — and nothing else. Core fills blank addresses in TWO
#     places (before_validation :set_ip_address at managed.rb:338, and
#     setComputeIPAM inside queue_compute_create); the before_validation fill
#     runs BEFORE the bootdisk ISO generates (generate is priority 5), so
#     dhcp/db/random_db/external_ipam addresses are already home at
#     generation time. What remains blank at validation is EUI-64 — its fill
#     waits for a MAC that only exists after create — so exactly a CREATE with
#     a blank behind a mac-based IPAM is refused. The plan wrote the gate as
#     provision_method 'full_host'; the INSTALLED 24.1.0 registers exactly ONE
#     provision method, 'bootdisk' (engine.rb:49), and its own full-host queue
#     gate is `provision_method == 'bootdisk' && ((old.nil? || !old.build?) &&
#     build?)` (orchestration/compute.rb:29) — the guard mirrors the queue's
#     own gate or it is dead code. Per Decision 6 a blank MAC itself NEVER
#     refuses: Hyper-V always answers compute_provides?(:mac) true.
#
# (2) The iso_upload_storage carry: the bootdisk gem ships NO widget for the
#     key (grepped 24.1.0 views/lib/helpers: zero writers), so it is set via
#     API/hammer and lives in host.compute_attributes. A UI edit re-renders
#     only what the form draws, and Host::Managed#vm_compute_attributes
#     (managed.rb:720) reads the LIVE fog model, which has no such attribute —
#     so a UI save would otherwise WIPE the operator's ISO destination. The
#     plugin's update seam carries the stored value into the submitted hash
#     unless the submission itself names the key (API '' clears stay
#     possible).
class HypervBootdiskSeamGuardTest < ActiveSupport::TestCase
  alias assert_not refute

  IPAM_NONE = IPAM::MODES[:none].freeze
  EXISTING_UUID = 'bd5-existing-uuid'

  # A booted-Foreman Host::Managed with its answers stubbed (the built-seam
  # suite's convention): the guard reads ONLY in-memory state, so every read
  # it makes is answered here and anything else it touches fails loudly.
  def guard_host(provision_method: 'bootdisk', build: true, old: nil, uuid: nil,
                 mac_based_subnet: false, mac_based_subnet6: false, nics: :eui64_blank)
    host = Host::Managed.new(name: 'bd5.example.com', provision_method: provision_method)
    host.build = build
    if uuid
      # A uuid means the machine was created: the instance reads persisted.
      # (A Host::Managed.new is a new record whatever the uuid column says.)
      host.uuid = uuid
      host.stubs(:new_record?).returns(false)
    end
    host.stubs(:old).returns(old)
    # Hyper-V always answers true for :mac (Decision 6 item 6: the guard must
    # not turn that ever-true fact into an over-refusal).
    host.stubs(:compute_provides?).with(:mac).returns(true)
    host.stubs(:mac_based_ipam?).with(:subnet).returns(mac_based_subnet)
    host.stubs(:mac_based_ipam?).with(:subnet6).returns(mac_based_subnet6)
    host.stubs(:interfaces).returns(
      case nics
      when :eui64_blank
        [stub(managed: true, subnet: nil, ip: nil, subnet6: stub(ipam: 'eui-64'), ip6: nil)]
      when :eui64_filled
        [stub(managed: true, subnet: nil, ip: nil, subnet6: stub(ipam: 'eui-64'), ip6: 'fe80::1')]
      when :none_blank
        [stub(managed: true, subnet: stub(ipam: IPAM_NONE), ip: nil, subnet6: nil, ip6: nil)]
      when :dhcp_filled
        [stub(managed: true, subnet: stub(ipam: 'dhcp'), ip: '10.0.0.7', subnet6: nil, ip6: nil)]
      when :unmanaged_blank
        [stub(managed: false, subnet: nil, ip: nil, subnet6: stub(ipam: 'eui-64'), ip6: nil)]
      else
        nics
      end
    )
    host
  end

  def rebuild_old
    old = Host::Managed.new(name: 'bd5.example.com', provision_method: 'bootdisk')
    old.stubs(:build?).returns(false) # the built transition; rebuild flips build back on
    old
  end

  # ---- Decision 1: the guard refuses the stale-payload create, and nothing else ----

  test 'a create whose ip6 is blank behind a mac-based (EUI-64) subnet6 is refused' do
    host = guard_host(mac_based_subnet6: true)

    assert host.bootdisk_payload_would_go_stale?,
           'the EUI-64 fill waits for a MAC that only exists after create — the ISO generated now ' \
           'would carry no address for the interface it configures'
  end

  test 'a rebuild of the same host is NOT refused: queue_compute_update has no IPAM step, so the payload cannot diverge' do
    host = guard_host(old: rebuild_old, uuid: EXISTING_UUID, mac_based_subnet6: true)

    assert_not host.bootdisk_payload_would_go_stale?
  end

  test 'a blank address behind a None-IPAM subnet is NOT refused: nothing is ever filled, so nothing goes stale' do
    host = guard_host(mac_based_subnet: false, mac_based_subnet6: false, nics: :none_blank)

    assert_not host.bootdisk_payload_would_go_stale?
  end

  test 'a create behind a NON-mac-based IPAM is NOT refused even with blanks: the before_validation fill owns those modes' do
    # The plan's list item 3, expressed honestly: dhcp/db/random_db/
    # external_ipam fill in before_validation (before generation), so core's
    # own IP-presence validation owns any blank there — the guard's mac-based
    # condition is what keeps this refused-case set empty.
    host = guard_host(mac_based_subnet: false, mac_based_subnet6: false, nics: :dhcp_filled)

    assert_not host.bootdisk_payload_would_go_stale?
  end

  test 'a blank ip6 behind EUI-64 whose address is already filled is NOT refused: the guard acts on blanks only' do
    host = guard_host(mac_based_subnet6: true, nics: :eui64_filled)

    assert_not host.bootdisk_payload_would_go_stale?
  end

  test 'an UNMANAGED interface blank behind EUI-64 is NOT refused: the guard mirrors set_ip_address, which walks managed nics only' do
    host = guard_host(mac_based_subnet6: true, nics: :unmanaged_blank)

    assert_not host.bootdisk_payload_would_go_stale?
  end

  test 'a plain build host and a bootdisk config-disk host (build false) never reach the guard' do
    assert_not guard_host(provision_method: 'build', mac_based_subnet6: true).bootdisk_payload_would_go_stale?
    assert_not guard_host(build: false, mac_based_subnet6: true).bootdisk_payload_would_go_stale?
  end

  test 'the refusal lands as an errors.add on base naming the fix, not as an exception' do
    host = guard_host(mac_based_subnet6: true)

    host.validate_bootdisk_payload_would_go_stale

    message = host.errors[:base].join(' ')
    assert_includes message, 'boot disk'
    assert_includes message, 'EUI-64'
  end

  # ---- the iso_upload_storage carry ----------------------------------------------

  def carrying_host(stored)
    host = Host::Managed.new(name: 'bd5.example.com')
    host.stubs(:compute_attributes).returns(stored)
    host
  end

  test 'a UI update that never renders the key carries the stored iso_upload_storage forward' do
    host = carrying_host('iso_upload_storage' => 'C:\\ClusterStorage\\Volume1')
    submitted = { 'compute_attributes' => { 'memory_startup' => '1024' } }

    host.send(:hyperv_preserve_iso_upload_storage, submitted)

    assert_equal 'C:\\ClusterStorage\\Volume1', submitted['compute_attributes']['iso_upload_storage']
  end

  test 'a submitted key wins, including the explicit empty clear: the carry never overrides an intent' do
    host = carrying_host('iso_upload_storage' => 'C:\\ClusterStorage\\Volume1')
    submitted = { 'compute_attributes' => { 'iso_upload_storage' => '' } }
    host.send(:hyperv_preserve_iso_upload_storage, submitted)
    assert_equal '', submitted['compute_attributes']['iso_upload_storage'].to_s

    submitted2 = { 'compute_attributes' => { 'iso_upload_storage' => 'C:\\VMs' } }
    host.send(:hyperv_preserve_iso_upload_storage, submitted2)
    assert_equal 'C:\\VMs', submitted2['compute_attributes']['iso_upload_storage']
  end

  test 'with nothing stored the carry adds no key at all' do
    host = carrying_host({})
    submitted = { 'compute_attributes' => { 'memory_startup' => '1024' } }

    host.send(:hyperv_preserve_iso_upload_storage, submitted)

    assert_not submitted['compute_attributes'].key?('iso_upload_storage')
  end
end
