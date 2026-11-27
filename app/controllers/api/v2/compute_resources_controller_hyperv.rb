# frozen_string_literal: true

module Api
  module V2
    # PLG-59: the authorization half of the plugin's switch_hosts endpoint,
    # PREPENDED onto core's compute-resources controller by the engine's
    # to_prepare. Prepend, not class_eval: Api::BaseController#action_permission
    # RAISES "unknown permission" for any action nothing claims, and core's own
    # mapping (every available_* action to :view) must stay in the chain for
    # everything else this controller serves. Everything switch_hosts needs
    # here is the one fact core cannot know: it is a read, so it takes
    # view_compute_resources.
    module ComputeResourcesControllerHyperv
      # The named door onto core's find_resource. It must NOT be registered
      # under find_resource's own name: Rails REPLACES a callback when the
      # same filter name is registered again with different options, so a
      # second `before_action :find_resource, only: [:switch_hosts]` silently
      # dropped core's full list and nil-ed @compute_resource on every other
      # action — measured live on the test bed, available_networks 500 with
      # "undefined method `available_clusters' for nil:NilClass". Calling
      # find_resource by name keeps the whole ladder (friendly id, taxonomy
      # scope, not-found) intact for this action alone.
      def find_resource_for_switch_hosts
        find_resource
      end

      def action_permission
        return :view if params[:action].to_s == 'switch_hosts'

        super
      end
    end
  end
end
