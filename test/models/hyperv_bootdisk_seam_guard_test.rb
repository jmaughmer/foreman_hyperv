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
#     possible). The API controller never crosses #update — that recorded
#     asymmetry (PR-5, F1) and where the loss surfaces are pinned at the tail.
class HypervBootdiskSeamGuardTest < ActiveSupport::TestCase
  alias assert_not refute

  IPAM_NONE = IPAM::MODES[:none].freeze
  EXISTING_UUID = 'bd5-existing-uuid'

  # A nic wearing the real contract the guard reads (the iso suite's
  # MachineStub convention): managed/primary are columns, and
  # mac_based_ipam? takes the REQUIRED field argument (nic/base.rb:252) —
  # answered per field from the mac_based map. primary?/managed? aliases
  # exist because core's flag lookup (get_interface_by_flag) may call either
  # shape, and the F2 case drives that real delegate.
  class NicStub
    attr_reader :managed, :primary, :subnet, :subnet6, :ip, :ip6

    def initialize(managed: true, primary: false, subnet: nil, subnet6: nil,
                   ip: nil, ip6: nil, mac_based: {})
      @managed = managed
      @primary = primary
      @subnet = subnet
      @subnet6 = subnet6
      @ip = ip
      @ip6 = ip6
      @mac_based = mac_based
    end

    alias managed? managed
    alias primary? primary

    def mac_based_ipam?(field)
      @mac_based.fetch(field, false)
    end
  end

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
    # Answered at BOTH levels on purpose: the host-level call answers the
    # core delegate (managed.rb:306 forwards to primary_interface), and the
    # primary nic answers it directly — the guard's own path. Keeping the
    # pair means the harness passes on the delegate shape AND on the
    # primary-detected shape, so it cannot mask a silent move between them.
    host.stubs(:mac_based_ipam?).with(:subnet).returns(mac_based_subnet)
    host.stubs(:mac_based_ipam?).with(:subnet6).returns(mac_based_subnet6)
    host.stubs(:interfaces).returns(
      case nics
      when :eui64_blank
        [primary_nic(mac_based_subnet, mac_based_subnet6, subnet6: stub(ipam: 'eui-64'))]
      when :eui64_filled
        [primary_nic(mac_based_subnet, mac_based_subnet6, subnet6: stub(ipam: 'eui-64'), ip6: 'fe80::1')]
      when :none_blank
        [primary_nic(mac_based_subnet, mac_based_subnet6, subnet: stub(ipam: IPAM_NONE))]
      when :dhcp_filled
        [primary_nic(mac_based_subnet, mac_based_subnet6, subnet: stub(ipam: 'dhcp'), ip: '10.0.0.7')]
      when :unmanaged_blank
        [primary_nic(mac_based_subnet, mac_based_subnet6, managed: false, subnet6: stub(ipam: 'eui-64'))]
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

  # Every single-nic scenario wears the primary flag: the guard's gate rides
  # the PRIMARY nic (core's setComputeIPAM gate is primary-only,
  # orchestration/compute.rb:80-83), so a flagless nic would short-circuit
  # it for reasons unrelated to the case under test.
  def primary_nic(mac_based_subnet, mac_based_subnet6, **attrs)
    NicStub.new(primary: true,
                mac_based: { subnet: mac_based_subnet, subnet6: mac_based_subnet6 },
                **attrs)
  end

  # ---- Decision 1: the guard refuses the stale-payload create, and nothing else ----

  test 'a create whose ip6 is blank behind a mac-based (EUI-64) subnet6 is refused' do
    host = guard_host(mac_based_subnet6: true)

    assert host.bootdisk_payload_would_go_stale?,
           'the EUI-64 fill waits for a MAC that only exists after create — the ISO generated now ' \
           'would carry no address for the interface it configures'
  end

  test 'a rebuild is NOT refused: queue_compute_update has no IPAM step to diverge' do
    host = guard_host(old: rebuild_old, uuid: EXISTING_UUID, mac_based_subnet6: true)

    assert_not host.bootdisk_payload_would_go_stale?
  end

  test 'a blank address behind a None-IPAM subnet is NOT refused: nothing is ever filled, so nothing goes stale' do
    host = guard_host(mac_based_subnet: false, mac_based_subnet6: false, nics: :none_blank)

    assert_not host.bootdisk_payload_would_go_stale?
  end

  test 'a NON-mac-based IPAM create is NOT refused with blanks: before_validation owns those' do
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

  test 'an UNMANAGED blank behind EUI-64 is NOT refused: the guard walks managed nics only' do
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

  test 'the guard is REGISTERED on Host::Managed: prepend left it unregistered (probe)' do
    # The first implementation PREPENDED this ActiveSupport::Concern beside
    # HostManagedExtensions. The module then sat in the ancestor chain, the
    # predicate worked when called, and the validate callback was NOT
    # registered — a guard that only runs when someone remembers to call it
    # (probed against the booted app: SEAM_ANCESTOR=true,
    # SEAM_REGISTERED=false). Registration is a separate fact from the
    # method existing, so it is asserted as its own fact.
    assert_includes Host::Managed._validate_callbacks.map(&:filter), :validate_bootdisk_payload_would_go_stale
  end

  test 'a host whose nics carry no primary flag answers NOT stale: no raise from the allow_nil-less delegate' do
    # Core delegates mac_based_ipam? to primary_interface WITHOUT allow_nil
    # (managed.rb:306) and primary_interface is a flag lookup
    # (host/base.rb:268-270) — nil on a host whose interfaces lack the flag.
    # Core only ever calls the delegate from after_validation/orchestration;
    # this guard runs INSIDE the validation cycle, where a NoMethodError
    # would 500 the save instead of letting check_interfaces (managed.rb:691)
    # report the missing primary (round 23, F2). The predicate is UNSTUBBED
    # here on purpose: the real delegate must be the thing that used to blow.
    host = Host::Managed.new(name: 'bd5.example.com', provision_method: 'bootdisk')
    host.build = true
    host.stubs(:old).returns(nil)
    host.stubs(:compute_provides?).with(:mac).returns(true)
    host.stubs(:interfaces).returns(
      [NicStub.new(primary: false, subnet6: stub(ipam: 'eui-64'), ip6: nil,
                   mac_based: { subnet6: true })]
    )

    assert_not host.bootdisk_payload_would_go_stale?
  end

  test 'a SECONDARY blank behind EUI-64 with a non-mac-based primary is NOT refused: gate primary, fill all' do
    # Documented scope (round 23, F7): core's setComputeIPAM GATE is
    # primary-only (orchestration/compute.rb:80-83 — mac_based_ipam? reads
    # the primary's subnet), while the FILL walks every managed nic
    # (managed.rb:600-606). So with a DHCP primary, core never queues the
    # EUI-64 fill for the secondary either — nothing fills, nothing goes
    # stale, no refusal. A test with two nics is the only place this split
    # is expressible at all.
    nics = [
      NicStub.new(primary: true, subnet: stub(ipam: 'dhcp'), ip: '10.0.0.7'),
      NicStub.new(subnet6: stub(ipam: 'eui-64'), ip6: nil)
    ]
    host = guard_host(nics: nics)

    assert_not host.bootdisk_payload_would_go_stale?
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

  # The tests above call the private method directly — the exact class of
  # blind spot this file already documents once (a method that exists but is
  # not WIRED, round 23, F6). These two pin the wiring itself: the prepended
  # HostManagedExtensions#update is what runs the carry, before the interface
  # reconciliation that sees the same hash.

  test 'Host#update dispatches the carry BEFORE hyperv_add_attributes' do
    host = Host::Managed.new(name: 'bd5.example.com')
    host.stubs(:provider).returns('Hyper-V')
    # save is NOT the subject — and it must not depend on test-DB state (a
    # shuffle left this host VALID once, which both flipped the return value
    # and LEAKED a row). The dispatch and its ORDER are the subject: both
    # expectations must be met before update returns. Dropping engine.rb's
    # prepend of HostManagedExtensions fails this test while every
    # direct-call test above stays green.
    host.stubs(:save).returns(false)
    seq = sequence('carry')
    host.expects(:hyperv_preserve_iso_upload_storage).in_sequence(seq)
    host.expects(:hyperv_add_attributes).in_sequence(seq)

    assert_not host.update('compute_attributes' => { 'memory_startup' => '1024' })
  end

  test 'the REAL carry has run by the time hyperv_add_attributes sees the hash' do
    host = Host::Managed.new(name: 'bd5.example.com')
    host.stubs(:provider).returns('Hyper-V')
    host.stubs(:save).returns(false)
    host.compute_attributes = { 'iso_upload_storage' => 'C:\\ClusterStorage\\Volume1' }
    # Only the interface reconciliation is stubbed — the carry itself is the
    # real method, and the with-block proves its output arrived first.
    host.expects(:hyperv_add_attributes).with do |attrs|
      attrs['compute_attributes']['iso_upload_storage'] == 'C:\\ClusterStorage\\Volume1'
    end

    host.update('compute_attributes' => { 'memory_startup' => '1024' })
  end

  # ---- F1: the API path never crosses #update (asymmetry recorded at merge) -------
  #
  # Api::V2::HostsController#update (installed core, hosts_controller.rb:158-167,
  # read 2026-11-26) does @host.attributes = host_attributes(...) + @host.save —
  # #update is NEVER called — and Orchestration::Compute declares
  # compute_attributes as a plain attr_accessor (installed
  # orchestration/compute.rb:9; rails-runner probe 2026-11-26: attributes= with
  # the key lands the raw hash, no sanitizer, no override on Host::Managed), so
  # the serialized hash is REPLACED WHOLE. hammer host update
  # --compute-attributes that omits iso_upload_storage therefore loses the
  # stored destination — the asymmetry PR-5 recorded at merge (round-23 fold)
  # as documented-not-fixed: the carry lives in #update, and the lower seam
  # that would cover both paths was deferred out of the one-feature scope.
  # These tests pin the RECORDED state, not new behavior: test-only, green on
  # the base tree by design (no runtime line exists for them to be red
  # about — recorded green-on-both-trees like the PLG-47 pin). The third pins
  # WHERE the loss surfaces: installed bootdisk 24.1.0 reads
  # compute_attributes&.with_indifferent_access&.dig(:iso_upload_storage) at
  # orchestration time (its orchestration/compute.rb:76-77) and hands it to
  # iso_upload as storage_id (:61), whose blank-id refusal (hyperv.rb:904)
  # names the failure one build later instead of writing an ISO toward an
  # undefined destination.

  test 'the API controller shape (attributes= then save) REPLACES compute_attributes ' \
       'whole: the omitted iso_upload_storage is gone' do
    host = Host::Managed.new(name: 'bd5.example.com')
    host.compute_attributes = { 'memory_startup' => '1024', 'iso_upload_storage' => 'C:\\ClusterStorage\\Volume1' }

    # Exactly the controller line — plain accessor write, no carry seam:
    # hosts_controller.rb:162 @host.attributes = host_attributes(...).
    host.attributes = { 'compute_attributes' => { 'memory_startup' => '2048' } }

    assert_equal({ 'memory_startup' => '2048' }, host.compute_attributes)
  end

  test 'the SAME submission through #update keeps the destination: the F1 asymmetry is the entrypoint, not the carry' do
    host = Host::Managed.new(name: 'bd5.example.com')
    host.stubs(:provider).returns('Hyper-V')
    host.stubs(:save).returns(false)
    host.stubs(:hyperv_add_attributes)
    host.compute_attributes = { 'memory_startup' => '1024', 'iso_upload_storage' => 'C:\\ClusterStorage\\Volume1' }

    host.update('compute_attributes' => { 'memory_startup' => '2048' })

    # The UI path's hash arrives at the same accessor write the API path uses,
    # but the prepended #update carried the key into it first (the wiring the
    # dispatch tests above pin): whole-hash replace, yet the destination rides.
    assert_equal({ 'memory_startup' => '2048', 'iso_upload_storage' => 'C:\\ClusterStorage\\Volume1' },
                 host.compute_attributes)
  end

  test 'the loss surfaces one build later: bootdisk digs nil and iso_upload refuses ' \
       'the replaced-hash storage id by name' do
    host = Host::Managed.new(name: 'bd5.example.com')
    host.compute_attributes = { 'memory_startup' => '1024', 'iso_upload_storage' => 'C:\\ClusterStorage\\Volume1' }
    host.attributes = { 'compute_attributes' => { 'memory_startup' => '2048' } }

    # bootdisk's EXACT orchestration-time read (24.1.0
    # orchestration/compute.rb:76-77), then the same hand-off :61 makes.
    storage_id = host.compute_attributes&.with_indifferent_access&.dig(:iso_upload_storage)
    assert_nil storage_id

    cr = ForemanHyperv::Hyperv.new(name: 'lab-cr', url: 'https://host.example:5985', user: 'u', password: 'p')
    # __FILE__ stands in for the generated ISO: the blank-arg checks run FIRST
    # (hyperv.rb:902-904), so this raises before any enablement gate, fog dial,
    # or byte — the refusal is the documented one, not an environmental accident.
    err = assert_raises(ArgumentError) { cr.iso_upload(__FILE__, EXISTING_UUID, storage_id: storage_id) }
    assert_match(/iso_upload requires a storage id/, err.message)
  end
end
