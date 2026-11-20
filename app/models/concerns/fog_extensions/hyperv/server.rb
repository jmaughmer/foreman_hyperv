# frozen_string_literal: true

module FogExtensions
  module Hyperv
    module Server
      extend ActiveSupport::Concern
      include ActionView::Helpers::NumberHelper

      def to_s
        name
      end

      def folder_name
        name.gsub(/[^0-9A-Za-z.-]/, '_')
      end

      def mac
        network_adapters.first&.mac
      end

      def interfaces
        network_adapters
      end

      def volumes
        hard_drives
      end

      def interfaces_attributes=(_attributes); end

      def volumes_attributes=(_attributes); end

      # Cluster placement: the folder this machine's disks go into instead of
      # wherever its node keeps disks by default. A clustered machine's disks have
      # to live on cluster shared storage, so the compute resource sets this to
      # C:\ClusterStorage\<volume>\<vm name> while it builds the machine; nil — the
      # case for every stand-alone machine, and for every machine before the
      # resource has a cluster — leaves fog's own path building in charge.
      attr_accessor :placement_path

      # fog builds this from the node's VirtualHardDiskPath; for a machine being
      # placed onto a cluster shared volume that path is the wrong drive entirely.
      def build_vhd_path(filename = nil)
        return [placement_path, filename].compact.join('\\') if placement_path

        super
      end

      # Override fog configuration with explicit cluster_name handling
      def cluster
        @cluster
      end

      def cluster_name
        cluster&.name
      end

      # Cluster placement: asked of the CACHED listing in Ruby, never by name.
      # This setter ran service.clusters.get(name) during mass assignment, and
      # fog's Clusters#get interpolated the name into a Get-Cluster filter
      # remote PowerShell — a create-time hash naming a cluster executed script
      # text on the host before any create had happened. Membership in what the
      # endpoint itself reported is the only answer, checked character-first;
      # a name that is not a member, or a listing that will not read, refuses
      # the assignment rather than asking the host about the string.
      def cluster_name=(name)
        if name.blank?
          @cluster = nil
          return
        end

        wanted = name.to_s
        ForemanHyperv::InputValidation.refuse_text!(:cluster_name, wanted)
        found = service.clusters.all.detect do |candidate|
          candidate.name.to_s.casecmp?(wanted) || candidate.id.to_s.casecmp?(wanted)
        end
        unless found
          raise ForemanHyperv::OperationRefused,
                'Refusing to bind a machine to a cluster this compute resource has not read from ' \
                'its endpoint; nothing was asked of the host with that name'
        end

        @cluster = found
      end

      def boot_device
        :NetworkAdapter
      end

      def foreman_firmware_type
        return 'bios' if generation_num == 1

        secure_boot_enabled ? 'uefi_secure_boot' : 'uefi'
      end

      def foreman_firmware
        generation_num == 1 ? 'bios' : 'efi'
      end

      def vlan
        nic = network_adapters.first
        return if nic.nil?

        nic.access_vlan_id || nic.native_vlan_id || nic.primary_vlan_id
      end

      def vlan=(vlan)
        logger.warn "using vlan=#{vlan.inspect} on Hyper-V VM, this can lead to unexpected results"
        nic = network_adapters.first
        if vlan.present? && vlan.to_i.positive?
          nic.vlan_operation_mode = :Access if nic.vlan_operation_mode == :Untagged
          case nic.vlan_operation_mode
          when :Access
            nic.access_vlan_id = vlan
          when :Trunk
            nic.native_vlan_id = vlan
          when :Private
            nic.primary_vlan_id = vlan
          end
        else
          nic.vlan_operation_mode = :Untagged
        end
      end

      def secure_boot_enabled=(enabled)
        return if generation != :UEFI
        return unless persisted?

        firmware.secure_boot = enabled ? :On : :Off
        firmware.save
      end

      def secure_boot_enabled
        return false if generation != :UEFI
        return unless persisted?

        firmware.secure_boot == :On
      end

      def vm_description
        format _('%{cpus} CPUs and %{ram} memory'),
               cpus: processor_count,
               ram: number_to_human_size(memory_startup)
      end

      def select_nic(fog_nics, nic)
        nic_attrs = nic.compute_attributes

        # Match for exact data
        match   = fog_nics.detect { |fn| fn.id == nic_attrs['id'].presence }
        match ||= fog_nics.detect { |fn| fn.mac == nic.mac }
        # match ||= fog_nics.detect { |fn| fn.name == nic_attrs['name'].presence }

        unless match
          # Match on networking, limit potentials down to identical configuration and then pick the first
          potential = fog_nics.select do |fn|
            fn.switch_id == nic_attrs['switch_id'].presence || fn.switch_name == nic_attrs['switch_name'].presence
          end
          potential.select! { |fn| fn.vlan_operation_mode.to_s == nic_attrs['vlan_operation_mode'] }
          case nic_attrs['vlan_operation_mode']
          when 'Access'
            potential.select! { |fn| fn.access_vlan_id.to_s == nic_attrs['access_vlan_id'] }
          when 'Trunk'
            potential.select! { |fn| fn.native_vlan_id.to_s == nic_attrs['native_vlan_id'] }
            if nic_attrs['allowed_vlan_ids'].present?
              potential.select! do |fn|
                fn.allowed_vlan_ids.split(',').map(&:strip) == nic_attrs['allowed_vlan_ids'].split(',').map(&:strip)
              end
            end
          when 'Private'
            potential.select! { |fn| fn.vlan_private_mode.to_s == nic_attrs['vlan_private_mode'] }
            potential.select! { |fn| fn.primary_vlan_id.to_s == nic_attrs['primary_vlan_id'].to_s } \
              if nic_attrs['primary_vlan_id'].present?

            if nic_attrs['vlan_private_mode'] == 'Promiscuous'
              if nic_attrs['secondary_vlan_ids'].present?
                potential.select! do |fn|
                  fn.secondary_vlan_ids.split(',').map(&:strip) == nic_attrs['secondary_vlan_ids'].split(',').map(&:strip)
                end
              end
            elsif nic_attrs['secondary_vlan_id'].present?
              potential.select! { |fn| fn.secondary_vlan_id.to_s == nic_attrs['secondary_vlan_id'].to_s }
            end
          end

          match = potential.first
        end
        return unless match

        # Store Hyper-V ID in compute attributes
        nic.compute_attributes['identity'] = match.id

        match
      end
    end
  end
end
