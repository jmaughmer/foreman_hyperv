# frozen_string_literal: true

# PLG-34: the per-resource switch for keepalive. The first remote read after
# an idle gap costs the human a cold WinRM shell — measured 20-120 s per node,
# 60-250 s in contention windows (§66/§67) — and PLG-33b's overlap leaves that
# one hop at full price. A scheduled tick (ForemanHyperv::Keepalive) replays
# one page load's reads so a human's load is always a warm one; this column is
# the operator saying yes to that, per resource, default OFF (the plugin never
# dials a node nobody asked it to keep warm).
class AddHypervKeepaliveToComputeResources < ActiveRecord::Migration[6.1]
  def change
    add_column :compute_resources, :hyperv_keepalive, :boolean, null: false, default: false
  end
end
