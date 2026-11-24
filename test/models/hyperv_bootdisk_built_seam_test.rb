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

# bootdisk PR-3: the /unattended/built SEAM, proven rather than wired. The RPM
# of foreman_bootdisk 24.1.0 (evidence/bootdisk-orchestration-compute.rb) shows
# the built POST's transition — `old&.build? && !build?` — queueing exactly two
# tasks, `setDetachIsoImage` at priority 52 and `setDeleteIsoImage` at 53, and
# those actions call compute_resource.iso_detach(uuid) then
# compute_resource.iso_delete(bootdisk_isofile, uuid). Nothing here re-queues
# anything: the tests pin the CHAIN (which module fires, in which order, with
# which contract arguments into OUR compute resource) so a bootdisk upgrade or
# a rename on our side trips here instead of stranding a host in build mode
# with a live token. These are PINS — they hold on the tree that already
# shipped, deliberately: red-first belongs to the new endpoint wiring (see
# hyperv_bootdisk_endpoint_test.rb), and the live end-to-end ride is spike 0.5.
class HypervBootdiskBuiltSeamTest < ActiveSupport::TestCase
  UUID = '1c51c4ee-df90-4cee-a9f7-218888711248'
  ISOFILE = '/tmp/dynflow-private/bd3.example.com.iso'

  def bootdisk_host(build_was: true, build_now: false)
    host = Host::Managed.new(name: 'bd3.example.com', provision_method: 'bootdisk')
    host.uuid = UUID
    host.stubs(:compute?).returns(true)
    # A SEPARATE instance, not host.dup: a dup taken after host is mocha'd
    # shares the mock state, and stubbing build? on the copy would then
    # re-stub it on the original. queue_bootdisk_compute reads only
    # old.build?, which this answers exactly.
    old = Host::Managed.new(name: 'bd3.example.com', provision_method: 'bootdisk')
    old.stubs(:build?).returns(build_was)
    host.stubs(:old).returns(build_now ? nil : old)
    host.build = build_now
    host
  end

  def recording_queue(sink)
    queue = Object.new
    queue.define_singleton_method(:create) { |**attrs| sink << attrs }
    queue
  end

  test 'the installed foreman_bootdisk is the seam itself: Host::Managed carries the RPM concern' do
    assert_includes Host::Managed.ancestors.map(&:to_s), 'ForemanBootdisk::Orchestration::Compute',
                    'without this module the built POST queues NOTHING for the ISO and the ride strands ' \
                    'the host in build mode — this is the drift guard for a bootdisk change'
    # Registration pin, not just the method: the RPM hooks the queue up as an
    # after_validation callback (compute.rb:10-12). Pinning only the method
    # body would stay green through a bootdisk release that dropped or moved
    # the hook — the chain would silently stop queueing.
    assert_includes Host::Managed._validate_callbacks.map { |c| c.filter.to_s },
                    'queue_bootdisk_compute',
                    'foreman_bootdisk no longer registers queue_bootdisk_compute as a validation ' \
                    'callback on Host::Managed — the /unattended/built chain is gone'
  end

  test 'the built transition queues detach(52) then delete(53) — the after_build pair, in that order' do
    host = bootdisk_host
    queued = []
    host.stubs(:queue).returns(recording_queue(queued))

    assert host.queue_bootdisk_compute, 'queue_bootdisk_compute answers true or the save itself fails'

    assert_equal [52, 53], queued.pluck(:priority),
                 'delete must run AFTER detach: eject nulls the drive Path (measured), and the delete ' \
                 'contract reads nothing off the drive but must still run after the eject it depends on'
    assert_equal [host, :setDetachIsoImage], queued[0][:action]
    assert_equal [host, :setDeleteIsoImage], queued[1][:action]
  end

  test 'the build START transition queues the ISO pair plus attach — and never the after_build pair' do
    host = bootdisk_host(build_was: false, build_now: true)
    queued = []
    host.stubs(:queue).returns(recording_queue(queued))

    assert host.queue_bootdisk_compute

    assert_equal [5, 6, 900], queued.pluck(:priority),
                 'generate(5), upload(6), attach(900): the before_build trio (the RPM verbatim)'
    assert queued.none? { |entry| entry[:action][1].in?(%i[setDetachIsoImage setDeleteIsoImage]) },
           'detach/delete belong to the built transition ONLY — firing them here ejects a disc the ' \
           'installer has not even booted from'
  end

  test 'a machine that is not bootdisk answers the seam with nothing queued at all' do
    host = bootdisk_host
    host.provision_method = 'build'
    queued = []
    host.stubs(:queue).returns(recording_queue(queued))

    # The RPM's own answer for this branch is nil (the early `return unless
    # provision_method == 'bootdisk'`), and the callback is after_validation —
    # a nil there is inert, only the QUEUE matters.
    assert_nil host.queue_bootdisk_compute

    assert_empty queued, 'the RPM gates every queue on provision_method == "bootdisk" — ordinary builds ' \
                         'must not grow ISO tasks (this is why iso_detach is NOT on every build path)'
  end

  test 'the two actions reach the compute resource with the contract arguments, detach first, answers true' do
    host = bootdisk_host
    calls = []
    compute = Object.new
    compute.define_singleton_method(:iso_detach) do |vm_id|
      calls << [:iso_detach, vm_id]
      true
    end
    compute.define_singleton_method(:iso_delete) do |isofile, vm_id|
      calls << [:iso_delete, isofile, vm_id]
      true
    end
    host.stubs(:compute_resource).returns(compute)
    host.stubs(:bootdisk_isofile).returns(ISOFILE)

    detach_answer = host.setDetachIsoImage
    delete_answer = host.setDeleteIsoImage

    assert_equal [[:iso_detach, UUID], [:iso_delete, ISOFILE, UUID]], calls,
                 'detach gets ONLY the uuid (it finds the drive by what reports media); delete gets the ' \
                 'full isofile path and takes the basename from it — the exact RPM bodies, pinned here'
    assert detach_answer, 'a falsy answer fails the whole /unattended/built save (core-orchestration.rb:149) ' \
                          '— a truthy detach is what keeps a completed install from looking failed'
    assert delete_answer
  end
end
