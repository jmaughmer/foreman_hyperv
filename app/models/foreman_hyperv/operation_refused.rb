# frozen_string_literal: true

module ForemanHyperv
  # An operation this plugin version refuses outright — machine creates, machine
  # destroys and disk removals — rather than one whose input was unsafe. The
  # refusal is a code state with a named enablement path (the message carries
  # it verbatim), not a configuration anyone can flip; lifting it is itself a
  # reviewed PR. Like UnsafeIdentifier it sits outside every rescue list that
  # quietly converts a refused operation into a successful one, so a refused
  # destroy can never report success and orphan the machine.
  class OperationRefused < Foreman::Exception
  end
end
