# frozen_string_literal: true

# Only the constants file: the GUID pattern this validator anchors to is the
# same constant fog's Servers#get tests, and constants.rb carries nothing else.
require 'fog/hyperv/constants'

module ForemanHyperv
  # One deep input validator for every user-controlled string this resource puts
  # in front of fog-hyperv, invoked at the entry of every method that takes one:
  # new_vm, create_vm, save_vm, new_interface, new_volume, new_cdrom,
  # find_vm_by_uuid and vm_from_cluster_owner.
  #
  # fog-hyperv assembles every request as a PowerShell script line by Ruby
  # interpolation (lib/fog/hyperv/utils/powershell.rb); the by-identity lookups
  # interpolate the id straight into a filter (the _by_id paths); and the
  # name-completion step of connection() interpolates an unresolved host into a
  # Resolve-DnsName call run on the host (lib/fog/hyperv/utils/winrm.rb). Until
  # fog itself stops interpolating, one quote character inside a machine name,
  # an adapter name, a disk path, a placement target or an id is remote
  # PowerShell running as the compute resource's service account — reachable
  # from create and edit (provisioning rights) and from the URL VM id of the
  # show page (view permission). The plugin therefore refuses the string here,
  # before fog is asked anything at all.
  #
  # Refusal, never sanitisation: a rejected value is never rewritten and never
  # forwarded. Every allowlist below rejects the quoting and statement
  # characters (' " $ ` ; newline), the provider wildcards ([ ] * ?) and
  # everything else its field has no business containing, and the exception
  # message names the field but never echoes the value — the string is
  # attacker-chosen and belongs nowhere near a log line or a flash message.
  #
  # The three placement strings — computer_name, cluster_name, datastore — are
  # additionally checked for membership in what the hypervisor itself reported;
  # that is the compute resource's job (it owns the reads) and lives in
  # Hyperv#validate_placement!. The character check here runs before that read,
  # so a hostile string is refused before it can reach any fog call — and no
  # fog call ever carries a user string, because the membership reads are
  # unfiltered (Get-Cluster, Get-ClusterNode, Get-VMHost) and the comparison
  # happens in Ruby.
  module InputValidation
    # Anchored on fog's own constant, with \A..\z and not ^..$: a value accepted
    # here is exactly a value Fog::Hyperv::Compute::Servers#get takes down its
    # id: branch (compute/models/servers.rb), and a trailing newline plus a
    # payload does not slip the anchor the way a $ anchor would.
    GUID_PATTERN = /\A#{Fog::Hyperv::GUID}\z/i

    # Keys whose value addresses a MACHINE or a SWITCH on the wire and is
    # accepted only GUID-shaped, wherever it appears: every fog by-id lookup
    # is GUID-only — fog takes its by-id branch on exactly this shape, so
    # "the plugin accepts this id" and "fog looks it up by id" cannot drift,
    # and an id forged as script text dies here.
    GUID_KEYS = %i[vm_id switch_id].freeze

    # Keys whose value identifies a DEVICE INSIDE an already-GUID-addressed
    # machine, which the edit form round-trips from what the endpoint and the
    # DB reported (PLG-37, measured 2026-11-24: identity and volume ids arrive
    # as WMI device paths like Microsoft:1C51C4EE-...\\D07B9966-...\\0\\0\\D,
    # and the NIC row carries its DB row id). These values select nothing on
    # the wire — an unmatched one matches no device — but they still ride to
    # interpolation sinks, so the endpoint's own shapes are what is accepted:
    # a GUID, a numeric row id, or a Microsoft:-prefixed WMI path whose
    # segments are GUIDs, controller numbers, or drive letters. Names, script
    # text, and path traversal stay refused.
    DEVICE_ID_KEYS = %i[id identity].freeze
    WMI_DEVICE_PATH = /\AMicrosoft:#{Fog::Hyperv::GUID}(?:\\(?:#{Fog::Hyperv::GUID}|\d+|[A-Z]))*\z/i
    DB_ROW_ID = /\A\d+\z/

    # Keys a machine hash must never carry at all. path is fog's own create
    # target and only this resource sets it (from a cluster shared volume);
    # service would replace the fog connection itself. computer_name is not on
    # this list at the machine level because the placement form legitimately
    # submits one — it is membership-checked instead. Inside NIC, disk and DVD
    # hashes computer_name is absent from their key allowlists entirely: the
    # node a device lives on is this resource's placement decision, never a
    # device field.
    FORBIDDEN_VM_KEYS = %i[path service].freeze

    # The writable attribute set of Fog::Hyperv::Compute::NetworkAdapter, the
    # plugin's VLAN accessors over it, and the form's structural keys. The
    # create/update interface loops dispatch these hashes with
    # nic.send(:"#{k}=", v) — send reaches every setter that exists on the
    # model, so the key must be on a fixed list, not merely non-empty.
    # The off-model keys on this list are legitimate form traffic that names
    # nothing Hyper-V is asked to do, and each rides to this validator and no
    # further, its characters still checked: ip/ip6 are core's pass-through
    # (PLG-24: host_interfaces_attrs merges them onto every physical NIC, and
    # the first clustered machine died on the IPv4 its operator typed), and
    # PLG-37 adds the interface-row columns — a host-form EDIT submits each
    # NIC's full row (identifier/domain_id/subnet_id/managed/primary/
    # provision/execution/tag/attached_to, measured refusing as 'identifier'
    # and 'execution' in production.log 881036ec) because
    # hyperv_add_attributes copies the form's interfaces_attributes wholesale
    # into the compute hash; update_interfaces picks its own keys, so these
    # reach no fog setter.
    NIC_KEYS = %i[
      _destroy _delete id identity mac mac_address name switch_name switch_id
      ip ip6
      identifier domain_id subnet_id managed primary provision execution
      tag attached_to
      is_legacy is_management_os connected dynamic_mac_address_enabled
      mac_address_spoofing dhcp_guard router_guard allow_teaming
      compute_attributes
      vlan_operation_mode vlan_private_mode access_vlan_id native_vlan_id
      primary_vlan_id secondary_vlan_id secondary_vlan_ids allowed_vlan_ids
    ].freeze

    # The writable attribute set of Fog::Hyperv::Compute::HardDrive, the
    # plugin's basename/size accessors over it, the form's structural key, and
    # datastore — the shared volume this resource is asked to place the disk on,
    # membership-checked before anything reads it.
    HDD_KEYS = %i[
      _delete id identity name basename size size_bytes path datastore
      controller_number controller_type maximum_iops minimum_iops
    ].freeze

    DVD_KEYS = %i[id identity name path controller_number controller_position].freeze

    CONTEXT_KEYS = { nic: NIC_KEYS, hdd: HDD_KEYS, dvd: DVD_KEYS }.freeze

    # A machine hash nests a NIC's items under interfaces_attributes and a
    # disk's under volumes_attributes; a NIC item round-trips its VLAN block
    # under compute_attributes, which is the same model's keys again.
    VM_CHILD_CONTEXTS = { interfaces_attributes: :nic, volumes_attributes: :hdd }.freeze
    INDEXED_KEY = /\A\d+\z/

    # ---- per-field character allowlists --------------------------------------
    # None of these admits a quote, a dollar, a backtick, a semicolon, a newline
    # or a wildcard. Field vocabularies were read off the forms and the lab:
    # names are host-ish, switches read "Default Switch" / "WSL (Hyper-V
    # firewall)", shared volumes are drive paths, VLAN fields are numbers,
    # ranges and comma lists.
    SAFE_NAME = /\A[\p{L}\p{N} .\-_()]+\z/
    SAFE_HOST = /\A[\p{L}\p{N}.-]+\z/
    SAFE_PATH = /\A[\p{L}\p{N} .\-_\\:]+\z/
    SAFE_MAC = /\A[0-9A-Fa-f:-]+\z/
    SAFE_NUMBERED = /\A[0-9,\- ]+\z/
    SAFE_TEXT = %r{\A[\p{L}\p{N} .,:_()/#&@!=+-]+\z}

    TEXT_BY_KEY = {
      name: SAFE_NAME,
      basename: SAFE_NAME,
      switch_name: SAFE_NAME,
      computer_name: SAFE_HOST,
      cluster_name: SAFE_HOST,
      datastore: SAFE_PATH,
      path: SAFE_PATH,
      # bootdisk PR-5: the storage_id foreman_bootdisk hands to iso_upload
      # and iso_attach. The values are Windows volume paths
      # (C:\ClusterStorage\Volume1, \\cluster\share) — the DEFAULT_TEXT
      # pattern has no backslash and would refuse every honest value, so the
      # key pairs with the exact pattern datastore/path already use (plan
      # round 7, major C). No new pattern is introduced.
      iso_upload_storage: SAFE_PATH,
      mac: SAFE_MAC,
      mac_address: SAFE_MAC,
      notes: SAFE_TEXT,
      allowed_vlan_ids: SAFE_NUMBERED,
      secondary_vlan_ids: SAFE_NUMBERED,
      access_vlan_id: SAFE_NUMBERED,
      native_vlan_id: SAFE_NUMBERED,
      primary_vlan_id: SAFE_NUMBERED,
      secondary_vlan_id: SAFE_NUMBERED,
      vlan_operation_mode: SAFE_NAME,
      vlan_private_mode: SAFE_NAME,
      controller_type: SAFE_NAME,
      boot_device: SAFE_NAME,
      foreman_firmware: SAFE_NAME,
      firmware: SAFE_NAME,
      firmware_type: SAFE_NAME
    }.freeze

    # An unknown key still gets a value check: the fog model guards its own key
    # list, but a string that cannot be named for a known field has no business
    # being anywhere near fog.
    DEFAULT_TEXT = SAFE_TEXT

    # Keys of a nested hash this validator has no model for — arbitrary keys
    # would be their own injection surface.
    GENERIC_KEY = /\A[a-z_][a-z0-9_]*\z/i

    class << self
      # fog's own anchored id test, shared with validate_id! so "the plugin
      # accepts this id" and "fog takes the id: branch for it" cannot drift.
      def guid?(value)
        !!(value.to_s =~ GUID_PATTERN)
      end

      # The URL VM id, the nested device ids, every lookup key: a machine is
      # addressed by the GUID Hyper-V gave it and by nothing else. Names went
      # into fog's name path — the builder sink — until this line refused them;
      # the lookup that answers "which node owns it" takes the same id.
      def validate_id!(value)
        return if value.present? && guid?(value)

        raise ForemanHyperv::UnsafeIdentifier,
              'A virtual machine must be addressed by the GUID Hyper-V gave it; nothing was asked ' \
              'of the host with this identifier'
      end

      # One value against its field's allowlist, for callers that validate a
      # single string before using it as a membership key (the fog_extensions
      # cluster_name= setter).
      def refuse_text!(key, value)
        check_text!(key, value)
      end

      # The deep walk. The hash is normalised into symbols on a copy: nothing
      # here rewrites or forwards anything, it only decides. Attributes arrive
      # either as one hash or as the keywords of the call itself — Ruby 3 does
      # not fold lone keywords into a positional hash, so both forms are taken,
      # never a mix.
      def validate_hash!(attrs = nil, context: :vm, **keyword_attrs)
        raise unsafe(:attributes) if attrs && keyword_attrs.any?

        attrs = keyword_attrs if attrs.nil?
        attrs = attrs.to_hash if attrs.respond_to?(:to_hash)
        raise unsafe(:attributes) unless attrs.is_a?(Hash)

        walk(deep_symbolize(attrs), context: context)
      end

      private

      def walk(hash, context:)
        hash.each do |key, value|
          next if value.nil?

          raise unsafe(key) if context == :generic && !key.to_s.match?(GENERIC_KEY)

          check_key!(key, value, context: context)
          # Identity keys own their shape above (GUID, row id, WMI device
          # path); the generic character allowlist would refuse the path's
          # backslashes, and a second opinion there buys nothing.
          next if GUID_KEYS.include?(key) || DEVICE_ID_KEYS.include?(key)

          check_value!(key, value, context: context)
        end
      end

      def check_key!(key, value, context:)
        if GUID_KEYS.include?(key)
          validate_id!(value) if value.present?
          return
        end

        # Device identities round-tripped from the endpoint's or the DB's own
        # answers: GUID-shaped, numeric row id, or Microsoft: WMI path — and
        # nothing else. The refusal class is the same as for a bad machine id:
        # the value could not have come from the shapes Hyper-V reports.
        if DEVICE_ID_KEYS.include?(key) && value.present?
          text = value.to_s
          return if text.match?(GUID_PATTERN) || text.match?(WMI_DEVICE_PATH) || text.match?(DB_ROW_ID)

          raise ForemanHyperv::UnsafeIdentifier,
                'A device identifier must be the GUID, the Microsoft: device path, or the form row ' \
                'id the endpoint reported; nothing was asked of the machine with this identifier'
        end

        if context == :vm
          # Fog's own constructor is the key guard one layer down: a key with no
          # setter there fails as UnknownAttribute, so only keys fog would
          # happily accept but this resource must own are refused here.
          raise unsafe(key) if FORBIDDEN_VM_KEYS.include?(key) && value.present?

          return
        end

        # A nested hash no model of ours describes — an unknown key under the
        # machine, or an unknown hash under a device: the shape gate in walk has
        # already refused keys that are not bare words, the value check owns the
        # characters, and fog's own constructor stays the key guard one layer
        # down (the same reasoning as the machine context above).
        return if context == :generic

        # NIC/disk/DVD hashes are dispatched through send(), so the key list is
        # the fixpoint: not-on-the-list is refused whatever it would reach.
        raise unsafe(key) unless CONTEXT_KEYS.fetch(context).include?(key)
      end

      def check_value!(key, value, context:)
        case value
        when Hash
          check_hash!(key, value, context: context)
        when Array
          value.each { |item| check_value!(key, item, context: context) }
        when String, Symbol
          check_text!(key, value, context: context)
        end
        # Numbers, booleans and the rest carry no text for the script line.
      end

      # Nested hashes arrive two ways: as the indexed form the web form submits
      # ({"0" => {...}, "1" => {...}}) and as the plain item the API and hammer
      # submit. The indexed wrapper is unwrapped so items meet their model's
      # key list, not the index.
      def check_hash!(key, value, context:)
        child = child_context(key, context)
        if CONTEXT_KEYS.key?(child) && indexed_collection?(value)
          value.each_value do |item|
            item.is_a?(Hash) ? check_hash!(key, item, context: context) : check_text!(key, item)
          end
          return
        end

        walk(deep_symbolize(value), context: child)
      end

      def indexed_collection?(hash)
        hash.any? && hash.keys.all? { |k| k.to_s.match?(INDEXED_KEY) }
      end

      def child_context(key, context)
        return VM_CHILD_CONTEXTS.fetch(key, :generic) if context == :vm
        return :nic if context == :nic && key == :compute_attributes

        :generic
      end

      def check_text!(key, value, context: :vm)
        text = value.to_s
        return if text.empty?

        pattern = context == :generic ? DEFAULT_TEXT : TEXT_BY_KEY.fetch(key, DEFAULT_TEXT)
        raise unsafe(key) unless text.match?(pattern)
      end

      def deep_symbolize(value)
        value.to_hash.deep_symbolize_keys
      rescue NoMethodError
        value
      end

      def unsafe(key)
        # Hash keys arrive from user params too, so the field name is only
        # quoted back when it is a bare word: anything else could smuggle a
        # log line, or a stray percent sign into Foreman::Exception's later
        # sprintf of this very message.
        field = key.to_s
        field = 'an unrecognised field' unless field.match?(/\A[A-Za-z0-9_]+\z/)
        message = 'Refusing to send this to the Hyper-V host: the value for ' \
                  '\'%<field>s\' is not text that field is allowed to carry'

        ForemanHyperv::UnsafeIdentifier.new(format(message, field: field))
      end
    end
  end
end
