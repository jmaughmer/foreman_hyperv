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
    # writers) — the key is set through the API/hammer and lands on the
    # request's compute_attributes accessor (the included-do attr_accessor at
    # compute.rb:9), which is exactly where the orchestration reads it at the
    # queued build (compute.rb:76-78). There is no storing to speak of: hosts
    # has no compute_attributes column on the installed core (measured
    # 2026-11-26 — columns_hash answers nil, the packaged migrations only
    # ever added the old compute-profile KV table and the nics column, and
    # assigning the key marks no dirty column), so the compute_attributes
    # this carry reads can only be what the current request's own assignment
    # put there. What the carry is therefore worth: within one request that
    # submits the key, #update re-injects a key the accessor already holds
    # (the no-op PLG-48 pins); in a fresh request it finds nothing, form
    # prefill included — the form seeds from the LIVE fog model
    # (vm_compute_attributes, managed.rb:720-722), which holds no such
    # property. Round 52 RULED no shipped production flow presents #update a
    # non-nil accessor in a fresh request, so TODAY this carries nothing
    # there; whether it earns its keep or simplifies out is the open design
    # question for the bootdisk activation window (production is opt-in and
    # dormant). The mechanical contract stays: a submission that NAMES the
    # key always wins (the API's explicit '' clear stays possible); this only
    # replaces absence.
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
