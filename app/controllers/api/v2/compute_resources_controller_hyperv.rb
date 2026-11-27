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
      def action_permission
        return :view if params[:action].to_s == 'switch_hosts'

        super
      end
    end
  end
end
