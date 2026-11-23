# frozen_string_literal: true

# PLG-32: the operator's deliberate opt-out of WinRM certificate
# verification, per compute resource. Verifying the peer certificate on an
# https endpoint stays the default (fog's own default, row (w)'s measured
# trust model); this column is the loud lever that switches it off for an
# endpoint the operator has decided to trust anyway — the same stance fog
# documents for hyperv_ssl_verify: false. It is a dedicated hyperv_* column,
# not a reuse of core's ssl_verify, because core gives that attribute its own
# per-provider semantics and this plugin's wire partner is fog's option of
# the same name (the PLG-5a/5b precedent). true (the default) changes no wire
# at all: the plugin sends the fog option only when it is false.
class AddHypervSslVerifyToComputeResources < ActiveRecord::Migration[6.1]
  def change
    add_column :compute_resources, :hyperv_ssl_verify, :boolean, null: false, default: true
  end
end
