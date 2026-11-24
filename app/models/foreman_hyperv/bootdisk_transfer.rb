# frozen_string_literal: true

require 'securerandom'
require 'digest'
require 'fileutils'
require 'json'

module ForemanHyperv
  # The bootdisk transfer store: the plugin's staging handoff between the
  # worker that GENERATES an ISO and the Hyper-V host that PULLS it (Decision
  # 2 — spike 0.1 measured the WinRM push at 0.54-0.75 MB/s against the host's
  # own HTTP pull at 148.9 MB/s, so the file moves by pull and this class is
  # the shelf the pull reads from).
  #
  # Two roots, and the split is the security boundary:
  #   * the SERVED root — Apache exposes exactly one Alias at /bootdisk-pull
  #     onto this directory (PR-3's snippet); it holds ONLY final, complete
  #     files named <32-hex-nonce>.iso. The nonce is the whole URL secret:
  #     the alias is anonymous-read by design, so an ISO carrying host keys
  #     must not be nameable by anything shorter or guessable.
  #   * the STAGING root (0700, never served) — temps and sidecars, both
  #     named for PR-4's janitor contract (plan v10 Decision 4/F10): temps are
  #     staging-<nonce>.iso.part, sidecars staging-<nonce>.json. Nothing else
  #     lives here, because a differently-named temp or a served sidecar is a
  #     file the janitor cannot find or must not touch.
  #
  # stage() ORDER IS THE CONTRACT (round 17, findings 5-6): the URL is
  # computed FIRST (a blank unattended_url refuses before a byte is written,
  # so no orphan can sit in the served root waiting for an Apache that will
  # never serve it), the copy is chmod 0644 and fsynced BEFORE the rename
  # (the PrivateTmp worker's umask is not Apache's problem, and a rename that
  # beats the data hits disk as a zero-length ISO), and a failed rename takes
  # the sidecar with it — a sidecar whose ISO never landed is one the janitor
  # would chase forever.
  #
  # This class stays out of fog, and touches the DB only through the Setting
  # store at OPERATION time (the roots, the unattended URL — never at load).
  # Its only reach outside the two roots is reading the Apache drop-ins the
  # pull URL rides (existence and Alias target — the installer-purge
  # measurement, above). It is used inside
  # the orchestration (iso_upload) and the plugin's own paths.
  module BootdiskTransfer
    # What stage() answers: everything fog's fetch_url_to_path needs to pull
    # and verify (url + sha256 + exact byte count), plus the nonce the caller
    # hands to discard(). The host-side NAME is not here on purpose — it is
    # the ISO basename the attach and delete steps receive from core, never
    # the nonce, which is only the URL secret.
    Staged = Struct.new(:nonce, :url, :sha256, :bytes, keyword_init: true)

    class ConfiguredRootError < StandardError; end

    # The refusal when the pull URL would be a lie: the setting says a root,
    # the shelf may even exist, but Apache does not serve it — every built
    # host would then hang waiting for media the host fetches as a 404. The
    # message carries only this file's own paths (no remote text) and the
    # remediation the measurement says is load-bearing: the installer PURGES
    # the drop-in dirs, so the copy is a state that must be re-applied.
    BOOTDISK_SNIPPET_REFUSAL = 'The boot disk file cannot be staged for the host to pull: the Apache ' \
                               'configuration serving /bootdisk-pull is not installed (%<paths>s). The gem ' \
                               'ships the snippet as config/apache/foreman-bootdisk-pull.conf — copy it to ' \
                               'the path named and reload httpd (systemctl reload httpd). foreman-installer ' \
                               'removes this drop-in (measured), so re-apply it after every installer run. ' \
                               'Nothing was staged.'

    # The drop-in exists but its Alias points somewhere else — the exact
    # failure a copy-paste of the snippet into BOTH vhost dirs introduces when
    # the operator set hyperv_bootdisk_pull_root to a non-default path: the check
    # passes on file-existence, the host fetches, Apache serves the wrong
    # (or an empty) directory, and every ride is a silent 404. Naming the
    # root makes the fix a one-line edit.
    BOOTDISK_SNIPPET_ALIAS_REFUSAL = 'The boot disk file cannot be staged for the host to pull: the Apache ' \
                                     'drop-in for /bootdisk-pull is installed (%<paths>s) but does not Alias ' \
                                     'that path at the configured pull root (%<root>s). Edit the snippet\'s ' \
                                     'Alias and <Directory> target to %<root>s and reload httpd (systemctl ' \
                                     'reload httpd). Nothing was staged.'

    # The Apache drop-ins the pull URL rides. Measured (2026-11-24,
    # evidence/bd-pr3-apache-2026-11-24.log): foreman-installer PURGES the
    # vhost drop-in dirs, so the installed snippet is a state that can
    # vanish silently — hence the pre-staging check below, and the shipped
    # source file config/apache/foreman-bootdisk-pull.conf whose basename
    # these paths pin (the endpoint test asserts the shared name). Module
    # scope, NOT class << self: constants inside a singleton-class block live
    # on the singleton, and BootdiskTransfer::HTTP_SNIPPET_PATH would not
    # resolve from the outside (measured as a NameError, 2026-11-24).
    HTTP_SNIPPET_PATH = '/etc/httpd/conf.d/05-foreman.d/foreman-bootdisk-pull.conf'
    HTTPS_SNIPPET_PATH = '/etc/httpd/conf.d/05-foreman-ssl.d/foreman-bootdisk-pull.conf'

    # Where the pull's files live. Production NEVER sets the accessors: the
    # readers resolve override-first (tests set them directly), else the
    # settings, PER OPERATION — nothing reads a Setting at boot, because a
    # fresh install boots and migrates before plugin settings exist, and a
    # Setting read is an in-memory cache hit anyway. Blank answers stay the
    # documented dormant state: stage() refuses before writing a byte.
    class << self
      attr_accessor :served_root, :staging_root

      # Create the two roots if missing, at the modes measured to work: the
      # served root 0711 (Apache traverses in, local users cannot list — the
      # nonce is the whole URL secret) and the staging root 0700 (unserved,
      # ungroupable). An EXISTING root keeps whatever mode the operator set —
      # the ensure creates, it does not police — and a root that cannot be
      # created raises through: that is a broken deployment, not a dormant
      # one. mkdir applies the umask (a worker at 0077 would hide the served
      # root from Apache), so the mode is set explicitly after creation.
      # iso_upload calls this on its pre-flight line; the store's own write
      # contract stays pure: it writes INSIDE roots that exist.
      def ensure_roots!
        ensure_root!(served_root!, 0o711)
        ensure_root!(staging_root!, 0o700)
      end

      # Copy the source into the served root under a fresh nonce. PRECONDITION:
      # both roots EXIST — iso_upload calls ensure_roots! before staging, and
      # the write path stays deliberately pure here (a stage that silently
      # created a missing root would hide a broken deployment inside an
      # otherwise-successful ride). Calling stage against roots that do not
      # exist raises through (Errno::ENOENT), which is the honest answer.
      # COPIES, never renames: the source lives in the worker's PrivateTmp, which is
      # a different filesystem (measured EXDEV), and the worker's ensure
      # removes it anyway. Returns the Staged handoff. Raises on any real
      # failure — the caller (iso_upload) deletes the staged copy in its
      # ensure either way.
      def stage(src, machine: nil)
        served = served_root!
        staging = staging_root!
        base = File.basename(src.to_s)
        raise ArgumentError, "#{src} is not a regular file" if base.blank? || !File.file?(src)

        # URL first: every failure below would otherwise orphan a file in the
        # root Apache serves, and a blank unattended_url is the one failure
        # that is ALWAYS waiting (setting unset).
        base_url = transfer_url!
        # The URL is only a promise Apache can keep if the drop-in is
        # installed — and it can vanish silently with the next installer run.
        # Checked before the hash pass, not merely before the copy: the purge
        # refusal is the most likely operator-facing failure of this whole
        # feature, and answering it only after a full SHA256 read of a 245 MB
        # ISO repeats the mistake round 17 called out for the gates ("every
        # one of them, before a single read").
        require_served_snippet!(base_url, served)
        bytes = File.size(src)
        sha256 = Digest::SHA256.file(src).hexdigest
        nonce = SecureRandom.hex(16)
        url = "#{base_url}/#{nonce}.iso"
        tmp = File.join(staging, "staging-#{nonce}.iso.part")
        sidecar = File.join(staging, "staging-#{nonce}.json")
        final = File.join(served, "#{nonce}.iso")

        staged_written = false
        begin
          FileUtils.cp(src, tmp)
          # The worker generated this under its own umask (0600 under
          # PrivateTmp is the common case); Apache runs as another user and
          # must be able to read it.
          File.chmod(0o644, tmp)
          # Durability BEFORE visibility: the rename publishes the file to
          # the host's GET, and a rename that beats the bytes serves a short
          # file the host's verifier will (correctly) refuse.
          File.open(tmp, 'rb', &:fsync)
          write_sidecar(sidecar, nonce: nonce, machine: machine, source: base, bytes: bytes, sha256: sha256)
          staged_written = true
          FileUtils.mv(tmp, final)
        rescue StandardError
          FileUtils.rm_f(tmp)
          FileUtils.rm_f(sidecar) if staged_written || File.file?(sidecar)
          # A cross-filesystem mv is copy-then-unlink: a mid-copy failure can
          # leave a PARTIAL file under the final name (round 19, finding N1).
          # The served root must hold only complete files - fog verifies the
          # copy host-side anyway, but the janitor should never have to.
          FileUtils.rm_f(final)
          raise
        end

        Staged.new(nonce: nonce, url: url, sha256: sha256, bytes: bytes)
      end

      # Delete the staged file for a nonce and its sidecar. Best-effort by
      # design: the caller runs it in an ensure and a failed cleanup must not
      # mask the real result; PR-4's janitor sweeps age-exceeded files anyway.
      # Anything that is not a nonce is refused without touching the disk.
      def discard(nonce)
        n = nonce.to_s
        return unless n.match?(/\A[0-9a-f]{32}\z/)

        served = served_root!
        staging = staging_root!
        begin
          FileUtils.rm_f(File.join(served, "#{n}.iso"))
          FileUtils.rm_f(File.join(staging, "staging-#{n}.json"))
        rescue StandardError
          nil
        end
      end

      # Does the Apache drop-in at this path exist AND alias /bootdisk-pull at
      # this root? Existence alone is half the answer: the installer purge
      # teaches operators to COPY the snippet, and a copy whose Alias still
      # points at the shipped default while the setting names another root
      # serves a 404 on every ride — the exact failure class this check
      # exists to catch. Deliberately a plain file read, not a live HTTP
      # probe: the probe would add failure modes (the endpoint must resolve
      # its own unattended_url from inside the worker) for an answer the
      # file already gives, and the end-to-end proof of the served endpoint
      # is the real ride, not this check. Named and public because it is the
      # seam tests answer through.
      def apache_snippet_serves?(path, root)
        return false unless File.file?(path.to_s)

        # Line-shaped match: leading whitespace (a hand-indented copy), one
        # optional trailing slash on either side (both are real Apache), and
        # anchored after the root so 'bootdisk-transfer-legacy' does not
        # count as 'bootdisk-transfer'.
        pattern = %r{^\s*Alias\s+/bootdisk-pull/?\s+#{Regexp.escape(root)}/?\s*$}
        File.read(path.to_s).match?(pattern)
      rescue SystemCallError
        false
      end

      private

      # Which drop-ins the URL about to be handed to the host requires, and
      # whether each one actually serves the configured root: the HTTP vhost
      # always; the TLS vhost additionally when the unattended URL is https —
      # the two vhosts Include only their own drop-in dir (measured), so an
      # https URL served without the ssl-side copy answers 404 on the very
      # request the host makes. A drop-in that exists but Aliases a different
      # root is as broken as one that is gone, so the check reads the target
      # too (apache_snippet_serves?) and names the right remediation for each.
      def require_served_snippet!(url, served)
        wanted = [HTTP_SNIPPET_PATH]
        wanted << HTTPS_SNIPPET_PATH if url.start_with?('https://')
        unmet = wanted.reject { |path| apache_snippet_serves?(path, served) }
        return if unmet.empty?

        absent = unmet.reject { |path| File.file?(path) }
        if absent.any?
          raise ForemanHyperv::OperationRefused, format(BOOTDISK_SNIPPET_REFUSAL, paths: absent.join(' and '))
        end

        raise ForemanHyperv::OperationRefused, format(BOOTDISK_SNIPPET_ALIAS_REFUSAL,
                                                      paths: unmet.join(' and '), root: served)
      end

      def ensure_root!(root, mode)
        return if File.directory?(root)

        # Collect the components we are ABOUT to create by walking up to the
        # first existing ancestor (FileUtils.mkdir_p silently ignores a block,
        # measured — the array cannot come from it). Creation errors (ENOTDIR,
        # EACCES) travel THROUGH: the ensure creates, honest failure is a real
        # failure. No chown: the creation runs as the foreman worker, so
        # everything made here is already foreman:foreman.
        missing = []
        node = root
        while !File.directory?(node)
          missing << node
          parent = File.dirname(node)
          break if parent == node # reached the filesystem root

          node = parent
        end
        FileUtils.mkdir_p(root)
        # chmod EVERY component we created: with a 0077 dynflow umask a root
        # configured deeper than its parent (say /srv/bootdisk/pull) would
        # otherwise leave /srv/bootdisk at 0700 and the served root permanently
        # unreachable (403) while the snippet check stays green. Existing
        # components keep operator modes — create, not police. A chmod racing a
        # concurrent ensure (or an operator fix landing mid-call) is not worth
        # failing an otherwise-successful creation over, so ONLY these metadata
        # calls tolerate SystemCallError; the mkdir above deliberately does not.
        missing.each { |dir| chmod_tolerant(dir, mode) }
      end

      # chmod that survives the race with a concurrent ensure or an operator
      # fix landing mid-call — only ever called on a directory we just
      # created, so a vanished/changed one is not our failure to report.
      def chmod_tolerant(dir, mode)
        File.chmod(mode, dir)
      rescue SystemCallError
        nil
      end

      def served_root!
        root = (served_root.presence || Setting[:hyperv_bootdisk_pull_root].to_s).strip
        raise ConfiguredRootError, 'hyperv_bootdisk_pull_root is not configured' if root.blank?

        # chomp ONE trailing slash (the common misconfiguration) without
        # annihilating a root configured as '/' itself.
        root.length > 1 ? root.chomp('/') : root
      end

      def staging_root!
        root = (staging_root.presence || Setting[:hyperv_bootdisk_staging_root].to_s).strip
        raise ConfiguredRootError, 'hyperv_bootdisk_staging_root is not configured' if root.blank?

        root.length > 1 ? root.chomp('/') : root
      end

      # The pull URL for the transfer: the setting plus the nonce path. Like
      # the smart-proxy URLs, unattended_url is trusted deployment config —
      # the ONLY untrusted bytes interpolated here are the generated nonce.
      # Chomp removes ONE trailing slash, the common misconfiguration; a
      # configured double slash ('foreman.test//', spike 0.2's trap) is left
      # as configured — this fixes the join, it does not rewrite settings.
      def transfer_url!
        base = Setting[:unattended_url].to_s.strip
        if base.empty?
          raise ForemanHyperv::OperationRefused,
                'The bootdisk transfer is refused: the unattended URL setting is blank, so the host ' \
                'could not be told where to fetch from. Nothing was staged.'
        end

        "#{base.chomp('/')}/bootdisk-pull"
      end

      # Sidecar fields per plan v10 Decision 4 (F10): host-side identity the
      # janitor and a human debugging a stale ride need. The janitor's AGE
      # decision reads the file mtime, never staged_at (Decision 4), but the
      # field is recorded, and the name matches the janitor's staging-* sweep
      # pattern.
      def write_sidecar(path, nonce:, machine:, source:, bytes:, sha256:)
        meta = {
          nonce: nonce,
          machine: machine,
          source: source,
          bytes: bytes,
          sha256: sha256,
          staged_at: Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
        }
        File.write(path, JSON.generate(meta))
      end
    end
  end
end
