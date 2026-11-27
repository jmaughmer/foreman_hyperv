# PLG-59: the switch map keyed by nothing but its own truth — a host the
# cluster reports but whose read did not answer holds null, never []. The
# consumer's three states are: present, proven absent (a name list without
# the name), and unknown (null / a missing key), and the JSON keeps them
# exactly that distinguishable.
object @compute_resource => :compute_resource
attributes :id, :name

node(:switch_hosts) { |_cr| @switch_hosts }
node(:endpoint_switches) { |_cr| @endpoint_switches }
