# frozen_string_literal: true

require 'test_helper'

# PLG-31: what the cluster will DO about a machine becomes visible in the
# VM detail page — failover priority, automatic failback, and the failback
# window — read from the role object the page ALREADY pays to fetch, at no
# additional cluster cost.
#
# Why this is display-only: the three knobs are group properties this fog
# fork already reads on every role listing (grounded against the live
# cluster 2026-11-23: leah-navia answers PRIORITY=2000, AutoFailbackType=1,
# window 4294967295..4294967295), and their WRITE is a separate, unmade
# contract. A knob an operator can read but must change in Failover Cluster
# Manager is honest; a half-editable knob is a trap.
#
# What this suite pins:
#   1. the measured shape of the lab cluster renders the labeled rows —
#      priority 2000 → "Medium (2000)", failback 1 → "On (1)", the measured
#      4294967295 sentinel → "None" (the documented map rides WITH its raw
#      value, because the raw value is what the cluster actually said);
#   2. values the map does not know show raw only (4500 is a priority, not
#      a guess), except failback, where fog's own rule is nonzero-is-on;
#   3. a cluster that answered nothing answers Unknown — never a word;
#   4. a fog without the failback contract says NOTHING about failback
#      (the PLG-30 silence rule), while still showing priority, which
#      predates that contract;
#   5. a machine the cluster does not own, a cluster that could not answer,
#      and a machine with no id get NO section at all — the Registration
#      column already owns those answers;
#   6. the rows cost the page EXACTLY ONE role read, shared with the
#      Registration column's join.
class HypervHaSettingsTest < ActiveSupport::TestCase
  HOST = 'hv-node1'
  CR_URL = "http://#{HOST}:5985/wsman".freeze
  LEAH = 'e8f37f42-11c4-4a5e-9b3a-0f2d8c1a6b77'
  OTHER = '3323c48a-a1bb-4609-b25d-b02013bc701f'
  SENTINEL = 4_294_967_295

  # A role as the installed fog's ClusterVirtualMachineRole answers it: the
  # attributes hash carrying the three HA knobs verbatim, plus the
  # auto_failback_type method the plugin gates the failback rows on.
  HaRoleDouble = Struct.new(:name, :virtual_machine_id, :owner_node, :attributes, keyword_init: true) do
    def auto_failback_type
      attributes[:auto_failback_type]
    end
  end

  # A role from a fog whose model predates the failback contract: the
  # methods themselves are absent, which is not the same as nil.
  LegacyHaRoleDouble = Struct.new(:name, :virtual_machine_id, :owner_node, :attributes, keyword_init: true)

  class RolesDouble
    attr_reader :calls

    def initialize(roles)
      @roles = roles
      @calls = 0
    end

    def all(_filters = nil)
      @calls += 1
      @roles
    end
  end

  # The cluster-answering fog. The contract fog additionally answers the
  # failback WRITE method, which is what cluster_failback_supported? keys
  # on alongside fog's CAPABILITIES constant.
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

  class ContractFogDouble < FogDouble
    def set_cluster_virtual_machine_role_auto_failback(**_args)
      true
    end
  end

  # A cluster-capable fog on a stand-alone endpoint.
  class NonClusterFogDouble < FogDouble
    def supports_clusters?
      false
    end
  end

  # A roles read that raises: "could not answer", the plugin's nil index.
  class RaisingRolesDouble
    def all(_filters = nil)
      raise Timeout::Error
    end
  end

  VmDouble = Struct.new(:id, :name, :path, keyword_init: true)

  setup do
    # The stand-alone confirmation probe really sleeps between attempts
    # (PLG-35); this suite pins the calls, never the clock.
    ForemanHyperv::Hyperv.any_instance.stubs(:role_index_flap_pause)
  end

  def leah
    VmDouble.new(id: LEAH, name: 'leah-navia.maughmer.net', path: 'http://hyperv/scim/v2/Machines/leah')
  end

  def ha_role(priority:, auto_failback_type:, window_start:, window_end:, id: LEAH)
    HaRoleDouble.new(name: 'leah-navia.maughmer.net', virtual_machine_id: id, owner_node: 'HV-NODE1',
                     attributes: { name: 'leah-navia.maughmer.net', owner_node: 'HV-NODE1',
                                   priority: priority, auto_failback_type: auto_failback_type,
                                   failback_window_start: window_start, failback_window_end: window_end })
  end

  def build_cr(fog)
    cr = ForemanHyperv::Hyperv.new(name: 'lab-cr', url: CR_URL, user: 'u', password: 'p')
    cr.stubs(:client).returns(fog)
    cr
  end

  def test_the_measured_cluster_shape_renders_the_three_labeled_rows
    # The exact values the live cluster answers for leah-navia (rails-runner
    # row, evidence §74): priority 2000, AutoFailbackType 1, no window.
    role = ha_role(priority: 2_000, auto_failback_type: 1, window_start: SENTINEL, window_end: SENTINEL)
    cr = build_cr(ContractFogDouble.new(RolesDouble.new([role])))

    ha = cr.cluster_ha_settings(leah)

    assert_predicate ha, :found?, 'the cluster owns this machine, so the page may speak of its HA settings'
    assert_equal 'Medium (2000)', ha.priority_label,
                 'the documented word AND the raw number the cluster reported — the operator reads both'
    assert_equal 'On (1)', ha.auto_failback_label
    assert_equal 'None', ha.failback_window_label,
                 'the measured 4294967295 sentinel means no window, not minute 4294967295'
  end

  def test_the_rest_of_the_documented_map_renders_with_its_raw_alongside
    role = ha_role(priority: 3_000, auto_failback_type: 0, window_start: 120, window_end: 180)
    cr = build_cr(ContractFogDouble.new(RolesDouble.new([role])))

    ha = cr.cluster_ha_settings(leah)

    assert_equal 'High (3000)', ha.priority_label
    assert_equal 'Off (0)', ha.auto_failback_label
    assert_equal '120–180 (raw cluster values)', ha.failback_window_label,
                 'a real window renders raw: this fork has measured the sentinel, not the unit'
  end

  def test_low_and_none_priorities_are_documented_words_not_mystery_numbers
    low = build_cr(ContractFogDouble.new(RolesDouble.new([ha_role(priority: 1_000, auto_failback_type: 2, window_start: SENTINEL, window_end: SENTINEL)])))
    none = build_cr(ContractFogDouble.new(RolesDouble.new([ha_role(priority: 0, auto_failback_type: 1, window_start: SENTINEL, window_end: SENTINEL)])))

    assert_equal 'Low (1000)', low.cluster_ha_settings(leah).priority_label
    assert_equal 'None (0)', none.cluster_ha_settings(leah).priority_label
    assert_equal 'On, in failback window (2)', low.cluster_ha_settings(leah).auto_failback_label
  end

  def test_values_the_map_does_not_know_show_their_raw_never_a_guess
    role = ha_role(priority: 4_500, auto_failback_type: 7, window_start: SENTINEL, window_end: SENTINEL)
    cr = build_cr(ContractFogDouble.new(RolesDouble.new([role])))

    ha = cr.cluster_ha_settings(leah)

    assert_equal '4500', ha.priority_label, 'an unmapped priority is a number, not a mapped word'
    assert_equal 'On (7)', ha.auto_failback_label, 'fog\'s own rule for the failback type is nonzero-is-on'
  end

  def test_a_cluster_that_answered_nothing_answers_unknown_not_a_word
    role = ha_role(priority: nil, auto_failback_type: nil, window_start: nil, window_end: nil)
    cr = build_cr(ContractFogDouble.new(RolesDouble.new([role])))

    ha = cr.cluster_ha_settings(leah)

    assert_predicate ha, :found?
    assert_equal 'Unknown', ha.priority_label
    assert_equal 'Unknown', ha.auto_failback_label
    assert_equal 'Unknown', ha.failback_window_label,
                 'missing attributes are not the sentinel: an unread window is not "no window"'
  end

  def test_a_fog_without_the_failback_contract_stays_silent_about_failback
    # PLG-30\'s rule transplanted: an unanswerable question prints nothing,
    # because "off" would be a claim the read never made. Priority survives:
    # it predates the failback contract and the old model carries it.
    role = LegacyHaRoleDouble.new(name: 'leah-navia.maughmer.net', virtual_machine_id: LEAH, owner_node: 'HV-NODE1',
                                  attributes: { priority: 2_000 })
    cr = build_cr(FogDouble.new(RolesDouble.new([role])))

    ha = cr.cluster_ha_settings(leah)

    assert_predicate ha, :found?
    assert_equal 'Medium (2000)', ha.priority_label
    assert_nil ha.auto_failback_label, 'no contract, no word — silence, never "Off"'
    assert_nil ha.failback_window_label
  end

  def test_a_machine_the_cluster_does_not_own_gets_no_ha_section
    role = ha_role(id: OTHER, priority: 2_000, auto_failback_type: 1, window_start: SENTINEL, window_end: SENTINEL)
    cr = build_cr(ContractFogDouble.new(RolesDouble.new([role])))

    ha = cr.cluster_ha_settings(leah)

    assert_not_predicate ha, :found?, 'a role for another machine says nothing about this one'
    assert_nil ha.priority_label
  end

  def test_a_cluster_that_could_not_answer_gets_no_ha_section
    cr = build_cr(FogDouble.new(RaisingRolesDouble.new))

    ha = cr.cluster_ha_settings(leah)

    assert_not_predicate ha, :found?,
                         'the unknown verdict belongs to the Registration column; the HA section says nothing'
    assert_nil ha.priority_label
  end

  def test_a_stand_alone_endpoint_gets_no_ha_section
    cr = build_cr(NonClusterFogDouble.new(RolesDouble.new([])))

    assert_not_predicate cr.cluster_ha_settings(leah), :found?,
                         'no cluster, no cluster knobs — the column already says Stand-alone'
  end

  def test_a_machine_without_an_id_gets_no_ha_section
    cr = build_cr(ContractFogDouble.new(RolesDouble.new([])))

    assert_not_predicate cr.cluster_ha_settings(VmDouble.new(id: nil, name: 'ghost')), :found?
  end

  def test_the_ha_rows_share_the_registration_join_for_exactly_one_role_read
    role = ha_role(priority: 2_000, auto_failback_type: 1, window_start: SENTINEL, window_end: SENTINEL)
    roles = RolesDouble.new([role])
    cr = build_cr(ContractFogDouble.new(roles))

    registration = cr.vm_registration(leah)
    ha = cr.cluster_ha_settings(leah)

    assert_equal :clustered, registration.state
    assert_predicate ha, :found?
    assert_equal 1, roles.calls,
                 'one page render reads the cluster role listing exactly once, whichever columns consume it'
  end
end
