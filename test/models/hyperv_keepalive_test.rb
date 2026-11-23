# frozen_string_literal: true

require 'test_helper'

# PLG-34: an optional, per-cluster keepalive. The measured reason (Pass 59/65,
# §66/§67): the FIRST remote read after a 10-35 minute idle gap costs 20-120 s
# per node, and PLG-33b's overlap turns that into one hop at full price, not
# none. A scheduled tick replays exactly one page load's worth of reads on
# fresh clients, so a human's load is always a warm load.
#
# What this suite pins:
#
#   1. the tick RECIPE (Hyperv#keepalive_tick): a cluster tick reads exactly
#      the hops the page pays — probe, node list, endpoint rows, every other
#      node's rows, the role index — each EXACTLY ONCE, and consumes the
#      same request's speculative pipeline (composes with PLG-33b rather
#      than duplicating it). A stand-alone tick is the endpoint branch only:
#      probe + rows, no node list, no roles, no per-node clients;
#   2. selection: only resources with hyperv_keepalive ON are ticked, once
#      per tick_all, from freshly loaded AR instances (a client or a gate
#      memoized in the scheduler must never outlive one tick);
#   3. the tick never reaches a human: one cluster's failure is rescued at
#      the runner, the next cluster is still ticked, and repeats of the SAME
#      failure warn at most once per warn-window (a dead node on a 5-minute
#      tick is otherwise a log firehose);
#   4. the guards: the interval reader clamps garbage to the frozen band,
#      the advisory lock makes the tick single-runner across Foreman's own
#      processes (a holder that cannot lock does nothing), and the scheduler
#      thread is not started in the test environment.
class HypervKeepaliveTest < ActiveSupport::TestCase
  HOST = 'hv-node1'
  CR_URL = "http://#{HOST}:5985/wsman".freeze
  ELENA = '3323c48a-a1bb-4609-b25d-b02013bc701f'
  PLAIN = 'cccc1111-2222-3333-4444-555566667777'
  NODE2_VM = '77771111-2222-3333-4444-555566667777'

  VmDouble = Struct.new(:id, :name, keyword_init: true)
  NodeDouble = Struct.new(:name)

  # Same warn-capture the PLG-33b suite proved on this harness: SilencedLogger
  # sups around Mocha stubs on either side of its delegation, so capture is a
  # singleton redefinition on the delegate plus a thread-local level lift.
  def capture_warns
    warns = []
    outer = Rails.logger
    delegate = outer.respond_to?(:__getobj__) ? outer.__getobj__ : outer
    delegate.singleton_class.send(:alias_method, :__p34_orig_warn__, :warn)
    delegate.singleton_class.send(:define_method, :warn) do |*args, &block|
      warns << (args.first || block&.call).to_s
      __p34_orig_warn__(*args, &block)
    end
    previous = outer.local_level if outer.respond_to?(:local_level)
    outer.local_level = Logger::DEBUG if outer.respond_to?(:local_level=)
    yield warns
    warns
  ensure
    outer.local_level = previous if outer.respond_to?(:local_level=)
    if delegate.singleton_class.method_defined?(:__p34_orig_warn__)
      delegate.singleton_class.send(:alias_method, :warn, :__p34_orig_warn__)
      delegate.singleton_class.send(:remove_method, :__p34_orig_warn__)
    end
  end

  # One fake fog answering every endpoint-side read the page (and therefore
  # the tick) makes, with per-method call counters.
  class TickFog
    attr_reader :probe_calls, :nodes_calls, :rows_calls, :roles_calls

    def initialize(machines:, node_names: %w[HV-NODE1 HV-NODE2], supports: true)
      @machines = machines
      @node_names = node_names
      @supports = supports
      @probe_calls = 0
      @nodes_calls = 0
      @rows_calls = 0
      @roles_calls = 0
      @servers = ServersCollection.new(self)
    end

    def servers(_attrs = {})
      @servers
    end

    def supports_clusters?
      @probe_calls += 1
      @supports
    end

    def cluster_nodes
      @nodes_calls += 1
      @node_names.map { |n| NodeDouble.new(n) }
    end

    def all_rows
      @rows_calls += 1
      @machines
    end

    def cluster_virtual_machine_roles
      @roles_calls += 1
      RolesCollection.new
    end

    class RolesCollection
      def all(*)
        []
      end
    end

    class ServersCollection
      def initialize(fog)
        @fog = fog
      end

      def all(filters = {})
        raise TypeError, 'no implicit conversion of nil into Hash' if filters.nil?

        @fog.all_rows
      end
    end
  end

  class TickCr < ForemanHyperv::Hyperv
    attr_accessor :client_fog, :pipeline_fog, :node_fogs

    def client_for_node(node_name)
      node_fogs.fetch(node_name.to_s.downcase) { raise "no fog staged for node #{node_name}" }
    end
  end

  def endpoint_machines
    [VmDouble.new(id: ELENA, name: 'elena.maughmer.net'),
     VmDouble.new(id: PLAIN, name: 'plain.maughmer.net')]
  end

  def build_tick_cr(supports: true)
    cr = TickCr.new(name: 'lab-cr', url: CR_URL, user: 'u', password: 'p')
    cr.client_fog = TickFog.new(machines: endpoint_machines, supports: supports)
    # PLG-33b seam: the pipeline composes fresh clients; in faked suites they
    # arrive at a SECOND fake instance so consumption stays countable.
    cr.pipeline_fog = TickFog.new(machines: endpoint_machines, supports: supports)
    cr.node_fogs = { 'hv-node2' => TickFog.new(machines: [VmDouble.new(id: NODE2_VM.upcase, name: 'x')]) }
    cr.stubs(:client).returns(cr.client_fog)
    cr.stubs(:fresh_endpoint_client).returns(cr.pipeline_fog)
    cr
  end

  # The pipeline's speculative threads are never joined on a stand-alone
  # discard; settle them before counting so the asserts race nothing.
  def settle(cr)
    pipeline = cr.instance_variable_get(:@listing_pipeline)
    return unless pipeline

    pipeline.take_probe
    pipeline.take_nodes
    pipeline.take_rows
  end

  # DB-backed selections need a user with rights: the harness default cannot
  # even set these attributes (Foreman answers with its permission message,
  # and create! returns an unsaved record). The migrated-but-unseeded test
  # DB has no admin, so the test provides one — transactional, like the rows.
  setup do
    # User.current starts nil in this harness, and creating an admin needs a
    # current user allowed to grant admin flags.
    User.current = User.anonymous_admin
    User.current = User.unscoped.find_by(login: 'admin') ||
                   User.create!(login: 'admin', admin: true, firstname: 'Test',
                                lastname: 'Admin', mail: 'admin@test.local',
                                password: 'keepalive-test-password')
  end

  def teardown
    ForemanHyperv::Keepalive.reset_state
  end

  # ---- 1: the tick recipe ----

  def test_a_cluster_tick_reads_exactly_one_page_load_of_the_hops_the_page_pays
    cr = build_tick_cr

    rows = cr.keepalive_tick

    assert_equal 3, rows, 'the tick answers with what one listing would show'
    assert_equal 1, cr.pipeline_fog.probe_calls, 'the gate consumed the tick-s own probe'
    assert_equal 1, cr.pipeline_fog.nodes_calls, 'the node list, once'
    assert_equal 1, cr.pipeline_fog.rows_calls, 'the endpoint rows, once'
    assert_equal 0, cr.client_fog.nodes_calls + cr.client_fog.rows_calls,
                 'the pipeline already answered them — nothing asked twice'
    assert_equal 1, cr.client_fog.roles_calls, 'the role index, once (the page reads it too)'
    assert_equal 1, cr.node_fogs['hv-node2'].rows_calls, 'each other node, once'
  end

  def test_a_stand_alone_tick_is_the_endpoint_branch_only
    cr = build_tick_cr(supports: false)

    rows = cr.keepalive_tick

    settle(cr)
    assert_equal 2, rows
    assert_equal 1, cr.client_fog.rows_calls, 'the endpoint Get-VM keeps WSMan and PowerShell warm'
    assert_equal 0, cr.client_fog.roles_calls, 'no role index on a host with no cluster'
    assert_equal 0, cr.node_fogs['hv-node2'].rows_calls, 'no per-node clients to dial'
    assert_equal 0, cr.client_fog.nodes_calls
  end

  # Replace Keepalive.tick_one for the duration of the block with a recorder
  # (singleton redefinition — the mechanism proven on this harness). Mocha
  # DOES NOT SUPPORT A BLOCK ON stubs: obj.stubs(:m) { ... } silently ignores
  # the block and returns nil (discovered the hard way here — a tick recorder
  # that "never fired" was actually a stub whose block never ran). Records
  # the instances it saw and answers with impl (default: every tick ok).
  def stub_ticks(seen, impl = nil)
    outer = ForemanHyperv::Keepalive
    outer.singleton_class.send(:alias_method, :__p34_orig_tick__, :tick_one)
    outer.singleton_class.send(:define_method, :tick_one) do |cr|
      seen << cr
      impl ? impl.call(cr) : true
    end
    yield seen
  ensure
    outer.singleton_class.send(:alias_method, :tick_one, :__p34_orig_tick__)
    outer.singleton_class.send(:remove_method, :__p34_orig_tick__)
  end

  # ---- 2: selection, and one tick per enabled resource ----

  def create_cr(name:, keepalive:)
    ForemanHyperv::Hyperv.create!(name: name, url: CR_URL, user: 'u', password: 'p',
                                  hyperv_keepalive: keepalive)
  end

  def test_only_enabled_resources_are_ticked_and_each_exactly_once
    on = create_cr(name: 'ka-on', keepalive: true)
    create_cr(name: 'ka-off', keepalive: false)
    seen = []
    ticked_ids = nil
    stub_ticks(seen) { ticked_ids = ForemanHyperv::Keepalive.tick_all }

    assert_equal [on.id], seen.map(&:id), "ON ticks; OFF never gets dialled (seen=#{seen.map(&:id).inspect})"
    assert_equal [on.id], ticked_ids, 'tick_all reports what it actually ticked'
  end

  def test_each_tick_runs_on_a_freshly_loaded_resource
    on = create_cr(name: 'ka-fresh', keepalive: true)
    seen = []
    stub_ticks(seen) do
      ForemanHyperv::Keepalive.tick_all
      ForemanHyperv::Keepalive.tick_all
    end

    assert_equal 2, seen.size
    refute_same seen.first, seen.second,
                'a tick must not inherit the last tick-s client, gate or pipeline memo'
    assert_equal on.id, seen.first.id
  end

  # ---- 3: the tick never reaches a human ----

  CrDouble = Struct.new(:id, :name) do
    attr_accessor :outcome

    def keepalive_tick
      raise @outcome if @outcome.is_a?(Exception)

      @outcome
    end
  end

  def test_a_failing_tick_is_rescued_at_the_runner_and_returns_false
    cr = CrDouble.new(1, 'ka-boom')
    cr.outcome = Foreman::Exception.new('shell refuses')

    warns = nil
    ok = nil
    warns = capture_warns { ok = ForemanHyperv::Keepalive.tick_one(cr) }

    assert_equal false, ok, 'a tick that cannot answer is reported, never re-raised'
    assert_equal 1, warns.count { |m| m.include?('keepalive') && m.include?('ka-boom') },
                 "the failure names the cluster and says keepalive — got: #{warns.inspect}"
  end

  def test_one_clusters_failure_cannot_hold_the_next_cluster_hostage
    boom = create_cr(name: 'ka-boom', keepalive: true)
    fine = create_cr(name: 'ka-fine', keepalive: true)
    seen = []
    ticked = nil
    stub_ticks(seen, ->(cr) { cr.id != boom.id }) { ticked = ForemanHyperv::Keepalive.tick_all }

    assert_equal [fine.id], ticked, 'the failing cluster drops out; the tick moves on'
    assert_equal [boom.id, fine.id], seen.map(&:id), 'both were attempted, in id order'
  end

  def test_repeats_of_the_same_failure_warn_at_most_once_per_warn_window
    cr = CrDouble.new(11, 'ka-noisy')
    cr.outcome = Foreman::Exception.new('shell refuses')
    ForemanHyperv::Keepalive.warn_window_seconds = 3_600

    warns = capture_warns { 3.times { ForemanHyperv::Keepalive.tick_one(cr) } }

    assert_equal 1, warns.count { |m| m.include?('keepalive') && m.include?('ka-noisy') },
                 "three failed ticks, one warn — got: #{warns.inspect}"

    # Window expired: the next failure is news again.
    ForemanHyperv::Keepalive.warn_window_seconds = 0
    second = capture_warns { ForemanHyperv::Keepalive.tick_one(cr) }
    assert_equal 1, second.count { |m| m.include?('keepalive') && m.include?('ka-noisy') },
                 'silence is throttled, not permanent — a still-dead cluster is heard from again'
  end

  def test_a_cluster_that_recovers_resets_its_warn_throttle
    cr = CrDouble.new(12, 'ka-flap')
    cr.outcome = Foreman::Exception.new('shell refuses')
    ForemanHyperv::Keepalive.warn_window_seconds = 3_600

    capture_warns { ForemanHyperv::Keepalive.tick_one(cr) }
    cr.outcome = 3
    capture_warns { assert_equal true, ForemanHyperv::Keepalive.tick_one(cr) }
    cr.outcome = Foreman::Exception.new('shell refuses')
    warns = capture_warns { ForemanHyperv::Keepalive.tick_one(cr) }

    assert_equal 1, warns.count { |m| m.include?('ka-flap') },
                 'a recovered cluster that fails again warns immediately, not at window end'
  end

  # ---- 4: the guards ----

  def test_the_interval_reader_clamps_garbage_into_the_frozen_band
    # Foreman's settings accessor is Foreman.settings (there is no Settings
    # constant on this line); the reader must survive ANY value the setting
    # holds, because an admin can type anything.
    stubs = { nil: nil, blank: '', text: 'abc', symbol: :thinking,
              zero: 0, negative: -5, fast: 30, huge: 99_999, stringy: '300', good: 300 }
    expected = { nil: 300, blank: 300, text: 300, symbol: 300,
                 zero: 60, negative: 60, fast: 60, huge: 3_600, stringy: 300, good: 300 }
    expected.each do |key, want|
      Foreman.settings.stubs(:[]).with(:hyperv_keepalive_interval_seconds).returns(stubs[key])
      assert_equal want, ForemanHyperv::Keepalive.interval_seconds, "#{key.inspect} is not handled"
    end
  end

  def test_the_tick_is_single_runner_across_foreman_s_own_processes
    connection = mock('connection')
    connection.stubs(:adapter_name).returns('PostgreSQL')
    ActiveRecord::Base.stubs(:connection).returns(connection)
    ran = false

    connection.expects(:select_value).with { |sql| sql.include?('pg_try_advisory_lock') }.returns(false)
    assert_nil ForemanHyperv::Keepalive.with_single_runner { ran = true }
    assert_equal false, ran, 'a scheduler that cannot hold the lock does NOTHING'

    connection.stubs(:select_value).returns(true)
    connection.expects(:select_value).with { |sql| sql.include?('pg_advisory_unlock') }.returns(true)
    assert_equal :done, ForemanHyperv::Keepalive.with_single_runner { ran = true; :done }
    assert ran
  end

  def test_the_lock_is_released_even_when_the_tick_raises
    connection = mock('connection')
    connection.stubs(:adapter_name).returns('PostgreSQL')
    ActiveRecord::Base.stubs(:connection).returns(connection)
    connection.stubs(:select_value).returns(true)
    connection.expects(:select_value).with { |sql| sql.include?('pg_advisory_unlock') }.returns(true)

    assert_raises(Foreman::Exception) do
      ForemanHyperv::Keepalive.with_single_runner { raise Foreman::Exception, 'mid-tick' }
    end
  end

  def test_the_scheduler_thread_does_not_run_inside_the_test_environment
    ForemanHyperv::Keepalive.start!

    assert_nil ForemanHyperv::Keepalive.thread,
               'the suite stays deterministic: the tick loop is a production creature'
  end
end
