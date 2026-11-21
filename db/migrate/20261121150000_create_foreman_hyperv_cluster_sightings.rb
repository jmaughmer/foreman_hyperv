# frozen_string_literal: true

# PLG-21b (B6): the insert-only ledger behind the standalone rules. A row says
# only that this compute resource's endpoint answered as a cluster (or that a
# cluster-role write left a machine stranded) at the timestamp on the row —
# rows are never updated and never deleted, so a later "not clustered" read
# can never erase an earlier sighting. 15c's destroy gate reads this table
# first: one sighting is enough to keep a destroy refused.
class CreateForemanHypervClusterSightings < ActiveRecord::Migration[6.1]
  def change
    create_table :foreman_hyperv_cluster_sightings do |t|
      t.string :endpoint_host, null: false
      t.string :kind, null: false
      t.string :vm_uuid
      t.string :vm_name
      t.string :cluster_name
      t.string :reason

      t.timestamps
    end

    add_index :foreman_hyperv_cluster_sightings, :endpoint_host,
              name: 'index_foreman_hyperv_sightings_on_endpoint_host'
    add_index :foreman_hyperv_cluster_sightings, :vm_uuid,
              name: 'index_foreman_hyperv_sightings_on_vm_uuid'
  end
end
