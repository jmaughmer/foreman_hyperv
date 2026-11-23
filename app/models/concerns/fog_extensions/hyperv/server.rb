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

      # PLG-16 retired the shim's placement_path accessor and build_vhd_path
      # override: fog declares placement_path itself (FOG-17) and owns the one
      # disk-folder join that refuses — instead of joining relative — every
      # shape that cannot name an absolute location. The compute resource
      # names the placement in the servers.new attributes; nothing here
      # answers for it again.

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
        format _('%<cpus>s CPUs and %<ram>s memory'),
               cpus: processor_count,
               ram: number_to_human_size(memory_startup)
      end

      # PLG-28: the endpoint's switch-name translation, handed to the machine by
      # the compute resource that built it (create_vm). A virtual switch is a
      # per-node resource: a NIC record carries the endpoint's GUID for the
      # switch the form offered, and a machine built on another node answers the
      # node's own GUID for the switch of the same name. Only the endpoint's own
      # listing knows one GUID IS the other's name, and the machine core reads
      # back for MAC assignment must answer with it — so the resource gives it
      # the listing's translation, and the matcher below uses it. A machine that
      # carries no resolver (the endpoint rung) matches on GUIDs alone, exactly
      # as before.
      attr_accessor :switch_name_resolver

      # PLG-30: the create form's Automatic failback checkbox is answered on the
      # machine the form renders (checkbox_f reads f.object.auto_failback), but
      # the CLUSTER's reported value lives on the cluster role, not here — this
      # accessor exists so the form can render a create-time REQUEST: fresh it
      # is nil (the box renders unchecked), the form value survives assignment
      # for the create path to read out of attr, and neither costs a wire
      # round trip. The write itself rides the cluster-role request
      # (set_cluster_virtual_machine_role_auto_failback), never this model.
      # Without it the create form 500s at render for every compute resource:
      # the fog Server has no such attribute of its own.
      attr_accessor :auto_failback

      def select_nic(fog_nics, nic)
        nic_attrs = nic.compute_attributes

        # Match for exact data
        match   = fog_nics.detect { |fn| fn.id == nic_attrs['id'].presence }
        match ||= fog_nics.detect { |fn| fn.mac == nic.mac }
        # match ||= fog_nics.detect { |fn| fn.name == nic_attrs['name'].presence }

        unless match
          # Match on networking, limit potentials down to identical configuration and then pick the first.
          # PLG-28: the endpoint GUID the NIC record carries names a switch every node shares by NAME,
          # so when the compute resource's translation resolves that GUID, the shared name joins the
          # identities a cross-node adapter may answer to — bridged only where the endpoint proves it.
          endpoint_name = switch_name_resolver&.call(nic_attrs['switch_id'].presence)
          potential = fog_nics.select do |fn|
            fn.switch_id == nic_attrs['switch_id'].presence ||
              fn.switch_name == nic_attrs['switch_name'].presence ||
              (endpoint_name.present? && fn.switch_name == endpoint_name)
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
                  fn.secondary_vlan_ids.split(',').map(&:strip) ==
                    nic_attrs['secondary_vlan_ids'].split(',').map(&:strip)
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
