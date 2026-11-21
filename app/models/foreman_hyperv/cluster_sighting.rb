# frozen_string_literal: true

module ForemanHyperv
  # B6: the insert-only ledger of the times a Hyper-V compute resource's
  # endpoint answered as a cluster (kind sighting) or left a machine stranded
  # by an unproven cluster-role write (kind strand). Rows are written once and
  # never changed: the point of the ledger is that a later "not clustered"
  # reading can never erase an earlier cluster sighting, because a node that
  # has left a cluster looks exactly like a node that never joined it on every
  # reading that outlives the membership. PLG-15c's standalone destroy gate
  # reads this table first — one sighting is enough to keep a destroy refused.
  class ClusterSighting < ApplicationRecord
    KINDS = %w[sighting strand].freeze

    self.table_name = 'foreman_hyperv_cluster_sightings'

    validates :endpoint_host, presence: true
    validate :endpoint_host_is_normalized
    validates :kind, inclusion: { in: KINDS }

    before_update :refuse_mutation
    before_destroy :refuse_mutation

    private

    # The ledger is read back by endpoint host, so the stored shape is fixed
    # at write time (trimmed and downcased) rather than normalized at read
    # time, when a second copy of one endpoint could already have slipped in.
    def endpoint_host_is_normalized
      return if endpoint_host.blank?
      return if endpoint_host == endpoint_host.strip.downcase

      errors.add(:endpoint_host, 'must be stored normalized (trimmed and downcased)')
    end

    def refuse_mutation
      errors.add(:base, 'cluster sightings are an insert-only ledger: rows are never updated or deleted')
      throw :abort
    end
  end
end
