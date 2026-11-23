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
#      thread is not started in the test environment;
#   5. the PLG-34b per-beat ELECTION: one beat per interval epoch across all
#      of Foreman's processes (Pass 70 proved every booted process carries a
#      thread and each beats at its own phase). The winner acquires
#      pg_try_advisory_lock(KEY, epoch) — a session lock bucketed by
#      (now / interval) — and HOLDS it until the epoch moves; losers beat
#      nothing and wake once a second to try the next bucket; losing the lock
#      (connection reaped) re-elects with no beat skipped; a non-Postgres
#      deployment never lets the election silence beats. B1: the default
#      interval is 60 s, the clamp band 60–3600 is unchanged.
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
    # PLG-33c: the page's role index now rides the pipeline's fourth hop —
    # the roles read starts the moment this same probe answered CLUSTER — so
    # it is counted on the pipeline client and read on NO client twice. The
    # recipe is still exactly one page load's worth of hops, one read each.
    assert_equal 1, cr.pipeline_fog.roles_calls, 'the role index, once (the lane answers it)'
    assert_equal 0, cr.client_fog.roles_calls,
                 'the page never re-asks the endpoint with its own client'
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

  def test_a_beat_from_a_thread_with_no_current_user_still_sees_the_enabled_resources
    on = create_cr(name: 'ka-nobody', keepalive: true)
    seen = []
    ticked = nil
    User.current = nil # exactly what the scheduler thread is: no logged-in user
    stub_ticks(seen) { ticked = ForemanHyperv::Keepalive.tick_all }

    assert_equal [on.id], ticked,
                 "User.current == nil must not silently tick NOTHING (ticked=#{ticked.inspect})"
    assert_equal [on.id], seen.map(&:id)
  ensure
    User.current = User.unscoped.find_by(login: 'admin')
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
    # PLG-34b B1: the DEFAULT fell 300 -> 60, so every garbage row now lands
    # on 60 (which is also the band floor — double-pinned). Real values in
    # the band still pass through untouched.
    expected = { nil: 60, blank: 60, text: 60, symbol: 60,
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

  # ---- 5: PLG-34b, the per-beat election ----

  # A scripted stand-in for the AR connection the election talks to. Blocks
  # on mocha stubs are IGNORED by this harness's mocha 2.x (the PLG-34 tick
  # recorder learned that the hard way), so per-phase behavior is mutable
  # attributes on a real object, not stub blocks. The election speaks
  # TWO-key advisory SQL (resource key + epoch bucket); the tick-
  # serialization lock stays one-key and is answered true here because
  # these tests are about the election.
  class ElectionConnection
    attr_reader :locks, :unlocks, :select_calls
    attr_accessor :adapter, :try_two, :unlock

    def initialize(adapter: 'PostgreSQL')
      @adapter = adapter
      @locks = []
      @unlocks = []
      @select_calls = 0
      @try_two = true
      @unlock = true
    end

    def adapter_name
      @adapter
    end

    def select_value(sql)
      @select_calls += 1
      case sql
      when /pg_try_advisory_lock\((\d+),\s*(\d+)\)/
        @locks << [Regexp.last_match(1).to_i, Regexp.last_match(2).to_i]
        @try_two
      when /pg_advisory_unlock\((\d+),\s*(\d+)\)/
        @unlocks << [Regexp.last_match(1).to_i, Regexp.last_match(2).to_i]
        @unlock
      else
        true
      end
    end
  end

  def election_connection(adapter: 'PostgreSQL')
    # A dedicated seam (not ActiveRecord::Base.connection): the User lookup
    # inside tick_all's as_anonymous_admin resolves through the Base
    # connection too, so stubbing that would starve the real selection of
    # its adapter. election_connection is the ONLY thing the scheduler asks
    # the database layer for.
    conn = ElectionConnection.new(adapter: adapter)
    ForemanHyperv::Keepalive.stubs(:election_connection).returns(conn)
    conn
  end

  ELECT_BASE = 1_800_000_000 # deterministic wall clock; the epoch is base/interval

  def test_a_thread_that_does_not_own_the_current_epoch_beats_nothing
    create_cr(name: 'ka-elect-loser', keepalive: true)
    connection = election_connection
    connection.try_two = false # another process already won this epoch
    seen = []
    ticked = nil
    outcome = nil

    stub_ticks(seen) do
      ticked = ForemanHyperv::Keepalive.tick_all
      outcome = ForemanHyperv::Keepalive.beat_once
    end

    assert_equal [], ticked, 'a losing tick_all reports nothing ticked'
    assert_empty seen, 'a losing thread must not dial the nodes AT ALL'
    assert_equal :lost, outcome, 'the loop must SEE the loss (it polls instead of sleeping)'
  end

  def test_the_winner_locks_the_epoch_once_holds_it_and_moves_only_when_the_epoch_moves
    create_cr(name: 'ka-elect-winner', keepalive: true)
    connection = election_connection
    seen = []
    key = ForemanHyperv::Keepalive::ADVISORY_LOCK_KEY
    ForemanHyperv::Keepalive.stubs(:interval_seconds).returns(60)
    ForemanHyperv::Keepalive.stubs(:now_seconds).returns(ELECT_BASE)
    epoch = ELECT_BASE / 60

    stub_ticks(seen) do
      ForemanHyperv::Keepalive.tick_all
      ForemanHyperv::Keepalive.tick_all # same epoch: already mine, tick again
    end
    assert_equal 2, seen.size, 'the epoch winner ticks in its own epoch'
    assert_equal [[key, epoch]], connection.locks, 'ONE epoch-keyed acquire, no re-entrant drift'
    assert_empty connection.unlocks, 'the winner HOLDS the bucket while the epoch stands (the heartbeat row)'

    # The epoch turns over: the old bucket is released and the new one won,
    # so the pg_locks objid advances by exactly one — the operator readout.
    ForemanHyperv::Keepalive.stubs(:now_seconds).returns(ELECT_BASE + 60)
    stub_ticks(seen) { ForemanHyperv::Keepalive.tick_all }
    assert_equal 3, seen.size
    assert_equal [[key, epoch], [key, epoch + 1]], connection.locks, 'the winner moves to the next bucket'
    assert_equal [[key, epoch]], connection.unlocks, 'the expired bucket is released, not hoarded'
  end

  def test_a_winner_that_lost_its_connection_lock_beats_the_next_epoch_anyway
    create_cr(name: 'ka-elect-reclaim', keepalive: true)
    connection = election_connection
    seen = []
    ForemanHyperv::Keepalive.stubs(:interval_seconds).returns(60)
    ForemanHyperv::Keepalive.stubs(:now_seconds).returns(ELECT_BASE)

    stub_ticks(seen) { ForemanHyperv::Keepalive.tick_all }
    assert_equal 1, seen.size, 'wins the epoch and ticks'

    # The pool reaper claims the connection mid-sleep and the session lock
    # dies with it: the next wake sees unlock answer FALSE (not mine
    # anymore), which is only information — the new bucket is tried like
    # any other and won. A lost lock costs zero beats.
    ForemanHyperv::Keepalive.stubs(:now_seconds).returns(ELECT_BASE + 60)
    connection.unlock = false
    stub_ticks(seen) { assert_equal :won, ForemanHyperv::Keepalive.beat_once }
    assert_equal 2, seen.size, 're-election after lock loss ticks, never skips'
  end

  def test_losing_one_epoch_skips_exactly_that_beat_and_the_next_is_winnable
    create_cr(name: 'ka-elect-skip', keepalive: true)
    connection = election_connection
    seen = []
    ForemanHyperv::Keepalive.stubs(:interval_seconds).returns(60)
    ForemanHyperv::Keepalive.stubs(:now_seconds).returns(ELECT_BASE)

    stub_ticks(seen) { ForemanHyperv::Keepalive.tick_all }
    assert_equal 1, seen.size

    # Another process already won the NEXT bucket: this thread reports lost
    # and dials nothing (its 1-s poll wakes it for the bucket after).
    ForemanHyperv::Keepalive.stubs(:now_seconds).returns(ELECT_BASE + 60)
    connection.try_two = false
    stub_ticks(seen) { assert_equal :lost, ForemanHyperv::Keepalive.beat_once }
    assert_equal 1, seen.size, 'the epoch owner dials; the loser does not'

    # The owner releases when ITS epoch moves: this thread wins the bucket
    # after and beats. Never two skips in a row.
    ForemanHyperv::Keepalive.stubs(:now_seconds).returns(ELECT_BASE + 120)
    connection.try_two = true
    stub_ticks(seen) { assert_equal :won, ForemanHyperv::Keepalive.beat_once }
    assert_equal 2, seen.size, 'one lost epoch, then beats resume'
  end

  def test_a_non_postgres_deployment_never_lets_the_election_silence_the_beats
    cr = create_cr(name: 'ka-elect-nopg', keepalive: true)
    connection = election_connection(adapter: 'SQLite')
    seen = []
    ticked = nil
    stub_ticks(seen) { ticked = ForemanHyperv::Keepalive.tick_all }

    assert_equal [cr.id], ticked, 'election unavailable means EVERY thread beats, never zero'
    assert_equal 1, seen.size
    assert_equal 0, connection.select_calls, 'no advisory SQL of any kind runs off Postgres'
  end

  def test_the_loser_polls_once_a_second_and_the_winner_sleeps_the_interval
    assert_equal 1, ForemanHyperv::Keepalive::LOSER_POLL_SECONDS
    ForemanHyperv::Keepalive.stubs(:interval_seconds).returns(120)

    assert_equal 1, ForemanHyperv::Keepalive.sleep_seconds_after(:lost)
    assert_equal 120, ForemanHyperv::Keepalive.sleep_seconds_after(:won)
    assert_equal 120, ForemanHyperv::Keepalive.sleep_seconds_after(:unknown),
                 'anything but an observed loss waits the full interval'
  end

  def test_the_b1_defaults_are_sixty_seconds_and_the_band_is_untouched
    assert_equal 60, ForemanHyperv::Keepalive::DEFAULT_INTERVAL,
                 'PLG-34b B1: new installs beat every 60 s (warmth decays under 300 s — Pass 70)'
    assert_equal 60, ForemanHyperv::Keepalive::MIN_INTERVAL, 'the clamp floor stays 60'
    assert_equal 3_600, ForemanHyperv::Keepalive::MAX_INTERVAL, 'the clamp ceiling stays 3600'
  end
end
