# frozen_string_literal: true

module ForemanHyperv
  # bootdisk PR-5: Decision 1's payload-staleness guard — one validation, on
  # in-memory state, mirroring core's own code path. It refuses exactly the
  # case where a step will write an address the ALREADY-GENERATED ISO cannot
  # carry, and nothing else.
  #
  # Core fills blank addresses in TWO places (round 10, F2):
  # before_validation :set_ip_address (host/managed.rb:338) and setComputeIPAM
  # inside queue_compute_create (orchestration/compute.rb:80-83, 210-217).
  # queue_compute_update has no IPAM step. The before_validation fill runs
  # BEFORE the bootdisk ISO generates (generate is priority 5, IPAM is 6), so
  # dhcp/db/random_db/external_ipam addresses are already home at generation
  # time and cannot go stale. What remains blank at validation is EUI-64 —
  # its fill waits for a MAC that only exists after create — so exactly a
  # CREATE with a blank behind a mac-based IPAM is refused.
  #
  # The plan wrote the gate as provision_method 'full_host'; the INSTALLED
  # foreman_bootdisk 24.1.0 registers exactly ONE provision method —
  # 'bootdisk' (engine.rb:49) — and its own full-host queue gate is
  # `provision_method == 'bootdisk' && ((old.nil? || !old.build?) && build?)`
  # (orchestration/compute.rb:29). The guard mirrors the queue's own gate, or
  # it would be dead code. Per Decision 6 item 6 a blank MAC itself NEVER
  # refuses: Hyper-V always answers compute_provides?(:mac) true, and that
  # ever-true fact is precisely the one the CALL-ORDER deferral exists to
  # work with — not this guard's trigger. The deferral is now MEASURED and
  # deliberately unshipped (sandbox pass 132): queuers run core-first /
  # plugin-second in valid? order with Task#<=> tying on created, so at
  # priorities 5/6 core runs first and the generate's upload pair interleaves
  # AFTER core's Query-details/Set-IP — the generate's xorriso seconds are
  # what delays Set-IP — and attach (900) lands last. Moving
  # queue_bootdisk_compute later is proven to be the lever; if bootdisk
  # activation ever shows IP-config lag, that is the measurement to act on.
  #
  # The known harmless gap (round 10 nit): a host that carries a uuid whose
  # VM was deleted out from under Foreman takes core's create branch while
  # this guard reads it as "not a create" — fine, because its addresses were
  # set on the original create.
  module BootdiskSeam
    extend ActiveSupport::Concern

    included do
      validate :validate_bootdisk_payload_would_go_stale
    end

    def bootdisk_payload_would_go_stale?
      return false unless provision_method == 'bootdisk'
      # The gem's own full-host queue transition (compute.rb:29): no queue,
      # no generation, nothing that can go stale. The config-disk bootdisk
      # host (build false) and the built host are out.
      return false unless (old.nil? || !old&.build?) && build?
      # The create branch only: a rebuild runs queue_compute_update, which
      # has no IPAM step, so the payload cannot diverge (F2).
      return false unless new_record? || uuid.blank?
      # Gate, not trigger (Decision 6 item 6 — Hyper-V always answers true).
      return false unless compute_provides?(:mac)

      # Core queues setComputeIPAM only for these two modes, and the
      # predicate takes the field as a REQUIRED argument (F1: a bare
      # mac_based_ipam? raises ArgumentError). The GATE rides the primary
      # nic while the loop below walks every managed nic — mirroring core's
      # own split (setComputeIPAM's gate is primary-only,
      # orchestration/compute.rb:80-83; the fill walks all managed nics,
      # managed.rb:600-606). A blank behind a secondary's EUI-64 with a
      # DHCP primary never fills, so it never goes stale (round 23, F7).
      # The primary is DETECTED here rather than called through the host
      # delegate because that delegate has no allow_nil (managed.rb:306
      # raises Module::DelegationError when no nic carries the flag) and
      # this runs INSIDE a validation cycle: the missing primary belongs to
      # check_interfaces' error, not to a 500 (round 23, F2).
      primary = interfaces.detect(&:primary)
      return false unless primary
      return false unless primary.mac_based_ipam?(:subnet) || primary.mac_based_ipam?(:subnet6)

      interfaces.select(&:managed).any? do |nic| # mirrors set_ip_address's own iteration
        (nic.subnet.present? && nic.ip.blank? && bootdisk_subnet_fills_address?(nic.subnet)) ||
          (nic.subnet6.present? && nic.ip6.blank? && bootdisk_subnet_fills_address?(nic.subnet6))
      end
    end

    def bootdisk_subnet_fills_address?(subnet)
      # IPAM::None#suggest_ip returns nil (verified on the CT); every other
      # registered mode can answer an address. A blank behind a mode that
      # suggests is either EUI-64 — the post-create fill this guard exists
      # for — or the suggestion itself failed, which core's own IP-presence
      # validation rejects anyway: that branch is defensive, not
      # load-bearing.
      subnet.ipam.present? && subnet.ipam != IPAM::MODES[:none]
    end

    def validate_bootdisk_payload_would_go_stale
      return unless bootdisk_payload_would_go_stale?

      errors.add(:base, _('The boot disk cannot be built for this host: a managed interface has no ' \
                          'address and the host uses MAC-based IPAM (EUI-64 answers the IPv6 address ' \
                          'only after Hyper-V assigns the MAC on first power-on). The boot disk image ' \
                          'is generated BEFORE that fill, so its payload would carry no address for ' \
                          'that interface. Set the address, or choose a subnet whose IPAM mode answers ' \
                          'addresses before the machine is created.'))
    end
  end
end
