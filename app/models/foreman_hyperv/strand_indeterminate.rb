# frozen_string_literal: true

module ForemanHyperv
  # The plugin asked the cluster to take a machine as a role and cannot tell
  # whether it did: the fog write raised after the request had been sent (fog
  # reports even a successful Add as a JSON decode failure), and the readbacks
  # did not find the role. Success, failure and partial application cannot be
  # told apart from here, and every destructive rollback would act on that
  # guess — so this exception means "touch nothing": no stop, no disk deletes,
  # no destroy, no role removal. The machine is left exactly as it is, the
  # strand is recorded in the log for the operator, and lifting the refusal is
  # a code PR under the same named conditions as every other one here.
  #
  # Like UnsafeIdentifier and OperationRefused it sits outside every rescue
  # list that quietly converts a failed operation into a successful one, so a
  # create that ended indeterminate can never report success.
  class StrandIndeterminate < Foreman::Exception
  end
end
