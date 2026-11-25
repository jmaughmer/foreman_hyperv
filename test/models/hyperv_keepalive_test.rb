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
#   5. the per-beat ELECTION (PLG-34b, re-scoped by PLG-42 / review F10):
#      one beat per interval epoch across all of Foreman's processes (Pass 70
#      proved every booted process carries a thread and each beats at its own
#      phase). PLG-42: the winner acquires pg_try_advisory_xact_lock(KEY,
#      epoch) — a TRANSACTION-scoped bucket compared ::text (the driver's 'f'
#      is truthy in Ruby) — INSIDE the transaction that spans the beat, so
#      the commit is the release: no held-bucket bookkeeping, no unlock,
#      nothing to strand. Losing skips exactly that epoch, and losers sleep
#      to the next epoch boundary like winners — the 1-s loser poll is
#      retired with the session-lock semantics that needed it. beat_once runs
#      the beat through executor.wrap + a per-beat connection lease (the F10
#      leak: every booted process used to pin one pool connection forever).
#      A non-Postgres deployment never lets the election silence beats. B1:
#      the default interval is 60 s, the clamp band 60–3600 is unchanged.
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

  # ---- 5: PLG-34b/PLG-42, the per-beat election ----

  # A scripted stand-in for the AR connection the election talks to. Blocks
  # on mocha stubs are IGNORED by this harness's mocha 2.x (the PLG-34 tick
  # recorder learned that the hard way), so per-phase behavior is mutable
  # attributes on a real object, not stub blocks. PLG-42: the election
  # speaks a TRANSACTION-scoped two-key try
  # (pg_try_advisory_xact_lock(KEY, epoch)) whose boolean arrives ::text —
  # the fake answers with the STRINGS 't'/'f' exactly as the pg driver
  # does, because 'f' is truthy in Ruby and a truthiness bug must fail
  # here, not in production. There is no unlock half anymore: the beat's
  # commit is the release, and this fake RECORDS any two-key unlock so the
  # suite can pin that nothing tries one. (The tick-serialization lock is
  # still one-key and session-scoped; in these election tests the real
  # SQLite connection answers its adapter check, so it runs unlocked and
  # its SQL never reaches this fake.)
  class ElectionConnection
    attr_reader :locks, :unlocks, :select_calls, :elect_sql
    attr_accessor :adapter, :try_xact, :unlock

    def initialize(adapter: 'PostgreSQL')
      @adapter = adapter
      @locks = []
      @unlocks = []
      @select_calls = 0
      @elect_sql = []
      @try_xact = 't'
      @unlock = true
    end

    def adapter_name
      @adapter
    end

    def select_value(sql)
      @select_calls += 1
      case sql
      when /pg_try_advisory_xact_lock\((\d+),\s*(\d+)\)/
        @elect_sql << sql
        @locks << [Regexp.last_match(1).to_i, Regexp.last_match(2).to_i]
        @try_xact
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

  # Recorder pair for the two managed-context seams beat_once must run
  # through (PLG-42). Singleton redefinition with delegation — mocha 2.x
  # ignores stub blocks on this harness (see stub_ticks).
  def with_context_recorders
    recorder = { transactions: [], leases: 0, wraps: 0 }

    ar = ActiveRecord::Base.singleton_class
    ar.send(:alias_method, :__p42_orig_transaction__, :transaction)
    ar.send(:define_method, :transaction) do |**kwargs, &block|
      recorder[:transactions] << kwargs
      __p42_orig_transaction__(**kwargs, &block)
    end

    pool = ActiveRecord::Base.connection_pool
    pool.singleton_class.send(:alias_method, :__p42_orig_with_connection__, :with_connection)
    pool.singleton_class.send(:define_method, :with_connection) do |&block|
      recorder[:leases] += 1
      __p42_orig_with_connection__(&block)
    end

    executor = Rails.application.executor
    executor.singleton_class.send(:alias_method, :__p42_orig_wrap__, :wrap)
    executor.singleton_class.send(:define_method, :wrap) do |**kwargs, &block|
      recorder[:wraps] += 1
      __p42_orig_wrap__(**kwargs, &block)
    end

    yield recorder
  ensure
    ar.send(:alias_method, :transaction, :__p42_orig_transaction__)
    ar.send(:remove_method, :__p42_orig_transaction__)
    pool.singleton_class.send(:alias_method, :with_connection, :__p42_orig_with_connection__)
    pool.singleton_class.send(:remove_method, :__p42_orig_with_connection__)
    executor.singleton_class.send(:alias_method, :wrap, :__p42_orig_wrap__)
    executor.singleton_class.send(:remove_method, :__p42_orig_wrap__)
  end

  def test_a_thread_that_does_not_own_the_current_epoch_beats_nothing
    create_cr(name: 'ka-elect-loser', keepalive: true)
    connection = election_connection
    # PLG-42: the loser signal is the driver's STRING 'f' — which is TRUTHY
    # in Ruby. A truthiness test on the xact answer hands every epoch to
    # every process; only the ::text comparison loses.
    connection.try_xact = 'f'
    seen = []
    ticked = nil

    stub_ticks(seen) { ticked = ForemanHyperv::Keepalive.tick_all }

    assert_equal [], ticked, 'a losing tick_all reports nothing ticked'
    assert_empty seen, "a losing thread must not dial the nodes AT ALL ('f' won't)"
    assert_equal true, Thread.current[ForemanHyperv::Keepalive::LOST_THREAD_KEY],
                 'the loss must be visible to the thread (telemetry reads it)'
  end

  def test_the_election_asks_for_a_transaction_scoped_bucket_on_the_current_epoch
    create_cr(name: 'ka-elect-winner', keepalive: true)
    connection = election_connection
    seen = []
    key = ForemanHyperv::Keepalive::ADVISORY_LOCK_KEY
    ForemanHyperv::Keepalive.stubs(:interval_seconds).returns(60)
    ForemanHyperv::Keepalive.stubs(:now_seconds).returns(ELECT_BASE)
    epoch = ELECT_BASE / 60

    stub_ticks(seen) do
      ForemanHyperv::Keepalive.tick_all
      ForemanHyperv::Keepalive.tick_all # same epoch: ask again, this beat is its own lock
    end
    assert_equal 2, seen.size, 'a beat that wins its epoch ticks'
    assert_equal [[key, epoch], [key, epoch]], connection.locks,
                 'one xact try per beat, both on the CURRENT epoch bucket'
    assert connection.elect_sql.all? { |sql| sql.include?('pg_try_advisory_xact_lock') },
                 "PLG-42: the election is TRANSACTION-scoped, got: #{connection.elect_sql.inspect}"
    assert connection.elect_sql.all? { |sql| sql.include?('::text') },
                 "the boolean comes back ::text so 'f' cannot beat as truthy"
  end

  def test_the_election_has_no_release_path_the_commit_is_the_release
    create_cr(name: 'ka-elect-nounlock', keepalive: true)
    connection = election_connection
    seen = []
    ForemanHyperv::Keepalive.stubs(:interval_seconds).returns(60)
    ForemanHyperv::Keepalive.stubs(:now_seconds).returns(ELECT_BASE)

    stub_ticks(seen) { ForemanHyperv::Keepalive.tick_all }

    # The epoch turns over — the ONLY moment the old session-lock design
    # reached for pg_advisory_unlock. Under the xact election nothing
    # does: the previous beat's COMMIT already released its bucket.
    ForemanHyperv::Keepalive.stubs(:now_seconds).returns(ELECT_BASE + 60)
    stub_ticks(seen) { ForemanHyperv::Keepalive.tick_all }

    assert_empty connection.unlocks,
                 'no pg_advisory_unlock for the ELECTION bucket may ever run: ' \
                 'the beat commits and Postgres releases — nothing to strand, nothing to release'
  end

  def test_the_beat_elects_inside_an_open_transaction
    create_cr(name: 'ka-elect-xact', keepalive: true)
    seen = []
    ForemanHyperv::Keepalive.stubs(:interval_seconds).returns(60)

    # The fake answers the xact try with 't' ONLY while a transaction the
    # recorder opened is actually executing — an election outside the
    # beat's transaction reads 'f' (which is what Postgres would do to a
    # zero-lifetime xact lock at the next statement) and the beat loses.
    cell = { in_xact: false, join_kwargs: [] }
    fake = ElectionConnection.new
    fake.define_singleton_method(:select_value) do |sql|
      @select_calls += 1
      if sql.include?('pg_try_advisory_xact_lock')
        @elect_sql << sql
        cell[:in_xact] ? 't' : 'f'
      else
        true
      end
    end
    ForemanHyperv::Keepalive.stubs(:election_connection).returns(fake)

    ar = ActiveRecord::Base.singleton_class
    ar.send(:alias_method, :__p42_orig_transaction__, :transaction)
    ar.send(:define_method, :transaction) do |**kwargs, &block|
      cell[:join_kwargs] << kwargs
      cell[:in_xact] = true
      begin
        __p42_orig_transaction__(**kwargs, &block)
      ensure
        cell[:in_xact] = false
      end
    end

    begin
      stub_ticks(seen) { ForemanHyperv::Keepalive.tick_all }
    ensure
      ar.send(:alias_method, :transaction, :__p42_orig_transaction__)
      ar.send(:remove_method, :__p42_orig_transaction__)
    end

    assert_equal 1, seen.size,
                 'PLG-42: the xact election must run INSIDE the beat transaction — ' \
                 'tried outside, the lock dies before the dialing starts'
    assert_equal 1, cell[:join_kwargs].count { |kw| kw[:join] == :joinable },
                 'one beat-wide transaction, joinable so a caller-held transaction is not lied to'
  end

  def test_beat_once_runs_the_beat_in_a_managed_connection_context
    cr = create_cr(name: 'ka-beat-context', keepalive: true)
    seen = []

    with_context_recorders do |recorder|
      stub_ticks(seen) { assert_equal [cr.id], ForemanHyperv::Keepalive.beat_once }
    end

    # PLG-42, the F10 fix pinned as structure: the beat leases its pool
    # connection for EXACTLY the beat (with_connection returns it when the
    # block ends — so the loop's sleep phase holds nothing) and runs inside
    # the executor (reload/shard state managed, not inherited from boot).
    assert_equal 1, recorder[:leases],
                 'the beat goes through connection_pool.with_connection'
    assert_equal 1, recorder[:wraps],
                 'the beat goes through Rails.application.executor.wrap'
    assert_equal 1, seen.size, 'and it still runs the real beat'
  end

  def test_a_beat_that_lost_or_won_never_leaves_state_for_the_next_beat
    cr = create_cr(name: 'ka-elect-fresh', keepalive: true)
    connection = election_connection
    seen = []
    ForemanHyperv::Keepalive.stubs(:interval_seconds).returns(60)
    ForemanHyperv::Keepalive.stubs(:now_seconds).returns(ELECT_BASE)

    stub_ticks(seen) { assert_equal [cr.id], ForemanHyperv::Keepalive.beat_once }
    assert_equal 1, seen.size

    # Lost epoch: nothing dials. PLG-34b needed unlock-false bookkeeping to
    # notice a lost session lock; with the bucket scoped to the beat's own
    # transaction there is NOTHING to notice — the next beat re-asks cold.
    connection.try_xact = 'f'
    stub_ticks(seen) { assert_equal [], ForemanHyperv::Keepalive.beat_once }
    assert_equal 1, seen.size, 'the losing beat dials nothing'

    connection.try_xact = 't'
    ForemanHyperv::Keepalive.stubs(:now_seconds).returns(ELECT_BASE + 60)
    stub_ticks(seen) { assert_equal [cr.id], ForemanHyperv::Keepalive.beat_once }
    assert_equal 2, seen.size,
                 'winning again needs no reclaim: the heartbeat bucket just advances by one'
    assert_equal [[ForemanHyperv::Keepalive::ADVISORY_LOCK_KEY, ELECT_BASE / 60],
                  [ForemanHyperv::Keepalive::ADVISORY_LOCK_KEY, ELECT_BASE / 60 + 1]],
                 connection.locks, 'the operator readout advances one bucket per interval'
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

  def test_the_loop_paces_to_epoch_boundaries_and_the_loser_poll_is_retired
    # PLG-42: winners AND losers sleep to the next epoch boundary — the
    # 1-second loser poll existed to notice a session lock's holder moving
    # on, and with a lock whose lifetime IS a beat there is nothing left to
    # notice. The whole outcome/poll apparatus is gone, not defaulted off.
    refute ForemanHyperv::Keepalive.respond_to?(:sleep_seconds_after),
           'the outcome-based pacing is retired; the loop paces to boundaries'
    refute ForemanHyperv::Keepalive.const_defined?(:LOSER_POLL_SECONDS, false),
           'the loser poll is gone'
    refute ForemanHyperv::Keepalive.const_defined?(:EPOCH_THREAD_KEY, false),
           'no held-epoch bookkeeping survives an xact-scoped election'
    refute ForemanHyperv::Keepalive.respond_to?(:release_election),
           'the commit is the release; an early-release path would only lie'

    # The boundary math: always in (0, interval], and now + sleep lands
    # exactly on the next boundary — for any phase, including ON one.
    [0.0, 0.5, 7.5, 59.0, 59.999].each do |offset|
      Time.stubs(:now).returns(Time.at(ELECT_BASE + offset))
      sleep_for = ForemanHyperv::Keepalive.seconds_until_next_boundary(60)
      assert_operator sleep_for, :>, 0, "sleep at +#{offset}s must never be zero (double-beat)"
      assert_operator sleep_for, :<=, 60, "sleep at +#{offset}s can never exceed the interval"
      assert_in_delta ELECT_BASE + 60, Time.at(ELECT_BASE + offset).to_f + sleep_for, 1e-6,
                      "waking at +#{offset}s must land on the NEXT boundary"
    end
  end

  def test_the_b1_defaults_are_sixty_seconds_and_the_band_is_untouched
    assert_equal 60, ForemanHyperv::Keepalive::DEFAULT_INTERVAL,
                 'PLG-34b B1: new installs beat every 60 s (warmth decays under 300 s — Pass 70)'
    assert_equal 60, ForemanHyperv::Keepalive::MIN_INTERVAL, 'the clamp floor stays 60'
    assert_equal 3_600, ForemanHyperv::Keepalive::MAX_INTERVAL, 'the clamp ceiling stays 3600'
  end
end
