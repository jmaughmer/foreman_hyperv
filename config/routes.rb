# frozen_string_literal: true

# PLG-59: the plugin's first API route, and the pattern every later one rides.
# The scope stanza is core's own (ApiConstraints, optional (:apiv), module :v2)
# copied from core's api routes so a plugin route lands in exactly the version
# and constraint world the core compute_resources routes live in; the member
# route then hangs off CORE's resources the same way core hangs
# available_networks off them. GET only, format json always.
Rails.application.routes.draw do
  namespace :api, defaults: { format: 'json' } do
    scope '(:apiv)', module: :v2, defaults: { apiv: 'v2' }, apiv: /v1|v2/, constraints: ApiConstraints.new(version: 2, default: false) do
      resources :compute_resources, only: [] do
        member do
          get :switch_hosts
        end
      end
    end
  end
end
