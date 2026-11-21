# frozen_string_literal: true

# PLG-5a: the operator node→endpoint override, one `NODE = host[:port]` line
# per cluster node this compute resource's own client does not serve. The
# value is a bare host or host:port — the identity SPLICED into the compute
# resource's scheme and port to compose that node's endpoint (N4); it is the
# only source of qualified node identity (N5), so it lives next to the
# endpoint it composes into. NULL (the default) means no overrides: every
# node the endpoint itself does not serve stays fail-closed, exactly as it
# was before this attribute existed.
class AddHypervNodeOverridesToComputeResources < ActiveRecord::Migration[6.1]
  def change
    add_column :compute_resources, :hyperv_node_overrides, :text
  end
end
