# frozen_string_literal: true

require 'test_helper'

# PLG-29a: the compute resource's VM list must say HOW a machine is registered —
# held by the cluster, or a bare registration on a node — because the two need
# opposite cleanups, and the list currently prints neither.
#
# The shape that started this (evidence §58): an operator deleted a machine
# through Failover Cluster Manager, which released the cluster role and left the
# VM registration behind on the node. Foreman's instance list — a live fog read,
# this provider caches nothing — kept showing a machine that looked exactly like
# a healthy one. "Computer: HV-NODE1" describes which node answered the read,
# not who owns the machine, so nothing on the row distinguished a clustered VM
# from an unhosted leftover sitting on C:\ClusterStorage.
#
# What this suite pins, in the order the claims get stronger:
#
#   1. the cluster's OWN answer decides "clustered": a role names the machine
#      (by GUID, case-insensitively — fog's -VMId filter is case-insensitive
#      too — or, when the id field is empty as it can be on real hosts, by the
#      group name the cluster builds from the machine's name);
#   2. "no role" means "no role" only when the cluster ANSWERED. A cluster that
#      raises, and a fog that cannot be asked at all, answer :unknown and never a
#      stand-alone verdict: fog keeps its own tri-state precisely because "no
#      role" is the answer that licenses disk removal, and a display column is
#      not the place to flatten it. An endpoint that answers the cluster question
#      with "I am not a cluster" has disproven the question instead, and prints
#      the true stand-alone;
#   3. the leftover signature — no role, and config on a Cluster Shared Volume
#      — is called what it is, because that combination cannot be produced by a
#      healthy lifecycle: a machine created by this plugin on cluster storage
#      gets a role (PLG-22/27), and a machine the cluster released without being
#      deleted keeps the path and loses the role;
#   4. one page renders one cluster read, not one per row (a per-VM role probe
#      costs 2–8 s here, and the page lists every machine the node answers).
class HypervRegistrationColumnTest < ActiveSupport::TestCase
  HOST = 'hv-node1'
  CR_URL = "http://#{HOST}:5985/wsman".freeze
  ELENA = '3323c48a-a1bb-4609-b25d-b02013bc701f'
  NICK = '55fa093f-1d2e-413c-a945-a505b8f4a46e'
  CSV = 'C:\ClusterStorage\Volume1'

  # A cluster role exactly as fog's ClusterVirtualMachineRole answers it: the
  # group name the cluster builds ("Virtual Machine <machine name>", measured
  # prefix), the documented virtual_machine_id, and the node that owns it now.
  RoleDouble = Struct.new(:name, :virtual_machine_id, :owner_node, keyword_init: true)

  # The roles collection, counting every read so the batch claim is observable.
  class RolesDouble
    attr_reader :calls

    def initialize(roles, raise_error: nil)
      @roles = roles
      @raise_error = raise_error
      @calls = 0
    end

    def all(_filters = nil)
      @calls += 1
      raise @raise_error if @raise_error

      @roles
    end
  end

  class FogDouble
    def initialize(roles_collection)
      @roles_collection = roles_collection
    end

    def cluster_virtual_machine_roles
      @roles_collection
    end

    def supports_clusters?
      true
    end
  end

  # A fog client on a stand-alone host: the cluster vocabulary is there, and the
  # endpoint answers that it is not a cluster.
  class NonClusterFogDouble < FogDouble
    def supports_clusters?
      false
    end
  end

  # A fog too old to speak clusters at all — the vocabulary is absent, which is
  # NOT the same answer as a probed "no".
  class LegacyFogDouble
    def supports_clusters?
      true
    end
  end

  # The listed machine: the three attributes the column reads.
  VmDouble = Struct.new(:id, :name, :path, keyword_init: true)

  def build_cr(fog)
    cr = ForemanHyperv::Hyperv.new(name: 'lab-cr', url: CR_URL, user: 'u', password: 'p')
    cr.stubs(:client).returns(fog)
    cr
  end

  # The machine the acceptance row created: a role, and the node that owns it.
  def clustered_vm
    VmDouble.new(id: ELENA, name: 'elena-smolen.maughmer.net', path: "#{CSV}\\elena-smolen.maughmer.net")
  end

  # The machine the operator released from the cluster and never deleted: same
  # storage class, no role (measured: the cluster answered with only its core
  # WMI resource while Get-VM on the node still answered this VM).
  def leftover_vm
    VmDouble.new(id: NICK, name: 'nick-abril.maughmer.net', path: "#{CSV}\\nick-abril.maughmer.net")
  end

  def standalone_vm
    VmDouble.new(id: 'cccc1111-2222-3333-4444-555566667777', name: 'plain.maughmer.net',
                 path: 'C:\Users\Public\Documents\Hyper-V\Virtual hard disks')
  end

  def test_a_machine_the_cluster_names_by_guid_reads_as_clustered_with_its_owner
    # The cluster reports ids upper-case (measured: 'Microsoft:47BCF071-75B6-…');
    # the plugin holds lower-case GUIDs, so the join must not be case-sensitive.
    roles = [RoleDouble.new(name: 'Virtual Machine elena-smolen.maughmer.net',
                            virtual_machine_id: ELENA.upcase, owner_node: 'HV-NODE2')]
    registration = build_cr(FogDouble.new(RolesDouble.new(roles))).vm_registration(clustered_vm)

    assert_equal :clustered, registration.state,
                 'the cluster holds a role for this exact GUID: the machine fails over with the cluster'
    assert_equal 'HV-NODE2', registration.owner_node,
                 'the column must name the node that OWNS the machine, not the node that answered the read ' \
                 '(computer_name is the reader and goes stale on a live move)'
  end

  def test_a_role_answering_no_id_still_counts_when_the_group_name_names_the_machine
    # fog's own readback accepts this shape: the id field is reported on
    # ClusterGroup but undocumented, so it may be empty on a real host.
    roles = [RoleDouble.new(name: "Virtual Machine #{clustered_vm.name}", virtual_machine_id: nil,
                            owner_node: 'HV-NODE1')]
    registration = build_cr(FogDouble.new(RolesDouble.new(roles))).vm_registration(clustered_vm)

    assert_equal :clustered, registration.state,
                 'an empty id field is not an absent role: the group name the cluster builds from the ' \
                 'machine name is the documented identity behind it'
  end

  def test_a_registration_on_cluster_storage_without_a_role_is_called_a_leftover
    registration = build_cr(FogDouble.new(RolesDouble.new([]))).vm_registration(leftover_vm)

    assert_equal :clustered_storage_without_role, registration.state,
                 'a machine on a Cluster Shared Volume with no role is the fingerprint of a release ' \
                 'without a delete (Failover Cluster Manager leaves exactly this behind) — and it is ' \
                 'the row an operator is cleaning up, so the list has to be able to say it'
  end

  def test_a_machine_off_cluster_storage_without_a_role_is_standalone
    registration = build_cr(FogDouble.new(RolesDouble.new([]))).vm_registration(standalone_vm)

    assert_equal :standalone, registration.state,
                 'the same absent role on a node-local path is a healthy stand-alone machine, ' \
                 'and must not be flagged as cleanup for anyone'
  end

  def test_a_cluster_that_raises_is_unknown_and_never_standalone
    roles = RolesDouble.new([], raise_error: Timeout::Error)
    registration = build_cr(FogDouble.new(roles)).vm_registration(clustered_vm)

    assert_equal :unknown, registration.state,
                 'a cluster that could not answer is not a cluster that answered "no role": fog keeps ' \
                 'that tri-state precisely because "no role" licenses disk removal, and the list is ' \
                 'where an operator decides what to delete'
  end

  def test_a_proven_non_cluster_endpoint_reads_as_stand_alone
    registration = build_cr(NonClusterFogDouble.new(RolesDouble.new([]))).vm_registration(standalone_vm)

    assert_equal :standalone_no_cluster, registration.state,
                 'an endpoint that answers the cluster question with "I am not a cluster" has proven ' \
                 'the absence: every machine it holds is stand-alone by definition, and that is the ' \
                 'useful true thing to print — not a shrug over a healthy machine'
  end

  def test_a_fog_without_the_cluster_vocabulary_is_unknown
    registration = build_cr(LegacyFogDouble.new).vm_registration(standalone_vm)

    assert_equal :unknown, registration.state,
                 'a fog that cannot be asked is not a fog that answered "no cluster": an old partner ' \
                 'has not disproven the cluster, so the column stays honest about not knowing'
  end

  def test_a_machine_with_no_id_cannot_be_asked_about
    cr = build_cr(FogDouble.new(RolesDouble.new([])))
    registration = cr.vm_registration(VmDouble.new(id: nil, name: 'x', path: CSV))

    assert_equal :unknown, registration.state,
                 'with nothing to key on the answer is "not asked", not "no role"'
  end

  def test_one_page_render_reads_the_cluster_once_not_once_per_machine
    roles = RolesDouble.new([RoleDouble.new(name: 'Virtual Machine elena-smolen.maughmer.net',
                                            virtual_machine_id: ELENA, owner_node: 'HV-NODE2')])
    cr = build_cr(FogDouble.new(roles))

    [clustered_vm, leftover_vm, standalone_vm].each { |vm| cr.vm_registration(vm) }

    assert_equal 1, roles.calls,
                 'the role question is a cluster-wide read: one call answers every machine on the page, ' \
                 'and a per-machine probe would multiply a 2-8 s round trip by the row count'
  end

  def test_the_labels_say_what_the_operator_can_do_with_each_row
    elenas_role = RoleDouble.new(name: 'Virtual Machine elena-smolen.maughmer.net',
                                 virtual_machine_id: ELENA, owner_node: 'HV-NODE2')
    clustered = build_cr(FogDouble.new(RolesDouble.new([elenas_role]))).vm_registration(clustered_vm)
    leftover = build_cr(FogDouble.new(RolesDouble.new([]))).vm_registration(leftover_vm)
    standalone = build_cr(FogDouble.new(RolesDouble.new([]))).vm_registration(standalone_vm)
    unknown = build_cr(LegacyFogDouble.new).vm_registration(standalone_vm)

    assert_includes clustered.label, 'owner HV-NODE2',
                    'the clustered row names the OWNING node: the Computer column already prints the ' \
                    'node that answered, and two columns agreeing on the reader is how a live move ' \
                    'goes unnoticed'
    assert_not clustered.warning?, 'a clustered machine is a healthy machine'
    assert_includes leftover.label, 'no cluster role'
    assert leftover.warning?,
           'the leftover is the row the operator came to clean up; it must not sit in the table ' \
           'wearing the same face as a healthy one'
    assert_not standalone.warning?, "a stand-alone machine on its own node is nobody's cleanup"
    assert unknown.warning?, 'an unreadable cluster must not read as a healthy verdict'
  end
end
