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

# bootdisk PR-3: the ENDPOINT wiring. PR-2 shipped the transfer store dormant —
# two module accessors NOTHING set, so stage() answered ConfiguredRootError
# before a byte was written. This file owns the opening of the shelf:
#
#   * the two roots are registered settings (BLANK defaults keep the dormant
#     state the default); the store resolves roots per operation — override
#     accessor first (tests), else the setting — and NOTHING reads a Setting at
#     boot: a fresh install boots and migrates before plugin settings exist.
#   * iso_upload ensures the shelf exists (served 0711, staging 0700 — the
#     modes measured to serve-and-hide) before staging into it; an existing
#     root keeps whatever mode the operator set.
#   * the pull refuses, before staging, when the Apache drop-in the URL rides
#     is not installed — and equally when the installed drop-in Aliases a
#     DIFFERENT root than the configured pull root (a copy the operator never
#     finished editing serves 404s forever, and existence alone would wave it
#     through — round 21, finding 9). That check is LOAD-BEARING because of a
#     measurement:
#     `foreman-installer` PURGES the vhost drop-in dirs — a probe snippet
#     answering 200 over HTTP was gone after the next installer run (301/404),
#     along with an unrelated hand-written conf.d entry (evidence/
#     bd-pr3-apache-2026-11-24.log, 2026-11-24). The plugin therefore SHIPS the
#     snippet (config/apache/foreman-bootdisk-pull.conf) and iso_upload refuses
#     with the copy+reload remediation named when the installed file is gone;
#     when the unattended URL is https the TLS vhost needs its OWN copy (the
#     two vhosts Include only their own dir — measured), so that twin is
#     checked too. Plan v10 F4's rule, generalized to both schemes.
#
# The file pins the shipped snippet's content and name against the paths the
# check reads, so docs, check, and file cannot drift apart.
class HypervBootdiskEndpointTest < ActiveSupport::TestCase
  UUID = '1c51c4ee-df90-4cee-a9f7-218888711248'
  CR_URL = 'https://hyperv.example.com:5985'
  # The shipped snippet, resolved both ways it runs: from the repo tree in
  # development, and from the INSTALLED gem on the CI box (the suite stages
  # only test/, so a repo-relative path cannot exist there — and "the plugin
  # ships it" is a claim about the GEM, so the gem path is the honest one).
  REPO_SNIPPET = File.expand_path('../../config/apache/foreman-bootdisk-pull.conf', __dir__)
  SNIPPET_SOURCE =
    if File.file?(REPO_SNIPPET)
      REPO_SNIPPET
    else
      require 'rubygems'
      File.join(Gem::Specification.find_by_name('foreman_hyperv').gem_dir,
                'config', 'apache', 'foreman-bootdisk-pull.conf')
    end

  # Answers what Fog::Hyperv::Compute::Server really exposes (see the PR-2
  # suite for why each field looks like this); iso_upload reads only the
  # machine stub through the CR, never a drive.
  class MachineStub
    attr_reader :id, :state, :generation, :computer_name

    def initialize(id = HypervBootdiskEndpointTest::UUID, state: :Off, generation: :UEFI, computer_name: 'HV-NODE1')
      @id = id
      @state = state
      @generation = generation
      @computer_name = computer_name
    end
  end

  # A fog partner with everything iso_upload's own path calls: the enablement
  # six (the era the pull rides) and the pull itself. The store and the ride
  # checks are the subject here; the fog surface is the partner.
  class FogBootdisk
    attr_reader :calls

    def initialize
      @calls = []
    end

    def supports_clusters? = true
    def supports_exact_host_connections? = true
    def supports_literal_path_destructive? = true
    def supports_stdout_json_hygiene? = true
    def supports_input_hardening? = true
    def supports_cluster_capacity_projection? = true

    def fetch_url_to_path(url:, path:, sha256:, size:)
      @calls << [:fetch_url_to_path, url, path, sha256, size]
      size
    end
  end

  setup do
    @root = Dir.mktmpdir('bd3')
    @served = File.join(@root, 'served')
    @staging = File.join(@root, 'staging')
    ForemanHyperv::BootdiskTransfer.served_root = @served
    ForemanHyperv::BootdiskTransfer.staging_root = @staging
    # The snippets serve the configured root here unless a test says
    # otherwise; reading /etc paths is the one reach this store has outside
    # its roots, so it rides a named predicate the tests override instead of
    # a stubbed File.
    ForemanHyperv::BootdiskTransfer.stubs(:apache_snippet_serves?).returns(true)
  end

  teardown do
    ForemanHyperv::BootdiskTransfer.served_root = nil
    ForemanHyperv::BootdiskTransfer.staging_root = nil
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def build_cr(fog = FogBootdisk.new)
    cr = ForemanHyperv::Hyperv.new(name: 'lab-cr', url: CR_URL, user: 'u', password: 'p')
    cr.stubs(:client).returns(fog)
    cr.stubs(:storage_roots).returns(['C:\VMs'])
    cr.stubs(:find_vm_by_uuid).returns(MachineStub.new)
    cr.stubs(:endpoint_cluster).returns(nil)
    cr.stubs(:endpoint_serves_node?).returns(true)
    [cr, fog]
  end

  def make_iso(dir, name = 'host.example.com.iso', bytes: 'ISO-PAYLOAD')
    path = File.join(dir, name)
    File.binwrite(path, bytes)
    path
  end

  def stub_unattended(url = 'http://foreman.test')
    Setting.stubs(:[]).returns(url)
    Setting.stubs(:[]).with(:unattended_url).returns(url)
  end

  # Answer the drop-in check for one path (bound to the test's @served root,
  # which is what stage passes to the predicate). The precedence this relies
  # on is MEASURED, not assumed: probed on the CI box with the suite's own
  # mocha 2.8.2, a later `with`-constrained stub wins for ITS argument while
  # other arguments still fall through to the broad setup stub
  # (m(:x)=:constrained, m(:y)=:broad). The https-twin test needs both halves
  # of that behavior at once, so any mocha that changed it would fail the
  # battery, not hide it.
  def stub_snippet(path, present)
    ForemanHyperv::BootdiskTransfer.stubs(:apache_snippet_serves?).with(path, @served).returns(present)
  end

  # ---- the settings -------------------------------------------------------------

  test 'the two roots are registered settings and ship BLANK — the dormant state is the default' do
    assert_equal '', Foreman.settings[:hyperv_bootdisk_pull_root]
    assert_equal '', Foreman.settings[:hyperv_bootdisk_staging_root]
  end

  test 'the store reads the settings when nothing overrides them — no initializer, no boot-time Setting read' do
    FileUtils.mkdir_p([@served, @staging])
    ForemanHyperv::BootdiskTransfer.served_root = nil
    ForemanHyperv::BootdiskTransfer.staging_root = nil
    stub_unattended
    Setting.stubs(:[]).with(:hyperv_bootdisk_pull_root).returns(@served)
    Setting.stubs(:[]).with(:hyperv_bootdisk_staging_root).returns(@staging)
    src = make_iso(@root)

    staged = ForemanHyperv::BootdiskTransfer.stage(src, machine: UUID)

    assert File.file?(File.join(@served, "#{staged.nonce}.iso")), 'the setting-configured shelf is the shelf'
    assert_match %r{\Ahttp://foreman\.test/bootdisk-pull/[0-9a-f]{32}\.iso\z}, staged.url
  end

  test 'override unset AND setting blank still refuses before writing — PR-3 does not open the shelf' do
    ForemanHyperv::BootdiskTransfer.served_root = nil
    ForemanHyperv::BootdiskTransfer.staging_root = nil
    Setting.stubs(:[]).returns('')
    src = make_iso(@root)

    assert_raises(ForemanHyperv::BootdiskTransfer::ConfiguredRootError) do
      ForemanHyperv::BootdiskTransfer.stage(src, machine: UUID)
    end
    assert_equal ['host.example.com.iso'], Dir.children(@root),
                 'the dormant refusal wrote nothing anywhere — the shelf is not even created'
  end

  # ---- ensuring the shelf ---------------------------------------------------------

  test 'ensure_roots! creates what is missing at the measured modes and never re-modes what it did not create' do
    FileUtils.mkdir_p(@served)
    File.chmod(0o750, @served)

    ForemanHyperv::BootdiskTransfer.ensure_roots!

    assert_equal 0o750, File.stat(@served).mode & 0o777,
                 'an operator-mode root stays operator-mode: the ensure creates, it does not police'
    assert File.directory?(@staging)
    assert_equal 0o700, File.stat(@staging).mode & 0o777,
                 'the staging root lands 0700 — unserved and unlistable, whatever the worker umask was'
  end

  test 'ensure_roots! creates the SERVED root at 0711 — the mode measured to serve while hiding the listing' do
    ForemanHyperv::BootdiskTransfer.ensure_roots!

    assert_equal 0o711, File.stat(@served).mode & 0o777
  end

  test 'ensure_roots! lets a real filesystem failure travel — a shelf that cannot exist is broken, not dormant' do
    # Under root the permission bits are a lie, so the un-creatable root is a
    # path THROUGH a regular file: ENOTDIR answers root and mortal alike.
    blocker = File.join(@root, 'blocker')
    File.write(blocker, 'not a directory')
    ForemanHyperv::BootdiskTransfer.served_root = File.join(blocker, 'served')

    assert_raises(SystemCallError) { ForemanHyperv::BootdiskTransfer.ensure_roots! }
  end

  test 'iso_upload creates the shelf it stages onto — a configured-but-fresh install TRANSFERS (PR-3 red-first)' do
    cr, fog = build_cr
    stub_unattended
    src = make_iso(@root)

    answer = cr.iso_upload(src, UUID, storage_id: 'C:\VMs')

    assert_equal File.size(src), answer,
                 'pre-PR-3 this raises Errno::ENOENT: stage() copied into a staging root the installer ' \
                 'window never created — the ensure is what a fresh install needs to ride at all'
    assert_equal 0o711, File.stat(@served).mode & 0o777
    assert_equal 0o700, File.stat(@staging).mode & 0o777
    assert_empty Dir.children(@served), 'the ensure creates the shelf; the ensure-deletion still empties it'
    assert_empty Dir.children(@staging)
    assert_equal 1, (fog.calls.count { |c| c.first == :fetch_url_to_path })
  end

  # ---- the snippet the URL rides (F4, post-purge) ---------------------------------

  test 'the pull refuses BEFORE staging when the Apache drop-in the URL rides is not installed' do
    FileUtils.mkdir_p([@served, @staging])
    src = make_iso(@root)
    stub_snippet(ForemanHyperv::BootdiskTransfer::HTTP_SNIPPET_PATH, false)

    error = assert_raises(ForemanHyperv::OperationRefused) do
      ForemanHyperv::BootdiskTransfer.stage(src, machine: UUID)
    end

    assert_includes error.message, ForemanHyperv::BootdiskTransfer::HTTP_SNIPPET_PATH,
                    'the refusal names the exact file the operator must put back'
    assert_includes error.message, 'foreman-bootdisk-pull.conf'
    assert_empty Dir.children(@served), 'the check rides the URL-first line: a refused pull stages nothing'
    assert_empty Dir.children(@staging)
  end

  test 'an https unattended URL refuses when only the HTTP vhost got the snippet (F4 twin, measured vhosts)' do
    FileUtils.mkdir_p([@served, @staging])
    stub_unattended('https://foreman.test')
    src = make_iso(@root)
    stub_snippet(ForemanHyperv::BootdiskTransfer::HTTPS_SNIPPET_PATH, false)

    error = assert_raises(ForemanHyperv::OperationRefused) do
      ForemanHyperv::BootdiskTransfer.stage(src, machine: UUID)
    end

    assert_includes error.message, ForemanHyperv::BootdiskTransfer::HTTPS_SNIPPET_PATH
    assert_not_includes error.message, ForemanHyperv::BootdiskTransfer::HTTP_SNIPPET_PATH,
                        'the HTTP copy IS installed — naming it would send the operator to the wrong vhost'
  end

  test 'https passes the snippet check when BOTH vhost copies are installed' do
    FileUtils.mkdir_p([@served, @staging])
    stub_unattended('https://foreman.test')
    src = make_iso(@root)

    staged = ForemanHyperv::BootdiskTransfer.stage(src, machine: UUID)

    assert_match %r{\Ahttps://foreman\.test/bootdisk-pull/[0-9a-f]{32}\.iso\z}, staged.url
  end

  # ---- what the drop-in must actually carry (round 21, finding 9) ------------------

  test 'the drop-in check reads the Alias target, not just the filename — a copy pointing elsewhere is refused' do
    ForemanHyperv::BootdiskTransfer.unstub(:apache_snippet_serves?)
    root = '/var/lib/foreman/bootdisk-transfer'

    good = File.join(@root, 'good.conf')
    File.write(good, "  # an indented ops copy\n  Alias /bootdisk-pull #{root}\n")
    assert ForemanHyperv::BootdiskTransfer.apache_snippet_serves?(good, root),
           'leading whitespace is still the same Apache directive'

    trailing = File.join(@root, 'trailing.conf')
    File.write(trailing, "Alias /bootdisk-pull/ #{root}/\n")
    assert ForemanHyperv::BootdiskTransfer.apache_snippet_serves?(trailing, root),
           'one optional trailing slash either side is the same path (the store chomps the configured one)'

    wrong = File.join(@root, 'wrong.conf')
    File.write(wrong, "Alias /bootdisk-pull /srv/somewhere-else\n")
    refute ForemanHyperv::BootdiskTransfer.apache_snippet_serves?(wrong, root),
           'the copy-without-editing bug this check exists for: file installed, Alias elsewhere, every ride a 404'

    legacy = File.join(@root, 'legacy.conf')
    File.write(legacy, "Alias /bootdisk-pull #{root}-legacy\n")
    refute ForemanHyperv::BootdiskTransfer.apache_snippet_serves?(legacy, root),
           'a PREFIX of the root is not the root — substring matching would wave it through'

    refute ForemanHyperv::BootdiskTransfer.apache_snippet_serves?(File.join(@root, 'gone.conf'), root),
           'no file, no service'
  end

  test 'a drop-in that EXISTS but Aliases another root refuses with the root named' do
    FileUtils.mkdir_p([@served, @staging])
    stub_unattended
    src = make_iso(@root)
    stub_snippet(ForemanHyperv::BootdiskTransfer::HTTP_SNIPPET_PATH, false)
    File.stubs(:file?).returns(true) # the drop-in IS installed — this is not the purge case

    error = assert_raises(ForemanHyperv::OperationRefused) do
      ForemanHyperv::BootdiskTransfer.stage(src, machine: UUID)
    end

    assert_includes error.message, @served, 'the refusal names the root the Alias must be edited to'
    assert_includes error.message, 'Alias'
    assert_empty Dir.children(@served), 'a mis-aliased drop-in stages nothing, exactly like a missing one'
  end

  test 'an http unattended URL does NOT require the ssl-side twin — the scheme rule is a rule, not a mood' do
    FileUtils.mkdir_p([@served, @staging])
    src = make_iso(@root)
    stub_snippet(ForemanHyperv::BootdiskTransfer::HTTPS_SNIPPET_PATH, false)

    staged = ForemanHyperv::BootdiskTransfer.stage(src, machine: UUID)

    assert_match %r{\Ahttp://foreman\.test/bootdisk-pull/[0-9a-f]{32}\.iso\z}, staged.url,
                 'round-21 finding 19: hardening the check to always demand BOTH copies must trip HERE, ' \
                 'not pass silently — the ssl twin is required by the URL scheme and nothing else'
  end

  test 'configured roots are normalized — pasted spaces and trailing slashes cannot create phantom directories' do
    ForemanHyperv::BootdiskTransfer.served_root = " #{@served}/ "
    assert_equal @served, ForemanHyperv::BootdiskTransfer.send(:served_root!),
                 'a pasted " /path " must not stage into a directory whose name starts with a space'
    ForemanHyperv::BootdiskTransfer.served_root = '/'
    assert_equal '/', ForemanHyperv::BootdiskTransfer.send(:served_root!),
                 "chomping a root of '/' down to '' would hand mkdir_p an empty path (ENOENT)"
  end

  test 'ensure_roots! modes every component it CREATES — umask must not hide the served root' do
    deep = File.join(@root, 'srv', 'bootdisk', 'served')
    ForemanHyperv::BootdiskTransfer.served_root = deep
    umask = File.umask(0o077) # the dynflow worker shape: fresh ancestors would land 0700 unchallenged
    begin
      ForemanHyperv::BootdiskTransfer.ensure_roots!
    ensure
      File.umask(umask)
    end

    ancestor = File.join(@root, 'srv')
    assert File.directory?(ancestor)
    assert_equal 0o711, File.stat(ancestor).mode & 0o777,
                 'under a 0077 umask a fresh /…/srv sits at 0700 and httpd can never traverse to the ' \
                 'served root — the snippet check stays green while every ride 403s (round 21, finding 11)'
    assert_equal 0o711, File.stat(deep).mode & 0o777
    assert_equal 0o700, File.stat(@staging).mode & 0o777, 'the fresh staging root lands its own 0700'
    assert_equal 0o700, File.stat(@root).mode & 0o777,
                 'the PRE-EXISTING parent (mktmpdir) is not re-moded — the ensure creates, it does not police'
  end

  # ---- the shipped snippet ----------------------------------------------------------

  test 'the plugin SHIPS the snippet, one name shared by the file, the docs and both checks' do
    assert File.file?(SNIPPET_SOURCE)
    shipped = File.read(SNIPPET_SOURCE)

    assert_includes shipped, 'Alias /bootdisk-pull /var/lib/foreman/bootdisk-transfer'
    assert_includes shipped, 'ProxyPass /bootdisk-pull !',
                    'the WHOLE subtree is Apache\'s (the plan\'s measured choice) — not a per-extension match'
    assert_not_includes shipped, 'ProxyPassMatch'
    assert_includes shipped, 'Options -Indexes -FollowSymLinks'
    assert_includes shipped, 'AllowOverride None'
    assert_includes shipped, 'Require all granted'
    # The Directory block must target the SAME root the store serves (plan
    # Decision 2 verbatim): an unasserted target could drift from the Alias
    # with every option silently applied to the wrong tree.
    assert_includes shipped, '<Directory /var/lib/foreman/bootdisk-transfer>'
    assert_includes shipped, '</Directory>'
    assert_equal File.basename(ForemanHyperv::BootdiskTransfer::HTTP_SNIPPET_PATH), File.basename(SNIPPET_SOURCE),
                 'shipped name, http-side check name and https-twin check name must never drift apart'
    assert_equal File.basename(ForemanHyperv::BootdiskTransfer::HTTPS_SNIPPET_PATH), File.basename(SNIPPET_SOURCE)
  end
end
