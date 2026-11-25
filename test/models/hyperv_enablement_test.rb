# frozen_string_literal: true

require 'test_helper'
require 'active_support/test_case'
require 'ostruct'

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

# PLG-22: the enablement. With FOG-10/11/14/15, PLG-15b/15c/21b/5a and FOG-9
# merged and fog deployed at the pinned build, the plugin's remaining refusals
# lift — but they lift CONDITIONALLY, on the fog actually installed: every
# unlocked operation first PROVIDE-checks the era STATICALLY (the CAPABILITIES
# constant AND respond_to? on each supports_*? fingerprint — PLG-38: no
# predicate is ever called; a predicate's answer is endpoint state, not era),
# and a fog missing any of them gets the pre-enablement refusals verbatim,
# word for word, in the pre-enablement order (a cluster ask refused before
# the endpoint is read; the stand-alone create gate refusing before any
# placement membership is consulted). Enablement is a property of the
# fog+plugin PAIR.
#
# The destructive decisions are made entirely plugin-side, before anything is
# mutated:
#  * the config folder is deleted with the machine ONLY when its name is the
#    machine's name, it sits directly under a root the HYPERVISOR itself named
#    (virtual_machine_path, virtual_hard_disk_path — the two roots, which the
#    lab measured to differ — or a cluster shared volume), spelled out in full
#    (an 8.3 short-name root is an alias and attributes nothing), the name
#    carries nothing a filesystem read could not tie back (path or wildcard
#    characters, a `..` segment, a trailing `.` or space), AND the wire
#    pre-flight — fog's literal-path Test-Path/Get-Item/Get-ChildItem in ONE
#    script — answers present, not a reparse point, not hidden, and its
#    every *.vmcx/*.vmrs (GUID-named, one level down in the real layout)
#    is attributed to this machine's id or name, with at least one .vmcx present;
#  * a disk file is deleted only when its parent is the machine's attributed
#    folder or a hypervisor-named root (call-site check) AND its
#    support_persistent_reservations reads false — fog's own model refuses
#    underlying: true otherwise, and an explicit removal that cannot prove
#    this refuses the WHOLE edit rather than half-completing;
#  * a destroy that would recurse over a kept disk file inside the machine's
#    folder keeps the folder: the recursion would take the survivor silently.
#
# F2 rides here: when the enablement stands, the clustered role removal is
# composed as a TWO-ELEMENT cmdlist whose first element is a node-identity
# guard ($env:COMPUTERNAME must answer one of the named node's accepted
# names — the NETBIOS truncation is accepted because that is what the
# variable carries for names over 15 characters) and whose second element is
# fog's own read-back-proven removal script. Every connection shell is its
# own shell (measured), so guard and mutation ride together or the guard
# proves nothing. An honest limit, stated: fog model-internal mutations do
# not take a plugin-supplied guard; the six capability predicates plus
# FOG-11's completion gate are what bind those to the named host.
class HypervEnablementTest < ActiveSupport::TestCase
  # The fog answer shapes, spelled out: the suites assert on their fields and
  # nothing else, so a plain struct is exactly the surface.
  Reply = Struct.new(:stdout, :exit_code, :error, keyword_init: true)
  StubHypervisor = Struct.new(:name, :virtual_machine_path, :virtual_hard_disk_path, keyword_init: true)
  StubCluster = Struct.new(:name, :shared_volumes, keyword_init: true)
  StubVolume = Struct.new(:volume_path, keyword_init: true)

  CR_URL = 'http://192.168.1.66:5985/wsman'
  GUID = '6f1e9a12-3b4c-4d5e-8f60-112233445566'

  def setup
    unless FOREMAN_BOOT || (defined?(Rails) && Rails.application)
      skip 'Needs a booted Foreman (rake test:plugins): these cover model-level enablement semantics.'
    end
    begin
      require 'mocha/minitest'
    rescue LoadError
      skip 'mocha is not available outside the Foreman bundle.'
    end
  end

  # A fog that provides everything the enablement stands on: the CAPABILITIES
  # constant AND the six predicates. The cluster probe answers true by default
  # because some cluster-path suites read through it; the ANSWER is endpoint
  # state, and the era check does not consult it (PLG-38) — the enablement
  # tests carry both shapes (clustered and stand-alone) on purpose.
  class FogFull
    attr_reader :calls

    def initialize(stdout: '', exit_code: 0, clustered: true)
      @calls = []
      @stdout = stdout
      @exit_code = exit_code
      @clustered = clustered
    end

    def supports_clusters? = @clustered
    def supports_exact_host_connections? = true
    def supports_literal_path_destructive? = true
    def supports_stdout_json_hygiene? = true
    def supports_input_hardening? = true
    def supports_cluster_capacity_projection? = true

    def remove_cluster_virtual_machine_role(**args)
      @calls << [:remove_cluster_virtual_machine_role, args]
    end

    def run_cmdlist(cmds, skip_json:, target_computer:, _separate_calls: false)
      @calls << [:run_cmdlist, cmds, skip_json, target_computer]
      Reply.new(stdout: @stdout, exit_code: @exit_code, error: '')
    end
  end

  # The full client minus one behaviour's fingerprint. The fingerprint-to-
  # capability names come from the plugin's own frozen map, so the helper
  # cannot drift from it. PLG-38: the era check never CALLS a predicate, so
  # the shape that removes a behaviour is the ABSENCE of the fingerprint —
  # a pre-era client does not provide what the era fog's build ships.
  class FogMissing < FogFull
    def initialize(missing:, **kwargs)
      super(**kwargs)
      @absent = ForemanHyperv::Hyperv::ENABLEMENT_CAPABILITIES.fetch(missing)
    end

    def respond_to?(name, *include_all)
      name.to_sym == @absent ? false : super
    end
  end

  # The machine destroy and the volume edit see: a sequence recorder, like
  # the PLG-15 tests. The service is the machine's own, and records the same
  # way: run_cmd answers the folder pre-flight, run_cmdlist carries the
  # guarded role removal.
  class FakeVm
    attr_accessor :role_stdout

    def initialize(name:, path:, drives:, clustered: false, owner_node: nil, preflight: 'ABSENT')
      @name = name
      @path = path
      @drives = drives
      @clustered = clustered
      @owner_node = owner_node
      @preflight = preflight
      @role_stdout = ''
      @calls = []
      @service = FakeService.new(self)
    end

    attr_reader :calls, :name, :path, :owner_node, :service, :preflight

    def id = GUID
    def computer_name = 'hv-node1'
    def clustered? = @clustered

    def set_preflight(answer)
      @preflight = answer
    end

    def hard_drives
      list = @drives
      collection = Object.new
      collection.define_singleton_method(:each) { |&blk| list.each(&blk) }
      collection.define_singleton_method(:any?) { |&blk| list.any?(&blk) }
      collection.define_singleton_method(:get) { |id| list.find { |d| d.id == id } }
      collection
    end

    def stop(**_args)
      @calls << :stop
    end

    def destroy(folder)
      @calls << [:destroy, folder]
    end

    class FakeService
      def initialize(vm)
        @vm = vm
      end

      def run_cmd(script, _skip_json: false)
        @vm.calls << [:run_cmd, script]
        Reply.new(stdout: @vm.preflight, exit_code: 0, error: '')
      end

      def run_cmdlist(cmds, skip_json:, target_computer:, _separate_calls: false)
        @vm.calls << [:run_cmdlist, cmds, skip_json, target_computer]
        Reply.new(stdout: @vm.role_stdout, exit_code: 0, error: '')
      end
    end
  end

  class FakeHdd
    attr_reader :calls, :id, :path

    def initialize(id, path, reservations: false)
      @id = id
      @path = path
      @reservations = reservations
      @calls = []
    end

    def support_persistent_reservations = @reservations

    def destroy(underlying:)
      @calls << underlying
    end
  end

  def build_cr(fog)
    cr = ForemanHyperv::Hyperv.new(name: 'lab-cr', url: CR_URL, user: 'u', password: 'p')
    cr.stubs(:client).returns(fog)
    stub_roots(cr)
    cr.stubs(:endpoint_cluster).returns(nil)
    [cr, fog]
  end

  # The roots the hypervisor itself reports: the two config/disk roots (the
  # lab measured them DIFFERENT) and one cluster shared volume.
  def stub_roots(cr, vm_root: 'C:\VMs', disk_root: 'C:\VMs\Disks')
    cr.stubs(:hypervisor).returns(StubHypervisor.new(name: 'hv-node1',
                                                     virtual_machine_path: vm_root,
                                                     virtual_hard_disk_path: disk_root))
    volume = StubVolume.new(volume_path: 'C:\ClusterStorage\Volume1')
    cr.stubs(:clusters).returns([StubCluster.new(name: 'lab-cluster', shared_volumes: [volume])])
  end

  def full_fog(**kwargs)
    FogFull.new(**kwargs)
  end

  # ---- the runtime capability check ------------------------------------------

  def test_the_capability_list_is_fogs_set_split_between_enablement_and_opt_in
    # Fog's CAPABILITIES is the union of two plugin-side kinds: the enablement
    # six — the era partnership every unlocked operation runs on — and, since
    # PLG-30, opt-in entries that gate one setting each and their column
    # words, not the era: :cluster_role_failback joined first, PLG-31b's
    # :cluster_role_owner_nodes (the preferred-owners read and its row) joins
    # the same side, and PLG-36's :cluster_role_owner_nodes_write (the
    # preferred-owners WRITE and its edit-form control) joins beside it, for
    # the same reason. The bootdisk pair joins now too, and ON THIS SIDE:
    # fog pairs no supports_*? predicate with :file_pull or
    # :contained_file_removal (the enablement side is predicate-paired, so a
    # predicate-less entry there would answer "missing" against the deployed
    # fog and refuse every unlocked operation), and each gates exactly one
    # operation pair — constant AND request method, the same rule the cluster
    # words gate by (see HypervBootdiskIsoTest). The equality is pinned whole:
    # a new fog behaviour has to join one side of this line on purpose, never
    # by accident (this is that line moving again).
    assert_equal Fog::Hyperv::CAPABILITIES.sort,
                 (ForemanHyperv::Hyperv::ENABLEMENT_CAPABILITIES.keys +
                   %i[cluster_role_failback cluster_role_owner_nodes cluster_role_owner_nodes_write
                      contained_file_removal file_pull]).sort
  end

  def test_enablement_stands_when_the_fog_provides_all_six
    cr, = build_cr(full_fog)
    assert cr.send(:enablement_supported?)
    assert_empty cr.send(:missing_enablement_capabilities)
    assert cr.send(:disk_removal_allowed?)
  end

  # PLG-38 (review F3): the era check is STATIC. supports_clusters? answers
  # endpoint state — a live query of root/mscluster — so it answers false on
  # EVERY stand-alone host, forever. When the era check called it, every
  # stand-alone host with this fog was permanently pre-enablement: bootdisk
  # refused ("missing: tri_state_cluster") and disk removal never unlocked,
  # contradicting bootdisk_ride_check!'s own promise that "a stand-alone host
  # answers no cluster and passes". Existence of the fingerprints is the era;
  # the cluster answer is not.
  def test_a_standalone_host_is_not_the_pre_enablement_era
    cr, = build_cr(full_fog(clustered: false))
    assert cr.send(:enablement_supported?),
           'a stand-alone host running the enabled fog must carry the enablement'
    assert_empty cr.send(:missing_enablement_capabilities)
    assert cr.send(:disk_removal_allowed?)
  end

  # The other half of F3: a cluster host drops out of the enablement whenever
  # the probe flaps (transport error answers false, the tri-state read answers
  # nil). A check that never calls cannot flap.
  def test_a_flapping_cluster_probe_does_not_drop_the_enablement
    fog = full_fog
    fog.define_singleton_method(:supports_clusters?) { raise 'root/mscluster unreadable' }
    cr, = build_cr(fog)
    assert cr.send(:enablement_supported?),
           'a transport flap on the cluster probe must not fall out of the era'
    assert cr.send(:disk_removal_allowed?)
  end

  # Static means NO call: every predicate is rigged to raise, and the check
  # must still stand — respond_to? is the only question it asks the client.
  def test_the_era_check_never_calls_a_capability_predicate
    fog = full_fog
    ForemanHyperv::Hyperv::ENABLEMENT_CAPABILITIES.each_value do |predicate|
      fog.define_singleton_method(predicate) { raise "#{predicate} was called by the era check" }
    end
    cr, = build_cr(fog)
    assert cr.send(:enablement_supported?),
           'the era check asked a predicate; the check must be static (PLG-38)'
  end

  def test_a_fog_missing_any_fingerprint_is_pre_enablement
    %i[tri_state_cluster exact_host_connection literal_path_destructive
       stdout_json_hygiene input_hardening cluster_capacity_projection].each do |missing|
      cr, = build_cr(FogMissing.new(missing: missing))
      assert_not cr.send(:enablement_supported?), "a fog missing #{missing} must not carry the enablement"
      assert_equal [missing], cr.send(:missing_enablement_capabilities)
      assert_not cr.send(:disk_removal_allowed?)
    end
  end

  def test_the_capability_refusal_names_the_missing_behaviours
    cr, = build_cr(FogMissing.new(missing: :stdout_json_hygiene))
    error = assert_raises(ForemanHyperv::OperationRefused) { cr.send(:refuse_without_enablement!) }
    assert_includes error.message, 'stdout_json_hygiene'
    assert_includes error.message, 'Nothing was stopped, deleted or created'
    assert_includes error.message, 'Upgrade fog-hyperv'
  end

  # ---- the two-root folder rule: the string half ------------------------------

  def attributed_vm(name: 'lab-vm2', path: 'C:\ClusterStorage\Volume1\lab-vm2',
                    clustered: true, drives: [], owner_node: nil)
    FakeVm.new(name: name, path: path, clustered: clustered, drives: drives, owner_node: owner_node)
  end

  def folder_rule(cr, vm)
    cr.send(:folder_deletion_path, vm)
  end

  def test_folder_attributed_under_either_configured_root_or_a_shared_volume
    cr, = build_cr(full_fog)
    # The shared volume: a clustered machine's home.
    assert_equal 'C:\ClusterStorage\Volume1\lab-vm2', folder_rule(cr, attributed_vm)
    # The config root AND the (measured different) disk root: the rule must
    # know both, or every machine under one of them keeps its folder.
    assert_equal 'C:\VMs\lab-vm2', folder_rule(cr, attributed_vm(clustered: false, path: 'C:\VMs\lab-vm2'))
    assert_equal 'C:\VMs\Disks\lab-vm2', folder_rule(cr, attributed_vm(clustered: false, path: 'C:\VMs\Disks\lab-vm2'))
  end

  def test_root_spelling_variants_still_attribute
    cr, = build_cr(full_fog)
    stub_roots(cr, vm_root: 'C:\\VMs\\', disk_root: 'C:/VMs/Disks')
    # Trailing separator on the root; doubled separators and forward slashes
    # in the path: all spell the same folder to the rule.
    assert_equal 'C:\VMs\lab-vm2', folder_rule(cr, attributed_vm(clustered: false, path: 'C:\VMs\\lab-vm2'))
    assert_equal 'C:\VMs\Disks\lab-vm2', folder_rule(cr, attributed_vm(clustered: false, path: 'C:/VMs/Disks/lab-vm2'))
  end

  def test_an_8_3_short_name_root_attributes_nothing
    # A PROGRA~1-style segment could alias any long name; attribution against
    # an alias is not attribution, so the folder stays even when the path
    # matches the short root the host happens to report.
    cr, = build_cr(full_fog)
    stub_roots(cr, vm_root: 'C:\PROGRA~1\VMs')
    assert_nil folder_rule(cr, attributed_vm(clustered: false, path: 'C:\PROGRA~1\VMs\lab-vm2'))
  end

  def test_the_name_shapes_the_wire_read_cannot_tie_back_keep_the_folder
    cr, = build_cr(full_fog)
    base = 'C:\\VMs\\'
    ['lab\vm', 'lab/vm', 'lab:vm', 'lab..vm', 'lab.vm.', 'lab vm ',
     'lab*vm', 'lab?vm', 'lab"vm', "lab\x01vm"].each do |name|
      assert_nil folder_rule(cr, attributed_vm(name: name, path: base + name, clustered: false)),
                 "the name #{name.inspect} keeps its folder"
    end
    # A single dot inside the name is a legal VM name and still attributes.
    folder = folder_rule(cr, attributed_vm(name: 'lab.vm', path: 'C:\VMs\lab.vm', clustered: false))
    assert_equal 'C:\VMs\lab.vm', folder
  end

  def test_a_folder_not_named_for_the_machine_or_not_under_a_root_is_never_touched
    cr, = build_cr(full_fog)
    assert_nil folder_rule(cr, attributed_vm(name: 'other', path: 'C:\VMs\lab-vm2', clustered: false))
    assert_nil folder_rule(cr, attributed_vm(name: 'lab-vm2', path: 'D:\elsewhere\lab-vm2', clustered: false))
    assert_nil folder_rule(cr, attributed_vm(name: 'lab-vm2', path: 'C:\VMs\sub\lab-vm2', clustered: false))
  end

  def test_roots_that_cannot_be_read_leave_the_folder_unattributed
    cr, = build_cr(full_fog)
    cr.stubs(:hypervisor).raises(RuntimeError.new('winrm died'))
    cr.stubs(:clusters).raises(RuntimeError.new('winrm died'))
    assert_nil folder_rule(cr, attributed_vm(clustered: false, path: 'C:\VMs\lab-vm2'))
  end

  # ---- the two-root folder rule: the wire pre-flight --------------------------

  def preflight_answer(cr, answer, vm = nil)
    vm ||= attributed_vm(path: 'C:\VMs\lab-vm2', clustered: false)
    vm.set_preflight(answer)
    cr.send(:destroy_folder?, vm)
  end

  def test_the_preflight_answers_the_delete_needs
    cr, = build_cr(full_fog)
    assert preflight_answer(cr, "NAMES:Virtual Machines;Snapshots;#{GUID}.vmcx;#{GUID}.vmrs;lab-vm2.vhdx;lab-vm2.avhdx"),
           'the layout the hypervisor actually writes: GUID-named config inside Virtual Machines'
    assert preflight_answer(cr, "NAMES:VIRTUAL MACHINES;#{GUID.upcase}.VMCX"), 'matching ignores case as the filesystem does'
    assert preflight_answer(cr, 'NAMES:lab-vm2.vmcx;Snapshot;lab-vm2.avhdx'), 'a name-named config still attributes'
  end

  def test_every_preflight_answer_that_is_not_a_clean_owning_answer_keeps_the_folder
    cr, = build_cr(full_fog)
    assert_not preflight_answer(cr, 'ABSENT')
    assert_not preflight_answer(cr, 'KEEP:JUNCTION')
    assert_not preflight_answer(cr, 'KEEP:HIDDEN')
    assert_not preflight_answer(cr, 'NAMES:vm99.vmcx;lab-vm2.vmcx'), 'a second machine’s config collides'
    assert_not preflight_answer(cr, "NAMES:Virtual Machines;#{GUID}.vmcx;deadbeef-1111-2222-3333-444444444444.vmcx"),
               'a second machine’s GUID config collides'
    assert_not preflight_answer(cr, "NAMES:Virtual Machines;deadbeef-1111-2222-3333-444444444444.vmcx"),
               'a folder whose only config belongs to another machine is not this machine’s'
    assert_not preflight_answer(cr, 'NAMES:'), 'no .vmcx means this is not provably the config folder'
    assert_not preflight_answer(cr, 'NAMES:lab-vm2.vhdx'), 'no .vmcx means this is not provably the config folder'
    assert_not preflight_answer(cr, 'C:\VMs\lab-vm2'), 'an answer outside the shape licenses nothing'
  end

  def test_a_preflight_that_does_not_answer_keeps_the_folder
    cr, = build_cr(full_fog)
    vm = attributed_vm(path: 'C:\VMs\lab-vm2', clustered: false)
    vm.service.stubs(:run_cmd).raises(Fog::Errors::Error.new('winrm died'))
    assert_not cr.send(:destroy_folder?, vm)
  end

  def test_the_preflight_rides_one_script_with_the_path_literal_quoted
    cr, = build_cr(full_fog)
    stub_roots(cr, vm_root: "C:\\VMs\\it's")
    vm = attributed_vm(path: "C:\\VMs\\it's\\lab-vm2", clustered: false)
    vm.set_preflight('ABSENT')
    cr.send(:destroy_folder?, vm)
    scripts = vm.calls.select { |c| c.is_a?(Array) && c.first == :run_cmd }.map(&:last)
    assert_equal 1, scripts.size, 'the pre-flight is exactly one round trip'
    assert_includes scripts.first, "'C:\\VMs\\it''s\\lab-vm2'", 'the path rides as a single-quoted literal'
    assert_includes scripts.first, '-LiteralPath'
    assert_includes scripts.first, 'ReparsePoint'
    assert_includes scripts.first, 'Hidden'
    assert_includes scripts.first, '-Recurse', 'the config lives one level down; the read must reach it'
  end

  # ---- the drive rule -----------------------------------------------------------

  def test_a_drive_file_is_deleted_only_when_attributed_and_proven_unshared
    cr, = build_cr(full_fog)
    vm = attributed_vm(path: 'C:\VMs\lab-vm2', clustered: false,
                       drives: [FakeHdd.new('d1', 'C:\VMs\lab-vm2\disk1.vhdx'),
                                FakeHdd.new('d2', 'C:\VMs\Disks\disk2.vhdx')])
    vm.hard_drives.each { |hdd| assert cr.send(:drive_deletion_allowed?, vm, hdd), hdd.path }
  end

  def test_a_shared_drive_never_has_its_file_deleted
    # fog's model refuses underlying: true unless the persistent-reservations
    # state reads false; true and unread both keep the file here too.
    cr, = build_cr(full_fog)
    vm = attributed_vm(path: 'C:\VMs\lab-vm2', clustered: false)
    assert_not cr.send(:drive_deletion_allowed?, vm, FakeHdd.new('d1', 'C:\VMs\lab-vm2\disk1.vhdx', reservations: true))
    assert_not cr.send(:drive_deletion_allowed?, vm, FakeHdd.new('d2', 'C:\VMs\lab-vm2\disk2.vhdx', reservations: nil))
  end

  def test_an_unattributed_drive_path_never_has_its_file_deleted
    cr, = build_cr(full_fog)
    vm = attributed_vm(path: 'C:\VMs\lab-vm2', clustered: false)
    assert_not cr.send(:drive_deletion_allowed?, vm, FakeHdd.new('d1', 'D:\pre-existing\disk.vhdx'))
    assert_not cr.send(:drive_deletion_allowed?, vm, FakeHdd.new('d2', 'C:\VMs\other-name\disk.vhdx'))
    assert_not cr.send(:drive_deletion_allowed?, vm, FakeHdd.new('d3', 'C:\VMs\lab-vm2\..\evil.vhdx'))
    assert_not cr.send(:drive_deletion_allowed?, vm, FakeHdd.new('d4', 'C:\PROGRA~1\lab-vm2\disk.vhdx'))
  end

  # ---- destroy: the enabled era --------------------------------------------------

  def enabled_destroy(cr, vm, state: :standalone)
    cr.stubs(:find_vm_by_uuid).returns(vm)
    cr.stubs(:standalone_destroy_state).returns(state)
    cr.destroy_vm(GUID)
  end

  def destroy_calls(vm)
    vm.calls.grep(Array).select { |c| c.first == :destroy }
  end

  def test_a_standalone_destroy_deletes_the_attributed_folder_and_files
    cr, = build_cr(full_fog)
    d1 = FakeHdd.new('d1', 'C:\VMs\lab-vm2\disk1.vhdx')
    vm = attributed_vm(path: 'C:\VMs\lab-vm2', clustered: false, drives: [d1])
    vm.set_preflight("NAMES:Virtual Machines;#{GUID}.vmcx")
    assert enabled_destroy(cr, vm)
    assert_equal [true], d1.calls, 'the attributed, unshared drive file goes'
    assert_equal [[:destroy, true]], destroy_calls(vm)
  end

  def test_a_kept_drive_file_inside_the_folder_keeps_the_folder
    # The folder delete recurses; a file this destroy refused must not be
    # taken by the recursion, so the folder stays with it.
    cr, = build_cr(full_fog)
    kept = FakeHdd.new('d1', 'C:\VMs\lab-vm2\shared.vhdx', reservations: true)
    vm = attributed_vm(path: 'C:\VMs\lab-vm2', clustered: false, drives: [kept])
    vm.set_preflight("NAMES:Virtual Machines;#{GUID}.vmcx")
    assert enabled_destroy(cr, vm)
    assert_equal [false], kept.calls
    assert_equal [[:destroy, false]], destroy_calls(vm)
  end

  def test_an_unattributed_drive_elsewhere_does_not_hold_the_folder
    cr, = build_cr(full_fog)
    elsewhere = FakeHdd.new('d1', 'D:\pre-existing\disk.vhdx')
    vm = attributed_vm(path: 'C:\VMs\lab-vm2', clustered: false, drives: [elsewhere])
    vm.set_preflight("NAMES:Virtual Machines;#{GUID}.vmcx")
    assert enabled_destroy(cr, vm)
    assert_equal [false], elsewhere.calls
    assert_equal [[:destroy, true]], destroy_calls(vm)
  end

  def test_an_indeterminate_classification_refuses_before_anything_is_mutated
    cr, = build_cr(full_fog)
    vm = attributed_vm(path: 'C:\VMs\lab-vm2', clustered: false)
    assert_raises(ForemanHyperv::OperationRefused) { enabled_destroy(cr, vm, state: :indeterminate) }
    assert_empty vm.calls, 'the unread endpoint stopped the destroy before stop, detach and delete'
  end

  def test_the_enablement_does_not_stretch_to_per_node_addressing_on_a_standalone_endpoint
    # :not_self stays refused with the pre-enablement sentence: enabling
    # clustered machines did not unlock PLG-5b's addressing question.
    cr, = build_cr(full_fog)
    vm = attributed_vm(path: 'C:\VMs\lab-vm2', clustered: false)
    error = assert_raises(ForemanHyperv::OperationRefused) { enabled_destroy(cr, vm, state: :not_self) }
    assert_includes error.message, ForemanHyperv::Hyperv::DESTROY_SELF_RUNG_REFUSAL
    assert_empty vm.calls
  end

  # ---- destroy: the clustered machine, F2's guard, fog's proof -------------------

  def test_a_clustered_destroy_releases_the_role_guarded_then_deletes
    cr, = build_cr(full_fog)
    d1 = FakeHdd.new('d1', 'C:\ClusterStorage\Volume1\lab-vm2\disk1.vhdx')
    vm = attributed_vm(drives: [d1], owner_node: 'hv-node2')
    vm.set_preflight("NAMES:Virtual Machines;#{GUID}.vmcx")
    assert enabled_destroy(cr, vm, state: :clustered)

    cmdlists = vm.calls.select { |c| c.is_a?(Array) && c.first == :run_cmdlist }
    assert_equal 1, cmdlists.size, 'the role removal is one two-element cmdlist'
    _, cmds, skip_json, target = cmdlists.first
    assert_equal 2, cmds.size, 'guard first, fog’s removal script second, together in one call'
    guard, = cmds[0]
    script, = cmds[1]
    assert_includes guard, '$env:COMPUTERNAME'
    assert_includes guard, "'hv-node2'"
    assert_includes guard, 'throw'
    assert_includes script, 'Remove-ClusterGroup'
    assert_includes script, 'ClusterObjectNotFound', 'fog’s read-back proof rides the composed element'
    assert_includes script, GUID
    assert_equal true, skip_json, 'the composed answer is fog’s own to parse'
    assert_equal 'hv-node2', target
    assert_equal [true], d1.calls
    assert_equal [[:destroy, true]], destroy_calls(vm)
    # The role release precedes every mutation of the machine itself.
    stop_index = vm.calls.index(:stop)
    role_index = vm.calls.index { |c| c.is_a?(Array) && c.first == :run_cmdlist }
    destroy_index = vm.calls.index { |c| c.is_a?(Array) && c.first == :destroy }
    assert stop_index < role_index && role_index < destroy_index
  end

  def test_a_role_that_does_not_answer_cleanly_stops_the_destroy_before_the_deletes
    cr, = build_cr(full_fog)
    d1 = FakeHdd.new('d1', 'C:\ClusterStorage\Volume1\lab-vm2\disk1.vhdx')
    vm = attributed_vm(drives: [d1], owner_node: 'hv-node2')
    vm.role_stdout = 'something unexpected'
    assert_raises(Foreman::Exception) { enabled_destroy(cr, vm, state: :clustered) }
    assert_equal [], d1.calls, 'nothing was detached under a role that did not answer'
    assert_empty destroy_calls(vm)
  end

  def test_a_role_removal_failure_stops_the_destroy_before_the_deletes
    cr, = build_cr(full_fog)
    d1 = FakeHdd.new('d1', 'C:\ClusterStorage\Volume1\lab-vm2\disk1.vhdx')
    vm = attributed_vm(drives: [d1], owner_node: 'hv-node2')
    vm.service.stubs(:run_cmdlist).raises(Fog::Hyperv::Errors::ServiceError, 'gone')
    assert_raises(Foreman::Exception) { enabled_destroy(cr, vm, state: :clustered) }
    assert_equal [], d1.calls
    assert_empty destroy_calls(vm)
  end

  def test_the_guard_carries_the_netbios_truncation_for_names_over_fifteen_characters
    # $env:COMPUTERNAME answers the NETBIOS name: uppercase, capped at 15.
    # A long node name must be matched by its truncation too, or the guard
    # false-refuses the machine it is guarding. (The pre-registered >15 red
    # case F2 owed before this PR.)
    long_name = 'hv-node-very-long-hostname'
    cr, = build_cr(full_fog)
    vm = attributed_vm(drives: [], owner_node: long_name)
    assert enabled_destroy(cr, vm, state: :clustered)
    cmdlists = vm.calls.select { |c| c.is_a?(Array) && c.first == :run_cmdlist }
    guard, = cmdlists.first[1][0]
    assert_includes guard, "'#{long_name}'"
    assert_includes guard, "'#{long_name[0, 15]}'", 'the NETBIOS truncation is an accepted answer'
  end

  def test_a_node_name_that_cannot_be_quoted_is_refused_as_itself_before_the_wire
    cr, = build_cr(full_fog)
    vm = attributed_vm(drives: [], owner_node: 'node`x')
    error = assert_raises(ForemanHyperv::OperationRefused) { enabled_destroy(cr, vm, state: :clustered) }
    assert_includes error.message, 'identity guard'
    assert_empty vm.calls.select { |c| c.is_a?(Array) && c.first == :run_cmdlist },
                 'the bad name never reached the wire'
  end

  # ---- destroy and create: the pre-enablement fog keeps the old refusals ---------

  def test_a_fog_missing_behaviours_gets_the_pre_enablement_destroy_sequence
    # The gate is PLG-15c's, verbatim: a proven stand-alone machine is still
    # detached-only and the folder is never deleted by it.
    cr, = build_cr(FogMissing.new(missing: :input_hardening))
    d1 = FakeHdd.new('d1', 'C:\VMs\lab-vm2\disk1.vhdx')
    vm = attributed_vm(path: 'C:\VMs\lab-vm2', clustered: false, drives: [d1])
    vm.set_preflight("NAMES:Virtual Machines;#{GUID}.vmcx")
    assert enabled_destroy(cr, vm, state: :standalone)
    assert_equal [[:destroy, false]], destroy_calls(vm)
    d1.calls.each { |c| assert_equal false, c }
    assert_empty vm.calls.select { |c| c.is_a?(Array) && c.first == :run_cmd },
                 'the pre-flight belongs to the enabled era only'
  end

  def test_a_fog_missing_behaviours_still_refuses_a_clustered_destroy
    cr, = build_cr(FogMissing.new(missing: :tri_state_cluster))
    vm = attributed_vm(path: 'C:\VMs\lab-vm2')
    error = assert_raises(ForemanHyperv::OperationRefused) { enabled_destroy(cr, vm, state: :clustered) }
    assert_includes error.message, ForemanHyperv::Hyperv::DESTROY_REFUSAL
    assert_empty vm.calls
  end

  def test_a_fog_missing_behaviours_refuses_a_cluster_create_before_reading_the_endpoint
    cr, fog = build_cr(FogMissing.new(missing: :stdout_json_hygiene))
    error = assert_raises(ForemanHyperv::OperationRefused) do
      cr.create_vm(name: 'vm1', cluster_name: 'lab-cluster')
    end
    assert_includes error.message, ForemanHyperv::Hyperv::CLUSTER_CREATE_REFUSAL
    assert_empty fog.calls
  end

  def test_a_fog_missing_behaviours_refuses_the_standalone_create_before_placement_reads
    # The pre-enablement era never consults placement membership: its gate
    # refused on the endpoint reads, and the order survives so its refusal
    # text survives.
    cr, fog = build_cr(FogMissing.new(missing: :exact_host_connection))
    cr.stubs(:create_allowed?).returns(false)
    cr.expects(:validate_placement!).never
    error = assert_raises(ForemanHyperv::OperationRefused) { cr.create_vm(name: 'vm1') }
    assert_includes error.message, ForemanHyperv::Hyperv::STANDALONE_CREATE_REFUSAL
    assert_empty fog.calls
  end

  # ---- the placement membership rule (reached by the enabled create) --------------

  def test_placement_membership_accepts_the_names_the_endpoint_reported_case_insensitively
    cr, = build_cr(full_fog)
    assert_nil cr.send(:validate_placement!, { computer_name: 'HV-NODE1' })
  end

  def test_a_placement_string_the_hypervisor_does_not_report_is_refused
    cr, = build_cr(full_fog)
    error = assert_raises(ForemanHyperv::OperationRefused) { cr.send(:validate_placement!, { computer_name: 'hv-node9' }) }
    assert_includes error.message, 'has not seen its own host or cluster report'
  end

  def test_a_membership_read_that_does_not_answer_refuses_the_create
    cr, = build_cr(full_fog)
    cr.stubs(:hypervisor).raises(RuntimeError.new('winrm died'))
    error = assert_raises(ForemanHyperv::OperationRefused) { cr.send(:validate_placement!, { computer_name: 'hv-node1' }) }
    assert_includes error.message, 'could not report its own nodes'
  end

  # ---- disk removal: the enabled era -----------------------------------------------

  def test_an_attributed_explicit_disk_removal_deletes_the_file_after_all_decisions
    cr, = build_cr(full_fog)
    d1 = FakeHdd.new('d1', 'C:\VMs\lab-vm2\disk1.vhdx')
    d2 = FakeHdd.new('d2', 'C:\VMs\Disks\disk2.vhdx')
    vm = attributed_vm(path: 'C:\VMs\lab-vm2', clustered: false, drives: [d1, d2])
    both = { '0' => { id: 'd1', _delete: '1' }, '1' => { id: 'd2', _delete: '1' } }
    cr.send(:update_volumes, vm, volumes_attributes: both)
    assert_equal [true], d1.calls
    assert_equal [true], d2.calls
  end

  def test_one_unattributable_removal_refuses_the_whole_edit_before_any_delete
    cr, = build_cr(full_fog)
    d1 = FakeHdd.new('d1', 'C:\VMs\lab-vm2\disk1.vhdx')
    d2 = FakeHdd.new('d2', 'D:\pre-existing\disk2.vhdx')
    vm = attributed_vm(path: 'C:\VMs\lab-vm2', clustered: false, drives: [d1, d2])
    error = assert_raises(ForemanHyperv::OperationRefused) do
      both = { '0' => { id: 'd1', _delete: '1' }, '1' => { id: 'd2', _delete: '1' } }
      cr.send(:update_volumes, vm, volumes_attributes: both)
    end
    assert_includes error.message, 'Nothing was detached and no file was deleted'
    assert_equal [], d1.calls, 'the whole edit refuses up front, not half of it completing'
    assert_equal [], d2.calls
  end

  def test_the_disk_removal_capability_gate_refuses_before_anything_is_fetched
    # Even with the enablement PR installed, a fog missing a behaviour keeps
    # the canonical refusal on the submitted hash: the hard-drive collection
    # is never asked for the disk it would have deleted.
    cr, = build_cr(FogMissing.new(missing: :literal_path_destructive))
    error = assert_raises(ForemanHyperv::OperationRefused) do
      cr.save_vm(GUID, volumes_attributes: { '0' => { id: GUID, _delete: '1' } })
    end
    assert_includes error.message, ForemanHyperv::Hyperv::DISK_REFUSAL
  end
end
