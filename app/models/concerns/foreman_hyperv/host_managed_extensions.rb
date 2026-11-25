# frozen_string_literal: true

module ForemanHyperv
  module HostManagedExtensions
    extend ActiveSupport::Concern

    def update(attributes = {})
      if provider == 'Hyper-V' && attributes.key?('compute_attributes')
        # bootdisk PR-5: carry the ISO destination across the save FIRST, so
        # the interface injection below sees the whole submitted intent.
        hyperv_preserve_iso_upload_storage(attributes)
        hyperv_add_attributes(attributes)
      end

      super
    end

    def setComputeUpdate
      ret = super
      return ret unless provider == 'Hyper-V'

      begin
        hyperv_sync_interfaces
      rescue StandardError => e
        failure format(_('Failed to update a compute %<compute_resource>s instance %<name>s: %<e>s'),
                       compute_resource: compute_resource, name: name, e: e), e
      end
      true
    end

    private

    # bootdisk PR-5: the carry. foreman_bootdisk ships NO widget for
    # iso_upload_storage (grepped 24.1.0's views, lib and helpers: zero
    # writers) — the key is set through the API/hammer and lives in the
    # host's stored compute_attributes, which is exactly where the
    # orchestration reads it (compute.rb:76-78). A UI edit re-renders only
    # what the form draws, and Host::Managed#vm_compute_attributes
    # (managed.rb:720-722) seeds the form from the LIVE fog model, which
    # holds no such property — so without this carry every UI save would
    # wipe the operator's ISO destination mid-flow. A submission that NAMES
    # the key always wins (the API's explicit '' clear stays possible); this
    # only replaces absence.
    def hyperv_preserve_iso_upload_storage(attributes)
      compute = attributes['compute_attributes']
      return unless compute.is_a?(Hash)
      return if compute.key?(:iso_upload_storage) || compute.key?('iso_upload_storage')

      stored = (compute_attributes || {}).with_indifferent_access
      carried = stored[:iso_upload_storage]
      compute['iso_upload_storage'] = carried if carried.present?
    end

    # Reconcile the mapping between Hyper-V and Foreman interfaces
    def hyperv_sync_interfaces
      unmapped_ifaces = interfaces.select { |iface| iface.physical? && iface.compute_attributes['identity'].blank? }
      return true if unmapped_ifaces.empty?

      logger.info "Mapping #{unmapped_ifaces.count} unknown interfaces for #{name}"

      self.vm = compute_object
      fog_nics = vm.interfaces.dup
      interfaces.each { |iface| fog_nics.delete_if { |vmiface| vmiface.id == iface.compute_attributes['identity'] } }

      unmapped_ifaces.each do |nic|
        logger.debug "Matching #{nic.inspect} against #{fog_nics}"
        selected_nic = vm.select_nic(fog_nics, nic)
        if selected_nic.nil?
          logger.warn "Orchestration::Compute: Could not match network interface #{nic.inspect}"
          raise ArgumentError, format(_('Could not find virtual machine network interface matching %s'),
                                      [nic.identifier, nic.ip, nic.name, nic.type].find(&:present?))
        end

        logger.debug "Orchestration::Compute: nic #{nic.inspect} assigned to #{selected_nic.inspect}"
        nic.mac ||= selected_nic.mac
        nic.save
        fog_nics.delete selected_nic
      end
    end

    # Inject interface attributes into the compute values, to allow modifying Hyper-V configuration on hosts
    def hyperv_add_attributes(attributes)
      compute = attributes['compute_attributes'] ||= {}
      compute['interfaces_attributes'] ||= {}

      attributes['interfaces_attributes'].each do |idx, interface|
        compute['interfaces_attributes'][idx] = interface
      end
    end
  end
end
