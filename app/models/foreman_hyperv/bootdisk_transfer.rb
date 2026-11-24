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
  #   * the STAGING root (0700, never served) — temps and sidecars. A file
  #     becomes visible to the host only through the final rename into the
  #     served root, so a half-written ISO is physically unservable, and the
  #     janitor (PR-4) reads sidecars this Apache cannot hand out.
  #
  # F8 rides stage(): the source lands through COPY-then-RENAME, never one
  # rename — the generating worker's tmpdir lives under its PrivateTmp bind
  # mount, so a move into the served root crosses filesystems (EXDEV) and a
  # rename would raise in the middle of a build. F10 rides the same line:
  # the sidecar records what the janitor needs beside the temp, and because
  # the janitor's age decision reads mtime, an unparseable sidecar can delay
  # a sweep but cannot keep an ISO on the shelf forever.
  #
  # discard() is the ensure every caller reaches — success, fog raise, host
  # refusal — and it is strict about the one string that becomes a filesystem
  # argument: only a full nonce is ever joined to a root.
  class BootdiskTransfer
    NONCE = /\A[0-9a-f]{32}\z/

    # What stage answers: everything iso_upload needs to hand the host, in
    # one object, so a caller cannot half-use the contract (the URL without
    # the digest that verifies it, say).
    Staged = Struct.new(:nonce, :path, :url, :sha256, :size, keyword_init: true)

    class << self
      # The roots, overridable where a test (or an operator with a layout of
      # their own) must point them; nil restores the installed defaults.
      attr_writer :served_root, :staging_root

      def served_root
        @served_root || '/var/lib/foreman/bootdisk-transfer'
      end

      def staging_root
        @staging_root || '/var/lib/foreman/bootdisk-staging'
      end

      # Copy source onto the shelf and answer its nonce, URL and verifiers.
      # The source STAYS: the worker still owns the file it generated.
      def stage(source)
        unless source.present? && File.file?(source)
          raise ArgumentError, "the ISO to stage does not exist: #{source.inspect}"
        end

        nonce = SecureRandom.hex(16)
        ensure_root(served_root, 0o711) # --x for the puller: it names files, it does not list the shelf
        ensure_root(staging_root, 0o700)
        sha256 = Digest::SHA256.file(source).hexdigest
        size = File.size(source)

        temp = File.join(staging_root, "#{nonce}.part")
        final = File.join(served_root, "#{nonce}.iso")
        begin
          FileUtils.cp(source, temp)
          File.write(File.join(staging_root, "#{nonce}.json"),
                     JSON.generate('sha256' => sha256, 'size' => size, 'source' => File.basename(source)))
          FileUtils.mv(temp, final) # same filesystem by construction: the visibility flip
        rescue StandardError
          FileUtils.rm_f(temp)
          FileUtils.rm_f(final)
          raise
        end

        Staged.new(nonce: nonce, path: final, url: url_for(nonce), sha256: sha256, size: size)
      end

      # Take one ISO off the shelf. Anything not a full nonce addresses
      # nothing here — a caller that lost its nonce waits for the janitor
      # rather than handing a search string to rm.
      def discard(nonce)
        return false unless NONCE.match?(nonce.to_s)

        FileUtils.rm_f(File.join(served_root, "#{nonce}.iso"))
        FileUtils.rm_f(File.join(staging_root, "#{nonce}.json"))
        true
      end

      # The URL the host fetches: the same unattended URL a provisioned
      # machine already trusts for its templates (the pull rides the same
      # http(s) decision the rest of the unattended exchange makes), plus
      # the snippet's one alias path and the nonce.
      def url_for(nonce)
        base = Setting[:unattended_url].to_s.strip.sub(%r{/+\z}, '')
        if base.empty?
          raise ForemanHyperv::OperationRefused,
                'The bootdisk pull needs a non-blank unattended URL the host can reach.'
        end

        "#{base}/bootdisk-pull/#{nonce}.iso"
      end

      private

      # Created lazily (a Foreman install has no reason to hold this until a
      # bootdisk builds); an existing root keeps the mode it has — an
      # operator's chmod is an answer, and rewriting it from a worker would
      # be a surprise, not a fix.
      def ensure_root(path, mode)
        return if File.directory?(path)

        FileUtils.mkdir_p(path)
        File.chmod(mode, path)
      rescue StandardError => e
        raise ForemanHyperv::OperationRefused,
              "The bootdisk transfer shelf #{path.inspect} could not be prepared: #{e.class}."
      end
    end
  end
end
