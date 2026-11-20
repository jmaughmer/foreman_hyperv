# frozen_string_literal: true

module ForemanHyperv
  # A value that must never be carried to the hypervisor, raised by
  # ForemanHyperv::InputValidation before any fog call sees the string.
  #
  # The class is deliberately not a NotFound of any shape. destroy_vm turns
  # ActiveRecord::RecordNotFound and Fog::Errors::NotFound into a successful
  # delete (fog's own collection.rb comment relies on that), and
  # vm_from_cluster_owner swallows StandardError into nil: a refusal that
  # arrived as "not found" would report a refused machine as deleted and leave
  # the machine running, which is exactly the failure this plugin refuses to
  # make about a machine's storage. It lives under app/ rather than lib/
  # because its superclass only exists once the Foreman app is up.
  class UnsafeIdentifier < Foreman::Exception
  end
end
