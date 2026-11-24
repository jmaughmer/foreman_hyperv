# frozen_string_literal: true

require 'test_helper'
require 'active_support/test_case'
require 'digest'
require 'tmpdir'
require 'fileutils'

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

# bootdisk PR-2: the iso_* quartet the foreman_bootdisk orchestration calls on
# the COMPUTE RESOURCE (contract verbatim from the installed
# foreman_bootdisk-24.1.0, Orchestration::Compute):
#
#   iso_upload(isofile, uuid, storage_id:)   before_build prio 6
#   iso_attach(File.basename(isofile), uuid, storage_id:) before_build prio 900
#   iso_detach(uuid)                         after_build prio 52
#   iso_delete(isofile, uuid)                after_build prio 53
#
# The transfer rides Decision 2's pull: the plugin stages the ISO under an
# unguessable nonce, the HOST fetches it over HTTP through fog's
# fetch_url_to_path (which verifies status, byte count and sha256 on the host
# BEFORE the file takes its final name), and the staged copy is deleted in an
# ensure either way. The host-side file is named for the ISO's basename —
# iso_attach and iso_delete receive that basename and no nonce, so the nonce
# protects the URL, never the path.
#
# Capability gates, never versions (the fork's rule): the pull is refused when
# the fog answers neither the :file_pull constant nor fetch_url_to_path, and
# the scoped delete likewise for :contained_file_removal/remove_file — the
# gate copies the cluster-role style, and these words sit on the plugin's
# opt-in side, never the enablement six (fog pairs no supports_*? predicate
# with them, and a predicate-less entry on the enablement side would answer
# "missing" and refuse every unlocked operation). The pull and the attach
# still ride the enablement era (they send through the same hardened WinRM
# transport); the scoped delete does not — fog's own request carries its own
# scope guard, and a destroy path that cannot clean up must not be gated on
# the create era's partnership.
#
# fog is a recording stub here (the fork's mutating-request rule: no
# Fog.mock!); every refusal is asserted to happen BEFORE any fog call.
class HypervBootdiskIsoTest < ActiveSupport::TestCase
  UUID = '1c51c4ee-df90-4cee-a9f7-218888711248'
  CR_URL = 'https://hyperv.example.com:5985'
  VmStub = Struct.new(:id, :power_state)
  BOOT_ORDER_ROWS = [
    { position: 1, boot_type: 'Network', device_text: 'VMNetworkAdapter (Name =  Ethernet 0)',
      device_id: 'Microsoft:1', firmware_path: '' },
    { position: 2, boot_type: 'Drive', device_text: 'HardDiskDrive (Name = disk.vhdx)',
      device_id: 'Microsoft:2', firmware_path: '' },
    { position: 3, boot_type: 'File', device_text: '', device_id: '', firmware_path: '\EFI\BOOT\BOOTX64.EFI' }
  ].freeze

  setup do
    @served = Dir.mktmpdir('bd-served')
    @staging = Dir.mktmpdir('bd-staging')
    ForemanHyperv::BootdiskTransfer.served_root = @served
    ForemanHyperv::BootdiskTransfer.staging_root = @staging
    Setting.stubs(:[]).returns('http://foreman.test')
  end

  teardown do
    ForemanHyperv::BootdiskTransfer.served_root = nil
    ForemanHyperv::BootdiskTransfer.staging_root = nil
    FileUtils.remove_entry(@served) if @served && File.directory?(@served)
    FileUtils.remove_entry(@staging) if @staging && File.directory?(@staging)
  end

  # ---- the recording fog ------------------------------------------------------

  class FogBootdisk
    attr_reader :calls
    attr_accessor :dvd_rows, :fetch_answer, :remove_answers, :boot_rows

    def initialize(dvd_rows: [{ id: 'dvd-1', vm_id: HypervBootdiskIsoTest::UUID, path: nil }],
                   fetch_answer: nil, remove_answers: {}, boot_rows: HypervBootdiskIsoTest::BOOT_ORDER_ROWS)
      @calls = []
      @dvd_rows = dvd_rows
      @fetch_answer = fetch_answer
      @remove_answers = remove_answers
      @boot_rows = boot_rows
    end

    # The enablement six, answered true (the era partnership the pull and the
    # attach ride; see HypervEnablementTest for what they mean).
    def supports_clusters? = true
    def supports_exact_host_connections? = true
    def supports_literal_path_destructive? = true
    def supports_stdout_json_hygiene? = true
    def supports_input_hardening? = true
    def supports_cluster_capacity_projection? = true

    def get_vm_dvd_drive(vm_id:)
      @calls << [:get_vm_dvd_drive, vm_id]
      @dvd_rows
    end

    def add_vm_dvd_drive(vm_id:, **options)
      @calls << [:add_vm_dvd_drive, vm_id, options]
      [{ id: 'dvd-new', vm_id: vm_id, path: nil }]
    end

    def set_vm_dvd_drive(id:, vm_id:, path:)
      @calls << [:set_vm_dvd_drive, id, vm_id, path]
      true
    end

    def eject_vm_dvd_drive(id:, vm_id:)
      @calls << [:eject_vm_dvd_drive, id, vm_id]
      true
    end

    def get_vm_boot_order(vm_id:)
      @calls << [:get_vm_boot_order, vm_id]
      @boot_rows
    end

    def set_vm_boot_order(vm_id:, order:)
      @calls << [:set_vm_boot_order, vm_id, order]
      order
    end

    def fetch_url_to_path(url:, path:, sha256:, size:)
      @calls << [:fetch_url_to_path, url, path, sha256, size]
      fetch_answer.nil? ? size : fetch_answer
    end

    def remove_file(path:, root:)
      @calls << [:remove_file, path, root]
      !!remove_answers[path.downcase]
    end
  end

  # A fog that cannot send the pull (older partner: no request method — the
  # respond_to? half of the gate is all a constant cannot bless).
  class FogNoPull < FogBootdisk
    undef_method :fetch_url_to_path if method_defined?(:fetch_url_to_path)
  end

  class FogNoRemove < FogBootdisk
    undef_method :remove_file if method_defined?(:remove_file)
  end

  # An era fog missing one enablement predicate: the pull and attach refuse.
  class FogNoEra < FogBootdisk
    def supports_input_hardening? = false
  end

  def build_cr(fog, roots: ['C:\VMs', 'C:\ClusterStorage\Volume1'], power: 'Off')
    cr = ForemanHyperv::Hyperv.new(name: 'lab-cr', url: CR_URL, user: 'u', password: 'p')
    cr.stubs(:client).returns(fog)
    cr.stubs(:storage_roots).returns(roots)
    cr.stubs(:find_vm_by_uuid).returns(VmStub.new(UUID, power))
    [cr, fog]
  end

  def make_iso(dir, name = 'host.example.com.iso', bytes: 'ISO-PAYLOAD')
    path = File.join(dir, name)
    File.binwrite(path, bytes)
    path
  end

  # ---- the transfer store -----------------------------------------------------

  test 'stage copies under an unguessable nonce, never renames the source away, and places atomically' do
    src = make_iso(@staging)
    staged = ForemanHyperv::BootdiskTransfer.stage(src)

    assert_match(/\A[0-9a-f]{32}\z/, staged.nonce)
    assert File.file?(src), 'stage COPIES: the worker still owns its ISO (EXDEV across PrivateTmp forbids the rename)'
    final = File.join(@served, "#{staged.nonce}.iso")
    assert File.file?(final), 'the served placement is <nonce>.iso under the served root'
    assert_equal File.binread(src), File.binread(final)
    assert Dir.children(@staging).none? { |f| f.end_with?('.part') }, 'no temp survivor in the staging root'
    sidecar = File.join(@staging, "#{staged.nonce}.json")
    assert File.file?(sidecar), 'the sidecar lives in the UNSERVED staging root beside the temp, not in the served one'
    meta = JSON.parse(File.read(sidecar))
    assert_equal Digest::SHA256.file(src).hexdigest, meta['sha256']
    assert_equal File.size(src), meta['size']
    assert_equal staged.sha256, meta['sha256']
    assert_equal staged.bytes, meta['size']
  end

  test 'the stage url is the unattended URL plus the nonce path' do
    staged = ForemanHyperv::BootdiskTransfer.stage(make_iso(@staging))
    assert_equal "http://foreman.test/bootdisk-pull/#{staged.nonce}.iso", staged.url
  end

  test 'discard removes the served ISO and its sidecar, and is an answer-free no-op when they are gone' do
    src = make_iso(Dir.mktmpdir('bd-src'))
    staged = ForemanHyperv::BootdiskTransfer.stage(src)
    ForemanHyperv::BootdiskTransfer.discard(staged.nonce)
    assert_empty Dir.children(@served)
    assert_empty Dir.children(@staging)
    assert File.file?(src), 'discard takes the shelf, never the worker\u2019s own copy'
    assert_nothing_raised { ForemanHyperv::BootdiskTransfer.discard(staged.nonce) }
  end

  test 'discard refuses to touch anything a nonce-shaped name does not cover' do
    File.write(File.join(@served, '..iso'), 'x')
    ForemanHyperv::BootdiskTransfer.discard('..')
    assert File.file?(File.join(@served, '..iso')), 'an unparseable nonce never becomes a filesystem argument'
  end

  # ---- iso_upload --------------------------------------------------------------

  test 'iso_upload stages, hands the host a verified pull, and leaves nothing staged behind' do
    iso = make_iso(Dir.mktmpdir('bd-iso'))
    cr, fog = build_cr(FogBootdisk.new)

    answer = cr.iso_upload(iso, UUID, storage_id: 'C:\ClusterStorage\Volume1')

    assert_equal File.size(iso), answer
    pull = fog.calls.find { |c| c.first == :fetch_url_to_path }
    assert_not_nil pull, 'the host must be told to pull'
    _tag, url, path, sha256, size = pull
    assert_match(%r{\Ahttp://foreman\.test/bootdisk-pull/[0-9a-f]{32}\.iso\z}, url)
    assert_equal "C:\\ClusterStorage\\Volume1\\#{File.basename(iso)}", path,
                 'the host-side name is the ISO basename — iso_attach/iso_delete receive no nonce'
    assert_equal Digest::SHA256.file(iso).hexdigest, sha256
    assert_equal File.size(iso), size
    assert_empty Dir.children(@served), 'the staged copy is gone on success'
  end

  test 'iso_upload deletes the staged copy even when the pull fails, and the failure travels' do
    iso = make_iso(Dir.mktmpdir('bd-iso'))
    fog = FogBootdisk.new
    fog.fetch_answer = File.size(iso) - 1 # a short pull is a failure the host reported as success
    cr, = build_cr(fog)

    assert_raises(ForemanHyperv::OperationRefused) { cr.iso_upload(iso, UUID, storage_id: 'C:\VMs') }
    assert_empty Dir.children(@served), 'the ensure deletes even on failure — a leaked served ISO is a leak forever'
  end

  test 'iso_upload refuses naming :file_pull when the fog cannot send the pull, and touches nothing' do
    iso = make_iso(Dir.mktmpdir('bd-iso'))
    cr, fog = build_cr(FogNoPull.new)

    error = assert_raises(ForemanHyperv::OperationRefused) { cr.iso_upload(iso, UUID, storage_id: 'C:\VMs') }
    assert_includes error.message, 'file_pull'
    assert_empty fog.calls
    assert_empty Dir.children(@served), 'a refused upload stages nothing'
  end

  test 'iso_upload still refuses without the enablement era, naming the missing behaviour' do
    iso = make_iso(Dir.mktmpdir('bd-iso'))
    cr, fog = build_cr(FogNoEra.new)

    error = assert_raises(ForemanHyperv::OperationRefused) { cr.iso_upload(iso, UUID, storage_id: 'C:\VMs') }
    assert_includes error.message, 'input_hardening'
    assert_empty fog.calls
  end

  test 'iso_upload refuses a storage the host never reported before any fog call' do
    iso = make_iso(Dir.mktmpdir('bd-iso'))
    cr, fog = build_cr(FogBootdisk.new)

    error = assert_raises(ArgumentError) { cr.iso_upload(iso, UUID, storage_id: 'D:\SomewhereElse') }
    # Cite the storage_id exactly as the message renders it (inspect doubles the backslash).
    assert_includes error.message, 'D:\SomewhereElse'.inspect
    assert_includes error.message, 'Nothing was transferred.'
    assert_includes error.message, 'C:\VMs'.inspect, 'roots render the way the refusal cites storage_id'
    assert_empty fog.calls
  end

  test 'iso_attach refuses a storage the host never reported before any fog call' do
    cr, fog = build_cr(FogBootdisk.new)

    error = assert_raises(ArgumentError) { cr.iso_attach('host.example.com.iso', UUID, storage_id: 'D:\SomewhereElse') }
    assert_includes error.message, 'D:\SomewhereElse'.inspect
    assert_includes error.message, 'Nothing was attached.'
    assert_includes error.message, 'C:\ClusterStorage\Volume1'.inspect
    assert_empty fog.calls
  end

  test 'iso_upload accepts a storage the host reported spelled differently, and writes with the host spelling' do
    iso = make_iso(Dir.mktmpdir('bd-iso'))
    cr, fog = build_cr(FogBootdisk.new)

    cr.iso_upload(iso, UUID, storage_id: 'c:\\ClusterStorage\\Volume1\\')

    pull = fog.calls.find { |c| c.first == :fetch_url_to_path }
    assert_equal "C:\\ClusterStorage\\Volume1\\#{File.basename(iso)}", pull[2]
  end

  test 'iso_upload refuses missing inputs with ArgumentError and touches nothing' do
    iso = make_iso(Dir.mktmpdir('bd-iso'))
    cr, fog = build_cr(FogBootdisk.new)

    assert_raises(ArgumentError) { cr.iso_upload(iso, '', storage_id: 'C:\VMs') }
    assert_raises(ArgumentError) { cr.iso_upload(iso, UUID, storage_id: nil) }
    assert_raises(ArgumentError) { cr.iso_upload(File.join(@served, 'never-built.iso'), UUID, storage_id: 'C:\VMs') }
    assert_empty fog.calls
  end

  # ---- iso_attach --------------------------------------------------------------

  test 'iso_attach sets the media on the drive the VM has and puts the DVD first, existing classes behind it' do
    cr, fog = build_cr(FogBootdisk.new)

    cr.iso_attach('host.example.com.iso', UUID, storage_id: 'C:\VMs')

    assert_includes fog.calls, [:set_vm_dvd_drive, 'dvd-1', UUID, 'C:\VMs\host.example.com.iso']
    assert_not(fog.calls.any? { |c| c.first == :add_vm_dvd_drive }, 'the VM already has a DVD drive; one more is a bug')
    set = fog.calls.find { |c| c.first == :set_vm_boot_order }
    assert_not_nil set
    # DVD first; then the read classes in read order. File entries are not requestable and
    # fog's write script keeps unrequested entries' positions — dropping one preserves it.
    assert_equal [{ 'DvdDrive' => 'dvd-1' }, 'VMNetworkAdapter', 'HardDiskDrive'], set[2]
  end

  test 'iso_attach adds the drive when the VM has none and drives the whole sequence off the new drive id' do
    fog = FogBootdisk.new(dvd_rows: [])
    cr, = build_cr(fog)

    cr.iso_attach('host.example.com.iso', UUID, storage_id: 'C:\VMs')

    assert(fog.calls.any? { |c| c.first == :add_vm_dvd_drive })
    assert_includes fog.calls, [:set_vm_dvd_drive, 'dvd-new', UUID, 'C:\VMs\host.example.com.iso']
    set = fog.calls.find { |c| c.first == :set_vm_boot_order }
    assert_equal 'dvd-new', set[2].first['DvdDrive']
  end

  test 'iso_attach refuses a machine that is not powered off — the file cannot take the drive into a running guest' do
    cr, fog = build_cr(FogBootdisk.new, power: 'Running')

    assert_raises(ForemanHyperv::OperationRefused) { cr.iso_attach('host.example.com.iso', UUID, storage_id: 'C:\VMs') }
    assert_empty fog.calls
  end

  test 'iso_attach refuses missing inputs with ArgumentError and touches nothing' do
    cr, fog = build_cr(FogBootdisk.new)

    assert_raises(ArgumentError) { cr.iso_attach('', UUID, storage_id: 'C:\VMs') }
    assert_raises(ArgumentError) { cr.iso_attach('x.iso', '', storage_id: 'C:\VMs') }
    assert_raises(ArgumentError) { cr.iso_attach('x.iso', UUID, storage_id: nil) }
    assert_raises(ArgumentError) { cr.iso_attach('x.iso', UUID, storage_id: 'D:\Elsewhere') }
    assert_empty fog.calls
  end

  # ---- iso_detach --------------------------------------------------------------

  test 'iso_detach ejects the media the drive is holding and answers that it did' do
    fog = FogBootdisk.new(dvd_rows: [{ id: 'dvd-1', vm_id: UUID, path: 'C:\VMs\host.example.com.iso' }])
    cr, = build_cr(fog)

    assert_equal true, cr.iso_detach(UUID)
    assert_includes fog.calls, [:eject_vm_dvd_drive, 'dvd-1', UUID]
  end

  test 'iso_detach is an idempotent no-op when nothing is in any drive' do
    cr, fog = build_cr(FogBootdisk.new)

    assert_equal false, cr.iso_detach(UUID)
    assert_not(fog.calls.any? { |c| c.first == :eject_vm_dvd_drive })
  end

  test 'iso_detach refuses a blank uuid before any fog call' do
    cr, fog = build_cr(FogBootdisk.new)

    assert_raises(ArgumentError) { cr.iso_detach('') }
    assert_empty fog.calls
  end

  # ---- iso_delete --------------------------------------------------------------

  test 'iso_delete removes the host-side file from every root the host reported and answers whether anything went' do
    fog = FogBootdisk.new(remove_answers: { 'c:\vms\host.example.com.iso' => true })
    cr, = build_cr(fog)

    assert_equal true, cr.iso_delete('/tmp/foreman-d0x/host.example.com.iso', UUID)
    removes = fog.calls.select { |c| c.first == :remove_file }
    swept = removes.map { |c| [c[1], c[2]] }
    assert_equal [['C:\VMs\host.example.com.iso', 'C:\VMs'],
                  ['C:\ClusterStorage\Volume1\host.example.com.iso', 'C:\ClusterStorage\Volume1']], swept
  end

  test 'iso_delete answers false — not a raise — when every root was already clean' do
    cr, = build_cr(FogBootdisk.new)

    assert_equal false, cr.iso_delete('/tmp/foreman-d0x/host.example.com.iso', UUID)
  end

  test 'iso_delete refuses naming :contained_file_removal when the fog cannot scope a delete' do
    cr, fog = build_cr(FogNoRemove.new)

    error = assert_raises(ForemanHyperv::OperationRefused) { cr.iso_delete('/tmp/x/host.example.com.iso', UUID) }
    assert_includes error.message, 'contained_file_removal'
    assert_empty fog.calls
  end

  test 'iso_delete refuses when the host reports no roots at all rather than deleting nowhere' do
    cr, = build_cr(FogBootdisk.new, roots: [])

    assert_raises(ForemanHyperv::OperationRefused) { cr.iso_delete('/tmp/x/host.example.com.iso', UUID) }
  end

  test 'iso_delete refuses a blank uuid or an empty basename with ArgumentError' do
    cr, fog = build_cr(FogBootdisk.new)

    assert_raises(ArgumentError) { cr.iso_delete('/tmp/x/host.iso', '') }
    assert_raises(ArgumentError) { cr.iso_delete('', UUID) }
    assert_empty fog.calls
  end

  # ---- the capability split -----------------------------------------------------

  test 'the bootdisk capabilities sit on the opt-in side: predicate-less words, gated on constant plus method' do
    # The pin in HypervEnablementTest owns the split itself; what belongs HERE
    # is the proof that the two bootdisk words are usable with no supports_*?
    # predicate anywhere (the enablement side is predicate-paired — putting
    # these there would refuse every unlocked operation against the deployed
    # fog, which defines neither predicate).
    # fog pairs no predicate with the bootdisk words (checked against the deployed gem).
    assert_not Fog::Hyperv::Compute::Real.method_defined?(:supports_file_pull?)
    assert_not Fog::Hyperv::Compute::Real.method_defined?(:supports_contained_file_removal?)
    assert_includes Fog::Hyperv::CAPABILITIES, :file_pull
    assert_includes Fog::Hyperv::CAPABILITIES, :contained_file_removal
  end
end
