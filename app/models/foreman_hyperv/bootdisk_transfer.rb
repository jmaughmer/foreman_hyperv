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
  # This class touches NOTHING outside the two roots: no fog, no DB. It is
  # used inside the orchestration (iso_upload) and the plugin's own paths.
  module BootdiskTransfer
    # What stage() answers: everything fog's fetch_url_to_path needs to pull
    # and verify (url + sha256 + exact byte count), plus the nonce the caller
    # hands to discard(). The host-side NAME is not here on purpose — it is
    # the ISO basename the attach and delete steps receive from core, never
    # the nonce, which is only the URL secret.
    Staged = Struct.new(:nonce, :url, :sha256, :bytes, keyword_init: true)

    class ConfiguredRootError < StandardError; end

    # Set by the plugin initializer from settings (bootdisk_pull_root /
    # bootdisk_pull_url — spike 0.2 measured these as REQUIRED configuration,
    # not derived), never by user input per operation. Nil until configured;
    # tests set them directly.
    class << self
      attr_accessor :served_root, :staging_root

      # Copy the source into the served root under a fresh nonce. COPIES,
      # never renames: the source lives in the worker's PrivateTmp, which is
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
        bytes = File.size(src)
        sha256 = Digest::SHA256.file(src).hexdigest
        nonce = SecureRandom.hex(16)
        url = "#{transfer_url!}/#{nonce}.iso"
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

      private

      def served_root!
        root = served_root.to_s
        raise ConfiguredRootError, 'bootdisk_pull_root is not configured' if root.blank?

        root.chomp('/')
      end

      def staging_root!
        root = staging_root.to_s
        raise ConfiguredRootError, 'bootdisk_staging_root is not configured' if root.blank?

        root.chomp('/')
      end

      # The pull URL for the transfer: the setting plus the nonce path. Like
      # the smart-proxy URLs, unattended_url is trusted deployment config —
      # the ONLY untrusted bytes interpolated here are the generated nonce.
      # Chomp only the trailing slash (never rstrip — 'foreman.test//' is
      # spike 0.2's double-slash trap).
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
