# frozen_string_literal: true

require 'test_helper'
require 'active_support/test_case'
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

# bootdisk PR-4: the janitor. Plan v10 Decision 4 decided it before the store
# existed: an AGE-ONLY sweep of the two Foreman-local directories, names
# restricted to the two contracts the store itself writes, the age decision
# from file mtime and NEVER from the sidecar (F10: an unparseable sidecar must
# not keep an ISO forever), symlinks never followed or removed, no ownership
# questions asked. The store names the janitor in four of its own comments —
# this file makes the promise real.
#
# Cadence is not invented either: measured on the CI box 2026-11-25, foreman
# 5.0.1 ships /etc/cron.d/foreman running foreman-rake cron:hourly at :30 each
# hour, and Foreman::Cron.register(cadence, task) is the documented plugin
# hook (the comment above core's own registrations in cron.rake). The plugin's
# rake file registers foreman_hyperv:bootdisk_janitor :hourly, and the last
# test loads that very file and asserts the registration — same file, same
# call, run in-process, so registration drift trips here.
class HypervBootdiskJanitorTest < ActiveSupport::TestCase
  # Two fixed nonces: real 32-hex, never a placeholder.
  OLD_ISO = 'a1b2c3d4e5f60718293a4b5c6d7e8f90'
  YOUNG_ISO = '0f1e2d3c4b5a69788796a5b4c3d2e1f0'
  DAY = 24 * 3600

  # The plugin's rake file, resolved both ways the suite runs: repo tree in
  # development, INSTALLED gem on the CI box (which stages only test/, so the
  # repo-relative path cannot exist there — same resolution the endpoint suite
  # uses for the shipped snippet).
  REPO_RAKE = File.expand_path('../../lib/tasks/foreman_hyperv_tasks.rake', __dir__)
  RAKE_FILE =
    if File.file?(REPO_RAKE)
      REPO_RAKE
    else
      require 'rubygems'
      File.join(Gem::Specification.find_by_name('foreman_hyperv').gem_dir,
                'lib', 'tasks', 'foreman_hyperv_tasks.rake')
    end

  setup do
    @root = Dir.mktmpdir('bd4')
    @served = File.join(@root, 'served')
    @staging = File.join(@root, 'staging')
    FileUtils.mkdir_p([@served, @staging])
    ForemanHyperv::BootdiskTransfer.served_root = @served
    ForemanHyperv::BootdiskTransfer.staging_root = @staging
    @now = Time.now
  end

  teardown do
    ForemanHyperv::BootdiskTransfer.served_root = nil
    ForemanHyperv::BootdiskTransfer.staging_root = nil
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  # Write a file and age it (mtime is the ONLY age source the janitor reads,
  # so the tests speak mtime too — utime, never sleep).
  def aged(dir, name, seconds_old, content: 'x')
    path = File.join(dir, name)
    File.binwrite(path, content)
    t = @now - seconds_old
    File.utime(t, t, path)
    path
  end

  def alive?(path) = File.exist?(path)

  test 'an age-exceeded nonce ISO goes out of the served root' do
    old = aged(@served, "#{OLD_ISO}.iso", DAY + 3600)
    counts = ForemanHyperv::BootdiskTransfer.sweep(now: @now)
    assert_not alive?(old), 'a crashed ride must not park 245 MB forever'
    assert_equal({ served: 1, staging: 0 }, counts)
  end

  test 'a young nonce ISO stays — the in-flight ride is protected by age alone' do
    young = aged(@served, "#{YOUNG_ISO}.iso", 60)
    counts = ForemanHyperv::BootdiskTransfer.sweep(now: @now)
    assert alive?(young), 'a file staged seconds ago may be mid-PULL right now'
    assert_equal({ served: 0, staging: 0 }, counts)
  end

  test 'age-exceeded sidecars AND interrupted staging temps go out of the staging root' do
    sidecar = aged(@staging, "staging-#{OLD_ISO}.json", DAY + 60, content: "{\"nonce\":\"#{OLD_ISO}\"}")
    part = aged(@staging, "staging-#{OLD_ISO}.iso.part", DAY + 60)
    counts = ForemanHyperv::BootdiskTransfer.sweep(now: @now)
    assert_not alive?(sidecar)
    assert_not alive?(part)
    assert_equal({ served: 0, staging: 2 }, counts)
  end

  test 'young staging files stay for the same reason young ISOs stay' do
    sidecar = aged(@staging, "staging-#{YOUNG_ISO}.json", 60)
    part = aged(@staging, "staging-#{YOUNG_ISO}.iso.part", 60)
    ForemanHyperv::BootdiskTransfer.sweep(now: @now)
    assert alive?(sidecar)
    assert alive?(part)
  end

  test 'the janitor touches nothing it did not write — foreign names survive at any age' do
    foreign_served = [
      'README.txt',                      # an operator note
      'zz.iso',                          # not a nonce
      "#{OLD_ISO[0..30]}.iso",           # 31 hex: one character short
      "#{OLD_ISO}0.iso",                 # 33 hex: one character over
      "#{OLD_ISO}.iso.tmp",              # a different editor's temp
      "STAGING-#{OLD_ISO}.json",         # right shape, wrong case
      "#{OLD_ISO.upcase}.iso"            # uppercase hex: the nonce is lowercase [0-9a-f]
    ].map { |n| aged(@served, n, DAY * 7) }
    Dir.mkdir(File.join(@served, "#{YOUNG_ISO}.iso")) # a DIRECTORY wearing the name
    foreign_staging = [
      'notes.txt',
      'staging-.json',
      "staging-#{OLD_ISO}.tmp", # not json, not iso.part
      'staging-readme.txt'
    ].map { |n| aged(@staging, n, DAY * 7) }

    counts = ForemanHyperv::BootdiskTransfer.sweep(now: @now)
    (foreign_served + foreign_staging).each { |p| assert alive?(p), "#{p} is not the janitor's to delete" }
    assert alive?(File.join(@served, "#{YOUNG_ISO}.iso")), 'a directory named like a nonce is not an ISO'
    assert_equal({ served: 0, staging: 0 }, counts)
  end

  test 'a symlink is never followed or removed, even wearing a nonce name (Decision 4)' do
    target = File.join(@root, 'someone-elses-file')
    File.binwrite(target, 'NOT OURS')
    t = @now - (DAY * 30)
    File.utime(t, t, target)
    link = File.join(@served, "#{OLD_ISO}.iso")
    File.symlink(target, link)
    File.utime(t, t, link) # lstat-time ages with the rest, where the fs allows it

    counts = ForemanHyperv::BootdiskTransfer.sweep(now: @now)
    assert File.symlink?(link), 'the janitor never removes a symlink'
    assert alive?(target), 'and never removes what it points at'
    assert_equal({ served: 0, staging: 0 }, counts)
  end

  test 'F10: age is mtime and NEVER the sidecar — a fresh-looking or unparseable sidecar cannot save an ISO' do
    iso = aged(@served, "#{OLD_ISO}.iso", DAY + 60)
    # A sidecar whose staged_at says seconds ago (clock wrong, hand-edited, or
    # rewritten by anything) and a sidecar that is not even JSON: neither may
    # keep the ISO, because the janitor reads neither.
    fresh = aged(@staging, "staging-#{OLD_ISO}.json", DAY + 60,
                 content: "{\"staged_at\":\"#{@now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')}\"}")
    junk = aged(@staging, "staging-#{YOUNG_ISO}.json", DAY + 60, content: '{not json')
    counts = ForemanHyperv::BootdiskTransfer.sweep(now: @now)
    assert_not alive?(iso), 'the sidecar never vouches for the ISO'
    assert_not alive?(fresh)
    assert_not alive?(junk)
    assert_equal({ served: 1, staging: 2 }, counts)
  end

  test 'dormant sweep answers nil and touches nothing (the ConfiguredRootError doctrine)' do
    ForemanHyperv::BootdiskTransfer.served_root = nil
    ForemanHyperv::BootdiskTransfer.staging_root = nil
    Setting.stubs(:[]).returns('')
    assert_nil ForemanHyperv::BootdiskTransfer.sweep(now: @now)
  end

  test 'configured roots that do not exist answer zero counts, not an error' do
    FileUtils.remove_entry(@served)
    FileUtils.remove_entry(@staging)
    assert_equal({ served: 0, staging: 0 }, ForemanHyperv::BootdiskTransfer.sweep(now: @now))
  end

  test 'strict older-than: exactly at the cutoff stays, one second older goes' do
    at = aged(@served, "#{OLD_ISO}.iso", DAY)
    over = aged(@served, "#{YOUNG_ISO}.iso", DAY + 1)
    counts = ForemanHyperv::BootdiskTransfer.sweep(now: @now)
    assert alive?(at), 'the boundary belongs to the young side'
    assert_not alive?(over)
    assert_equal({ served: 1, staging: 0 }, counts)
  end

  test 'a per-file unlink race is swallowed and the sweep proceeds' do
    racing = aged(@served, "#{OLD_ISO}.iso", DAY + 60)
    survivor = aged(@served, "#{YOUNG_ISO}.iso", DAY + 60)
    File.stubs(:unlink).raises(Errno::ENOENT.new)
    # The stub answers for EVERY unlink; nothing is removed, and the sweep
    # must still walk every candidate and return honest zero counts.
    counts = ForemanHyperv::BootdiskTransfer.sweep(now: @now)
    File.unstub(:unlink) # before teardown: mocha restores only after it, and
    # a stubbed File.unlink turns remove_entry's cleanup into ENOTEMPTY
    assert_equal({ served: 0, staging: 0 }, counts, 'failed unlinks are not removals')
    assert alive?(racing) && alive?(survivor)
  end

  test 'the max_age argument overrides the constant (testability without sleeping)' do
    young = aged(@served, "#{OLD_ISO}.iso", 120)
    counts = ForemanHyperv::BootdiskTransfer.sweep(now: @now, max_age: 60)
    assert_not alive?(young), 'an explicitly shorter patience sweeps files the default keeps'
    assert_equal({ served: 1, staging: 0 }, counts)
  end

  test 'the plugin rake file defines foreman_hyperv:bootdisk_janitor and registers it HOURLY' do
    require 'rake'
    require 'foreman/cron'
    # The plugin file is written for foreman-rake: it declares an
    # :environment prerequisite and ends with Rake::Task[:test].enhance. The
    # test process supplies both tasks so the LOAD (the thing under test) can
    # run at all.
    Rake::Task.define_task(:environment)
    Rake::Task.define_task(:test)
    load RAKE_FILE

    assert Rake::Task.task_defined?('foreman_hyperv:bootdisk_janitor'),
           'the janitor needs its rake entry point (the RPM cron file runs rake, not Ruby)'
    hourly = Foreman::Cron.send(:tasks_for, :hourly)
    assert_includes hourly, 'foreman_hyperv:bootdisk_janitor',
                    'Decision 4 runs the janitor "on the same cadence as the existing scheduled work" — ' \
                    'measured 2026-11-25, that cadence is /etc/cron.d/foreman cron:hourly'
  end

  test 'the shipped age constant is a day (documented patience, not a magic local)' do
    assert_equal 24 * 3600, ForemanHyperv::BootdiskTransfer::JANITOR_MAX_AGE
  end
end
