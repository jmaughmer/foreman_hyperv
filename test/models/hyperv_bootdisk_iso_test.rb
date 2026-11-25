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
# Round 17 (REQUEST_CHANGES) folded three semantics back in, all of them
# proven by core code, not taste: (1) the after_build steps run INSIDE the
# /unattended/built save and core fails the whole save on a falsy step answer
# (evidence/core-orchestration.rb:149), so detach and delete — cleanup steps
# that run on EVERY build and are legitimately "nothing to do" most times —
# answer true always and log what they skipped; attach and upload keep
# raising, because a bootdisk that did not mount is a build that must not
# complete. (2) The machine is read through fog's own shape (state/generation
# enums, computer_name) and the ride refuses a machine that is not Off, not
# UEFI, or hosted on a cluster node this endpoint cannot write — the same
# fail-closed node rule every other cluster operation rides. (3) The staged
# file is chmod 0644 + fsynced BEFORE the flip into the served root, and the
# URL is computed BEFORE anything is written, so a blank unattended URL cannot
# orphan a served ISO.
#
# Capability gates, never versions (the fork's rule): the pull is refused when
# the fog answers neither the :file_pull constant nor fetch_url_to_path, and
# the scoped delete likewise for :contained_file_removal/remove_file — the
# gate copies the cluster-role style, and these words sit on the plugin's
# opt-in side, never the enablement six (fog pairs no supports_*? predicate
# with them, and a predicate-less entry on the enablement side would answer
# "missing" and refuse every unlocked operation).
#
# fog is a recording stub here (the fork's Fog.mock! ban); every refusal is
# asserted to happen BEFORE any fog call. The machine stub answers in the
# shapes fog's server model MEASURES (state/generation are hypervenum symbols,
# computer_name is the node that answered) — round 17's point #2 was that the
# previous stub answered a power_state no Hyper-V server has.
class HypervBootdiskIsoTest < ActiveSupport::TestCase
  UUID = '1c51c4ee-df90-4cee-a9f7-218888711248'
  CR_URL = 'https://hyperv.example.com:5985'
  BOOT_ORDER_ROWS = [
    { position: 1, boot_type: 'Network', device_text: 'VMNetworkAdapter (Name =  Ethernet 0)',
      device_id: 'Microsoft:1', firmware_path: '' },
    { position: 2, boot_type: 'Drive', device_text: 'HardDiskDrive (Name = disk.vhdx)',
      device_id: 'Microsoft:2', firmware_path: '' },
    { position: 3, boot_type: 'File', device_text: '', device_id: '', firmware_path: '\EFI\BOOT\BOOTX64.EFI' }
  ].freeze

  # Answers what Fog::Hyperv::Compute::Server really exposes (server.rb): the
  # hypervenum symbols for state and generation, and the computer_name of the
  # node that printed the row — the same reading_node input every other
  # cluster decision in this plugin uses.
  class MachineStub
    attr_reader :id, :state, :generation, :computer_name

    def initialize(id = HypervBootdiskIsoTest::UUID, state: :Off, generation: :UEFI,
                   computer_name: 'HV-NODE1', secure_boot: false)
      @id = id
      @state = state
      @generation = generation
      @computer_name = computer_name
      @secure_boot = secure_boot
    end

    # PR-5: the ride refuses Secure Boot off the LIVE machine, and the live
    # read is FogExtensions::Hyperv::Server#foreman_firmware_type
    # (fog_extensions/hyperv/server.rb:81-85) — 'bios' for Gen1,
    # 'uefi_secure_boot' only when the firmware reads back on. The stub
    # answers the REAL model's shape, which is why this file changes with the
    # implementation rather than silently passing on a model-shaped stub that
    # never grew the method.
    def foreman_firmware_type
      return 'bios' if generation == :BIOS

      @secure_boot ? 'uefi_secure_boot' : 'uefi'
    end
  end

  setup do
    @served = Dir.mktmpdir('bd-served')
    @staging = Dir.mktmpdir('bd-staging')
    ForemanHyperv::BootdiskTransfer.served_root = @served
    ForemanHyperv::BootdiskTransfer.staging_root = @staging
    Setting.stubs(:[]).returns('http://foreman.test')
    # PR-3 added the drop-in check inside stage() (the installer purge,
    # measured; PR-3 review added the Alias-target half). This suite tests the
    # STORE, not the endpoint: answer the check satisfied and let
    # hyperv_bootdisk_endpoint_test own that contract. Without this the real
    # /etc on the CI box (purged by the last foreman-installer run) refuses
    # every stage here.
    ForemanHyperv::BootdiskTransfer.stubs(:apache_snippet_serves?).returns(true)
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
    attr_accessor :dvd_rows, :fetch_answer, :remove_answers, :boot_rows,
                  :raise_eject, :raise_remove_paths

    # dvd_rows carries fog's MEASURED live answers: nil (no drive), ONE bare
    # Hash (the VM has one drive), an Array of Hashes (several).
    def initialize(dvd_rows: { id: 'dvd-1', vm_id: HypervBootdiskIsoTest::UUID, path: nil },
                   fetch_answer: nil, remove_answers: {}, boot_rows: HypervBootdiskIsoTest::BOOT_ORDER_ROWS)
      @calls = []
      @dvd_rows = dvd_rows
      @fetch_answer = fetch_answer
      @remove_answers = remove_answers
      @boot_rows = boot_rows
      @raise_eject = false
      @raise_remove_paths = []
    end

    # The enablement six, answered true (the era partnership the pull and the
    # attach ride; see HypervEnablementTest for what they mean).
    def supports_clusters? = true
    def supports_exact_host_connections? = true
    def supports_literal_path_destructive? = true
    def supports_stdout_json_hygiene? = true
    def supports_input_hardening? = true
    def supports_cluster_capacity_projection? = true

    def get_vm_dvd_drive(vm_id:, **_rest)
      @calls << [:get_vm_dvd_drive, vm_id]
      @dvd_rows
    end

    def add_vm_dvd_drive(vm_id:, **options)
      @calls << [:add_vm_dvd_drive, vm_id, options]
      { id: 'dvd-new', vm_id: vm_id, path: nil }
    end

    def set_vm_dvd_drive(id:, vm_id:, path:, **options)
      @calls << [:set_vm_dvd_drive, id, vm_id, path, options]
      true
    end

    def eject_vm_dvd_drive(id:, vm_id:, **_rest)
      @calls << [:eject_vm_dvd_drive, id, vm_id]
      raise Fog::Hyperv::Errors::PSError, 'eject failed (test)' if @raise_eject

      true
    end

    def get_vm_boot_order(vm_id:, **_rest)
      @calls << [:get_vm_boot_order, vm_id]
      @boot_rows
    end

    def set_vm_boot_order(vm_id:, order:, **options)
      @calls << [:set_vm_boot_order, vm_id, order, options]
      order
    end

    def fetch_url_to_path(url:, path:, sha256:, size:)
      @calls << [:fetch_url_to_path, url, path, sha256, size]
      fetch_answer.nil? ? size : fetch_answer
    end

    def remove_file(path:, root:)
      @calls << [:remove_file, path, root]
      raise Fog::Hyperv::Errors::PSError, 'remove failed (test)' if @raise_remove_paths.include?(path)

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

  class FogNoBootOrder < FogBootdisk
    undef_method :set_vm_boot_order if method_defined?(:set_vm_boot_order)
  end

  # An era fog missing one enablement predicate: the pull and attach refuse.
  class FogNoEra < FogBootdisk
    def supports_input_hardening? = false
  end

  def build_cr(fog, roots: ['C:\VMs', 'C:\ClusterStorage\Volume1'], state: :Off,
               generation: :UEFI, sb: false,
               machine: MachineStub.new(UUID, state: state, generation: generation, secure_boot: sb),
               cluster: nil, serves: true)
    cr = ForemanHyperv::Hyperv.new(name: 'lab-cr', url: CR_URL, user: 'u', password: 'p')
    cr.stubs(:client).returns(fog)
    cr.stubs(:storage_roots).returns(roots)
    cr.stubs(:find_vm_by_uuid).returns(machine)
    cr.stubs(:endpoint_cluster).returns(cluster)
    cr.stubs(:endpoint_serves_node?).returns(serves)
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
    staged = ForemanHyperv::BootdiskTransfer.stage(src, machine: UUID)

    assert_match(/\A[0-9a-f]{32}\z/, staged.nonce)
    assert File.file?(src), 'stage COPIES: the worker still owns its ISO (EXDEV across PrivateTmp forbids the rename)'
    final = File.join(@served, "#{staged.nonce}.iso")
    assert File.file?(final), 'the served placement is <nonce>.iso under the served root'
    assert_equal File.binread(src), File.binread(final)
    assert Dir.children(@staging).none? { |f| f.end_with?('.part') }, 'no temp survivor in the staging root'
  end

  test 'the sidecar follows the janitor contract: staging- name in the unserved root, host and verifiers inside' do
    src = make_iso(@staging)
    staged = ForemanHyperv::BootdiskTransfer.stage(src, machine: UUID)

    sidecar = File.join(@staging, "staging-#{staged.nonce}.json")
    assert File.file?(sidecar),
           'sidecars match the staging-* pattern PR-4 janitor will sweep, in the root Apache cannot serve'
    meta = JSON.parse(File.read(sidecar))
    assert_equal staged.nonce, meta['nonce']
    assert_equal UUID, meta['machine'], 'the sidecar names the machine the ride is for (plan v10 Decision 4)'
    assert_equal staged.sha256, meta['sha256']
    assert_equal staged.bytes, meta['bytes']
    assert_equal File.basename(src), meta['source']
    # The janitor's age decision reads MTIME, never this field — but it is
    # recorded, and an unparseable value here must not be a timestamp at all.
    assert_kind_of String, meta['staged_at']
    # The digest describes the bytes that were SERVED, not the worker's file:
    # equal here because the copy is byte-identical, pinned because the
    # verifier fog checks is THIS value.
    assert_equal Digest::SHA256.file(File.join(@served, "#{staged.nonce}.iso")).hexdigest, staged.sha256
  end

  test 'the served copy is world-readable 0644 and fsynced before the flip, whatever the source mode was' do
    src = make_iso(@staging)
    File.chmod(0o600, src) # a PrivateTmp worker under a 077 umask generates exactly this

    staged = ForemanHyperv::BootdiskTransfer.stage(src, machine: UUID)
    mode = File.stat(File.join(@served, "#{staged.nonce}.iso")).mode & 0o777

    assert_equal 0o644, mode, 'Apache (PR-3 Alias) must be able to read the shelf file whatever the worker umask was'
  end

  test 'a blank unattended URL refuses BEFORE anything is staged — no orphan can enter the served root' do
    Setting.stubs(:[]).with(:unattended_url).returns('')
    src = make_iso(Dir.mktmpdir('bd-src'))

    assert_raises(ForemanHyperv::OperationRefused) { ForemanHyperv::BootdiskTransfer.stage(src, machine: UUID) }
    assert_empty Dir.children(@served), 'the URL is computed before the first write: a refused stage leaves no orphan'
    assert_empty Dir.children(@staging)
  end

  test 'a failed flip cleans the temp AND the sidecar, not just the temp' do
    src = make_iso(Dir.mktmpdir('bd-src'))
    FileUtils.stubs(:mv).raises(Errno::EACCES)

    assert_raises(Errno::EACCES) { ForemanHyperv::BootdiskTransfer.stage(src, machine: UUID) }
    assert_empty Dir.children(@staging), 'a sidecar whose ISO never landed is a sidecar the janitor would chase forever'
    assert_empty Dir.children(@served), 'nothing reached the root Apache serves'
  end

  test 'a cross-filesystem flip that fails mid-copy leaves NO partial file in the served root' do
    src = make_iso(Dir.mktmpdir('bd-src'))
    # A cross-device FileUtils.mv is copy-then-unlink: it writes into the REAL
    # target name and can fail partway (round 19, finding N1). Mocha's stub
    # block is not an implementation hook, so the real method is replaced for
    # the duration of the test and restored after.
    original = FileUtils.method(:mv)
    FileUtils.define_singleton_method(:mv) do |_from, to|
      FileUtils.touch(to)
      raise Errno::EACCES
    end

    assert_raises(Errno::EACCES) { ForemanHyperv::BootdiskTransfer.stage(src, machine: UUID) }
    assert_empty Dir.children(@served),
                 'the served root holds ONLY complete files: a half-written flip target is swept too'
    assert_empty Dir.children(@staging)
  ensure
    FileUtils.define_singleton_method(:mv, original)
  end

  test 'the stage url is the unattended URL plus the nonce path' do
    staged = ForemanHyperv::BootdiskTransfer.stage(make_iso(@staging))
    assert_equal "http://foreman.test/bootdisk-pull/#{staged.nonce}.iso", staged.url
  end

  test 'discard removes the served ISO and its sidecar, and is an answer-free no-op when they are gone' do
    src = make_iso(Dir.mktmpdir('bd-src'))
    staged = ForemanHyperv::BootdiskTransfer.stage(src, machine: UUID)
    ForemanHyperv::BootdiskTransfer.discard(staged.nonce)
    assert_empty Dir.children(@served)
    assert_empty Dir.children(@staging)
    assert File.file?(src), 'discard takes the shelf, never the copy the worker still owns'
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

  test 'iso_upload answers the gate refusals before reading roots or the machine at all' do
    iso = make_iso(Dir.mktmpdir('bd-iso'))
    cr, fog = build_cr(FogNoPull.new)
    # Both reads would CRASH if attempted: the refusal must be decided by the
    # gates alone (round 17 verified storage_roots used to make WinRM reads
    # before the era gate — the tests only saw "no fog calls" because it was
    # stubbed to answer politely).
    cr.stubs(:storage_roots).raises(StandardError, 'roots must not be read before the gates')
    cr.stubs(:find_vm_by_uuid).raises(StandardError, 'the machine must not be read before the gates')

    error = assert_raises(ForemanHyperv::OperationRefused) { cr.iso_upload(iso, UUID, storage_id: 'C:\VMs') }
    assert_includes error.message, 'file_pull'
    assert_empty fog.calls
  end

  test 'iso_upload refuses a machine that is not Off before staging anything — a refused rebuild pulls no 245 MB' do
    iso = make_iso(Dir.mktmpdir('bd-iso'))
    cr, fog = build_cr(FogBootdisk.new, state: :Running)

    error = assert_raises(ForemanHyperv::OperationRefused) { cr.iso_upload(iso, UUID, storage_id: 'C:\VMs') }
    assert_includes error.message, :Running.inspect
    assert_empty fog.calls
    assert_empty Dir.children(@served)
  end

  test 'iso_upload refuses a Gen1 (BIOS) machine: the boot-order write this ride ends in is UEFI-only' do
    iso = make_iso(Dir.mktmpdir('bd-iso'))
    cr, fog = build_cr(FogBootdisk.new, generation: :BIOS)

    error = assert_raises(ForemanHyperv::OperationRefused) { cr.iso_upload(iso, UUID, storage_id: 'C:\VMs') }
    assert_includes error.message, :BIOS.inspect
    assert_empty fog.calls
  end

  test 'iso_upload refuses when the machine answers no server at all, naming the uuid' do
    iso = make_iso(Dir.mktmpdir('bd-iso'))
    cr, = build_cr(FogBootdisk.new, machine: nil)

    error = assert_raises(ForemanHyperv::OperationRefused) { cr.iso_upload(iso, UUID, storage_id: 'C:\VMs') }
    assert_includes error.message, UUID
  end

  test 'iso_upload on a clustered CR refuses a machine hosted on a node this endpoint cannot write' do
    iso = make_iso(Dir.mktmpdir('bd-iso'))
    cr, fog = build_cr(FogBootdisk.new, cluster: Object.new, serves: false)

    error = assert_raises(ForemanHyperv::OperationRefused) { cr.iso_upload(iso, UUID, storage_id: 'C:\VMs') }
    assert_includes error.message, 'HV-NODE1', 'the refusal names the node the machine answered from'
    assert_empty fog.calls
    assert_empty Dir.children(@served)
  end

  test 'iso_upload works on a clustered CR when the endpoint node itself hosts the machine' do
    iso = make_iso(Dir.mktmpdir('bd-iso'))
    cr, fog = build_cr(FogBootdisk.new, cluster: Object.new, serves: true)

    assert_equal File.size(iso), cr.iso_upload(iso, UUID, storage_id: 'C:\VMs')
    assert(fog.calls.any? { |c| c.first == :fetch_url_to_path })
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

  test 'iso_upload reads the reported roots exactly once even when it refuses' do
    iso = make_iso(Dir.mktmpdir('bd-iso'))
    cr, = build_cr(FogBootdisk.new)
    cr.expects(:storage_roots).once.returns(['C:\VMs'])

    assert_raises(ArgumentError) { cr.iso_upload(iso, UUID, storage_id: 'D:\Elsewhere') }
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

  test 'iso_attach reads every shape fog answers and takes the first drive of a list' do
    fog = FogBootdisk.new(dvd_rows: [{ id: 'dvd-a', vm_id: UUID, path: nil },
                                     { id: 'dvd-b', vm_id: UUID, path: nil }])
    cr, = build_cr(fog)

    cr.iso_attach('host.example.com.iso', UUID, storage_id: 'C:\VMs')

    written = [:set_vm_dvd_drive, 'dvd-a', UUID, 'C:\VMs\host.example.com.iso', { computer_name: 'HV-NODE1' }]
    assert_includes fog.calls, written
  end

  test 'iso_attach sets the media on the drive the VM has and puts the DVD first, existing classes behind it' do
    cr, fog = build_cr(FogBootdisk.new)

    cr.expects(:storage_roots).once.returns(['C:\VMs'])
    cr.iso_attach('host.example.com.iso', UUID, storage_id: 'C:\VMs')

    written = [:set_vm_dvd_drive, 'dvd-1', UUID, 'C:\VMs\host.example.com.iso', { computer_name: 'HV-NODE1' }]
    assert_includes fog.calls, written,
                    'the ride threads the machine-owning node into every drive write (round 19, finding 4)'
    assert_not(fog.calls.any? { |c| c.first == :add_vm_dvd_drive }, 'the VM already has a DVD drive; one more is a bug')
    set = fog.calls.find { |c| c.first == :set_vm_boot_order }
    assert_not_nil set
    # DVD first; then the read classes in read order. File entries are not requestable and
    # fog's write script keeps unrequested entries' positions — dropping one preserves it.
    assert_equal [{ 'DvdDrive' => 'dvd-1' }, 'VMNetworkAdapter', 'HardDiskDrive'], set[2]
  end

  test 'iso_attach adds the drive when the VM has none and drives the whole sequence off the new drive id' do
    fog = FogBootdisk.new(dvd_rows: nil)
    cr, = build_cr(fog)

    cr.iso_attach('host.example.com.iso', UUID, storage_id: 'C:\VMs')

    assert(fog.calls.any? { |c| c.first == :add_vm_dvd_drive })
    written = [:set_vm_dvd_drive, 'dvd-new', UUID, 'C:\VMs\host.example.com.iso', { computer_name: 'HV-NODE1' }]
    assert_includes fog.calls, written
    set = fog.calls.find { |c| c.first == :set_vm_boot_order }
    assert_equal 'dvd-new', set[2].first['DvdDrive']
  end

  test 'iso_attach refuses a machine that is not powered off, rendering the state fog answered' do
    cr, fog = build_cr(FogBootdisk.new, state: :Running)

    error = assert_raises(ForemanHyperv::OperationRefused) do
      cr.iso_attach('host.example.com.iso', UUID, storage_id: 'C:\VMs')
    end
    # server.state is the fog enum that decided it; Hyper-V servers have no power_state.
    assert_includes error.message, :Running.inspect
    assert_empty fog.calls
  end

  test 'iso_attach refuses a Gen1 (BIOS) machine: fog boot-order writes are the UEFI surface' do
    cr, fog = build_cr(FogBootdisk.new, generation: :BIOS)

    error = assert_raises(ForemanHyperv::OperationRefused) { cr.iso_attach('x.iso', UUID, storage_id: 'C:\VMs') }
    assert_includes error.message, :BIOS.inspect
    assert_empty fog.calls
  end

  # PR-5's LIVE Secure-Boot seam. The create-time refusal (optin suite) reads
  # the create attrs because there is no VM yet; rebuilds and externally-
  # flipped firmware are exactly what that seam cannot see, so the ride also
  # refuses off the live model's foreman_firmware_type. The attach step only
  # ever runs inside the bootdisk flow, so this refusal cannot touch a
  # non-bootdisk host.
  test 'iso_attach refuses a machine whose LIVE firmware reads Secure Boot on: the shim media cannot boot under it' do
    cr, fog = build_cr(FogBootdisk.new, sb: true)

    error = assert_raises(ForemanHyperv::OperationRefused) { cr.iso_attach('x.iso', UUID, storage_id: 'C:\VMs') }
    assert_includes error.message, 'Secure Boot'
    assert_empty fog.calls
  end

  test 'iso_upload refuses the same Secure Boot machine before staging — the shared ride gate, one step earlier' do
    iso = make_iso(Dir.mktmpdir('bd-iso'))
    cr, fog = build_cr(FogBootdisk.new, sb: true)

    error = assert_raises(ForemanHyperv::OperationRefused) { cr.iso_upload(iso, UUID, storage_id: 'C:\VMs') }
    assert_includes error.message, 'Secure Boot'
    assert_empty fog.calls
    assert_empty Dir.children(@served), 'a refused ride stages nothing'
  end

  test 'iso_attach refuses a clustered machine the endpoint node does not host, naming its node' do
    cr, fog = build_cr(FogBootdisk.new, cluster: Object.new, serves: false)

    error = assert_raises(ForemanHyperv::OperationRefused) { cr.iso_attach('x.iso', UUID, storage_id: 'C:\VMs') }
    assert_includes error.message, 'HV-NODE1'
    assert_empty fog.calls
  end

  test 'iso_attach refuses a fog that cannot send the boot-order write, naming what is missing' do
    cr, fog = build_cr(FogNoBootOrder.new)

    error = assert_raises(ForemanHyperv::OperationRefused) { cr.iso_attach('x.iso', UUID, storage_id: 'C:\VMs') }
    assert_includes error.message, 'set_vm_boot_order'
    assert_empty fog.calls
  end

  test 'iso_attach refuses a path-shaped or traversing name with ArgumentError' do
    cr, fog = build_cr(FogBootdisk.new)

    assert_raises(ArgumentError) { cr.iso_attach('sub\host.iso', UUID, storage_id: 'C:\VMs') }
    assert_raises(ArgumentError) { cr.iso_attach('sub/host.iso', UUID, storage_id: 'C:\VMs') }
    assert_raises(ArgumentError) { cr.iso_attach('..', UUID, storage_id: 'C:\VMs') }
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

  test 'iso_attach refuses missing inputs with ArgumentError and touches nothing' do
    cr, fog = build_cr(FogBootdisk.new)

    assert_raises(ArgumentError) { cr.iso_attach('', UUID, storage_id: 'C:\VMs') }
    assert_raises(ArgumentError) { cr.iso_attach('x.iso', '', storage_id: 'C:\VMs') }
    assert_raises(ArgumentError) { cr.iso_attach('x.iso', UUID, storage_id: nil) }
    assert_empty fog.calls
  end

  # ---- iso_detach ---------------------------------------------------------------
  #
  # after_build semantics (round 17, finding 3): the answer runs INSIDE the
  # /unattended/built save and core fails the whole save on false — the host
  # would sit in build mode with a live token forever. Detach runs for EVERY
  # build, bootdisk or not, so "nothing to do" and "the host refused" are both
  # logged, never a failed save.

  test 'iso_detach ejects the media the drive is holding and answers true' do
    fog = FogBootdisk.new(dvd_rows: { id: 'dvd-1', vm_id: UUID, path: 'C:\VMs\host.example.com.iso' })
    cr, = build_cr(fog)

    assert_equal true, cr.iso_detach(UUID)
    assert_includes fog.calls, [:eject_vm_dvd_drive, 'dvd-1', UUID]
  end

  test 'iso_detach answers TRUE (not false) when nothing is in any drive — false would fail the built save' do
    cr, fog = build_cr(FogBootdisk.new)

    assert_equal true, cr.iso_detach(UUID)
    assert_not(fog.calls.any? { |c| c.first == :eject_vm_dvd_drive })
  end

  test 'iso_detach answers TRUE when the host refuses the eject, and the refusal is logged not raised' do
    fog = FogBootdisk.new(dvd_rows: { id: 'dvd-1', vm_id: UUID, path: 'C:\VMs\host.example.com.iso' })
    fog.raise_eject = true
    cr, = build_cr(fog)
    cr.stubs(:logger).returns(stub(warn: nil, info: nil, debug: nil, error: nil))

    assert_nothing_raised { assert_equal true, cr.iso_detach(UUID) }
  end

  test 'iso_detach answers TRUE on a fog too old to send the eject: cleanup never wedges a build in build mode' do
    cr, fog = build_cr(FogNoEra.new)
    cr.stubs(:logger).returns(stub(warn: nil, info: nil, debug: nil, error: nil))

    assert_equal true, cr.iso_detach(UUID)
    assert_empty fog.calls
  end

  test 'iso_detach refuses a blank uuid before any fog call' do
    cr, fog = build_cr(FogBootdisk.new)

    assert_raises(ArgumentError) { cr.iso_detach('') }
    assert_empty fog.calls
  end

  # ---- iso_delete ---------------------------------------------------------------
  #
  # Same after_build rule as detach, plus the permanent-wedge case: delete(53)
  # runs AFTER detach(52) already ejected, so it cannot read a path and must
  # sweep the reported roots — and any raise here makes every later built
  # retry fail at 52 with nothing left to eject.

  test 'iso_delete sweeps the basename out of every root the host reported and answers true' do
    fog = FogBootdisk.new(remove_answers: { 'c:\vms\host.example.com.iso' => true })
    cr, = build_cr(fog)

    assert_equal true, cr.iso_delete('/tmp/foreman-d0x/host.example.com.iso', UUID)
    removes = fog.calls.select { |c| c.first == :remove_file }
    swept = removes.map { |c| [c[1], c[2]] }
    assert_equal [['C:\VMs\host.example.com.iso', 'C:\VMs'],
                  ['C:\ClusterStorage\Volume1\host.example.com.iso', 'C:\ClusterStorage\Volume1']], swept
  end

  test 'iso_delete answers TRUE when every root was already clean — absence is the common answer, not a failure' do
    cr, = build_cr(FogBootdisk.new)

    assert_equal true, cr.iso_delete('/tmp/foreman-d0x/host.example.com.iso', UUID)
  end

  test 'iso_delete keeps sweeping when one root raises, and the whole step still answers true' do
    fog = FogBootdisk.new
    fog.raise_remove_paths = ['C:\VMs\host.example.com.iso']
    cr, = build_cr(fog)
    cr.stubs(:logger).returns(stub(warn: nil, info: nil, debug: nil, error: nil))

    assert_equal true, cr.iso_delete('/tmp/foreman-d0x/host.example.com.iso', UUID)
    assert(fog.calls.any? { |c| c.first == :remove_file && c[2] == 'C:\ClusterStorage\Volume1' },
           'one root refusing must not stop the sweep of the rest')
  end

  test 'iso_delete answers TRUE and logs when the fog cannot scope a delete' do
    cr, fog = build_cr(FogNoRemove.new)
    cr.stubs(:logger).returns(stub(warn: nil, info: nil, debug: nil, error: nil))

    assert_equal true, cr.iso_delete('/tmp/x/host.example.com.iso', UUID)
    assert_empty fog.calls
  end

  test 'iso_delete answers TRUE and logs when the host reports no roots rather than failing the save' do
    cr, = build_cr(FogBootdisk.new, roots: [])
    cr.stubs(:logger).returns(stub(warn: nil, info: nil, debug: nil, error: nil))

    assert_equal true, cr.iso_delete('/tmp/x/host.example.com.iso', UUID)
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
