# frozen_string_literal: true

# PLG-5b: the CA file a hardened (https) compute resource verifies its
# per-node certificates against. Row (w) measured that winrm's default trust
# store does not see this platform's system anchors, so the https rows
# verified ONLY against an explicitly named CA file (fog's
# hyperv_ca_trust_path option); an https per-node composition without it is
# refused, so this attribute is what makes the hardened ladder rungs dialable
# at all. NULL (the default) means no explicit trust: http resources need
# none, and https per-node compositions stay refused — exactly the fail-closed
# state that preceded this attribute. (The class spells CA uppercase because
# that is what the inflector camelizes `hyperv_ca_trust_path` to — the name
# must round-trip for ActiveRecord's constantize.)
class AddHypervCATrustPathToComputeResources < ActiveRecord::Migration[6.1]
  def change
    add_column :compute_resources, :hyperv_ca_trust_path, :string
  end
end
