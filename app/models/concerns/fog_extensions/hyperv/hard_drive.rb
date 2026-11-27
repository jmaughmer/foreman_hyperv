# frozen_string_literal: true

module FogExtensions
  module Hyperv
    module HardDrive
      extend ActiveSupport::Concern
      include ActionView::Helpers::NumberHelper

      # PLG-58: the API documents datastore on volumes_attributes — the shared
      # volume a clustered machine's disk is asked for — and this plugin gives
      # the key meaning: validate_placement! checks its membership against the
      # cluster's own shared-volume listing and placement_storage composes the
      # placement from it. Both read the request hash; but new_vm's volume
      # assignment hands every submitted key to the model as a writer, and the
      # key died there (measured 2026-11-27: undefined method `datastore=' for
      # Fog::Hyperv::Compute::HardDrive) before either question was asked.
      # This accessor exists so the assignment survives a key fog never
      # persists — not a declared fog attribute, so it stays out of the
      # request the model composes (the iso_upload_storage pattern on Server).
      attr_accessor :datastore

      def size_bytes=(new_size)
        raise ArgumentError, "Can't modify a physical disk" if disk

        self.vhd ||= Fog::Hyperv::Compute::Vhd.new unless persisted?
        vhd.size = new_size
      end

      def basename
        vhd&.basename
      end

      def basename=(new_basename)
        raise ArgumentError, "Can't modify a physical disk" if disk

        self.vhd ||= Fog::Hyperv::Compute::Vhd.new unless persisted?
        vhd.basename = new_basename
      end

      def compute_attributes
        attributes
          .slice(:id)
          .merge(
            {
              basename: basename,
              size_bytes: size_bytes
            }.compact
          )
      end
    end
  end
end
