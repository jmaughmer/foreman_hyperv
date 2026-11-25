# frozen_string_literal: true

module ForemanHyperv
  # PLG-34: the optional, per-resource keepalive tick.
  #
  # WHY (Pass 59/65, §66/§67): the FIRST remote read after a 10-35 minute idle
  # gap costs 20-120 s per node (60-250 s in documented contention windows).
  # PLG-33b turned a page's cold-hop SUM into its slowest single hop — one hop
  # at full price remains. A scheduled tick replays exactly one page load's
  # worth of endpoint reads (the listing pipeline, the per-node Get-VM ladder,
  # the role index) and drops the answers, so the hops a human pays are always
  # warm: WSMan shell allocation, PowerShell startup, the cluster cmdlets.
  #
  # WHERE THE LOGIC LIVES: the recipe is Hyperv#keepalive_tick (model
  # behavior, tested against the same fake fogs as the listing itself). This
  # module is only the scheduler: who to tick (the hyperv_keepalive column),
  # how often (one global setting, clamped), WHO among Foreman's many threads
  # ticks (the PLG-34b election below), that two ticks never overlap (the
  # single-runner try-lock kept underneath the election), and how loudly
  # failures speak (throttled warns — a dead node is otherwise a log firehose).
  #
  # A tick never reaches a human: every failure is rescued here, at most one
  # warn per warn-window per resource, and one dead cluster cannot stop the
  # next one. Each tick runs on a FRESHLY loaded resource instance, so no
  # client, gate or pipeline memo ever outlives the tick that made it.
  #
  # THE ELECTION (PLG-34b, Pass 70/§70; re-scoped by PLG-42, review F10):
  # every process that boots Foreman carries a scheduler thread — the puma
  # master AND each sidekiq process (the preload-forked workers none).
  # PLG-34's per-tick try-lock serialized OVERLAPPING ticks only, so N
  # threads beat at N independent phases per interval — up to N full
  # page-loads of dialing where one was meant. The election fixes the beat
  # COUNT, not just the overlap: the bucket is
  # pg_try_advisory_xact_lock(KEY, (now / interval).floor) — SINCE PLG-42 a
  # TRANSACTION-scoped lock acquired inside the transaction that spans the
  # beat, so COMMIT OR ROLLBACK ALWAYS RELEASES IT. Nothing can strand an
  # owned epoch: no release path exists to lose, no dead-man's lock waits
  # for a connection reaper, a killed worker is simply an epoch the next
  # boundary re-elects. Losing is settled AT THE BOUNDARY: every thread on
  # every node shares the boundary grid (same wall clock, same epoch
  # formula), so losers sleep to the next boundary exactly like winners
  # rather than re-polling every second — the old LOSER_POLL_SECONDS poll
  # existed to notice a session lock's holder moving on; with a lock whose
  # lifetime IS a beat, there is nothing left to notice.
  # The live lock's objid IS the current epoch — pg_locks filtered to
  # classid = ADVISORY_LOCK_KEY, mode ShareExclusiveLock, is the operator's
  # heartbeat readout, advancing by one per interval and gone between
  # beats. Off Postgres there is no election and every thread beats
  # (today's PLG-34 behavior): the election is a dialing economy, never a
  # reason to tick zero.
  #
  # THE CONNECTION DISCIPLINE (PLG-42, review F10): a bare Thread has no
  # connection management, and on the old design the first AR call in the
  # loop pinned one pool connection to the scheduler thread of EVERY booted
  # process for the process's WHOLE LIFE — keepalive off or on, idle or
  # busy — because the epoch election held its session lock on that pinned
  # connection. Now the thread holds NOTHING while sleeping, and beats
  # through beat_once, which leases a connection for exactly one beat
  # (connection_pool.with_connection) and runs it inside
  # Rails.application.executor.wrap — the same managed context a background
  # job gets. The thread still starts UNCONDITIONALLY on purpose: the enable
  # column and the interval are dynamic settings, and a thread that skipped
  # booting because nothing was tick-listed could never be woken when an
  # admin enables one — the idle cost is now what it always should have
  # been: one pluck SELECT per interval and zero held connections.
  module Keepalive
    # PLG-34b B1: the default fell 300 -> 60. The measured reason (Pass 70,
    # §70): in a real lab the warmth decays below the human-readable band
    # well inside 300 s (a load 4.5 minutes after a warm beat still cost
    # 30.7 s), so the interval must be shorter than the decay, not equal to
    # it. B1 means NEW installs see 60; a stored setting is never rewritten
    # (an untouched default and a deliberate choice are indistinguishable
    # from the row alone, and the plan's rule is never to overwrite operator
    # choices silently).
    DEFAULT_INTERVAL = 60
    MIN_INTERVAL = 60
    MAX_INTERVAL = 3_600
    # One warn per this many intervals for the SAME still-failing resource.
    WARN_EVERY_N_INTERVALS = 12
    # Fixed advisory-lock key. Since PLG-34b it is the CLASSID half of the
    # election's two-key pair (objid = the epoch bucket) and, unchanged from
    # PLG-34, the whole key of the tick-serialization lock below. Since
    # PLG-42 the election half is TRANSACTION-scoped (released by the beat's
    # commit, un-strandable); the serialization half stays session-scoped,
    # explicitly released inside the same beat's connection lease.
    ADVISORY_LOCK_KEY = 48_175_301
    # Per-thread bookkeeping. PLG-42 retired the owned-epoch thread-local:
    # the xact lock's lifetime is the beat's own transaction, so there is
    # no held-bucket bookkeeping left to keep. What remains is the loss
    # flag the loop's telemetry reads.
    LOST_THREAD_KEY = :foreman_hyperv_keepalive_lost

    class << self
      # Tests drive the tick directly; the thread is a production creature.
      #
      # PLG-42: NO pre-start database gate, deliberately, and the unconditional
      # start survives the redesign that made it cheap. Both knobs (the enable
      # column and the interval) are dynamic settings a human changes at
      # runtime, so a thread that skipped starting because nothing was
      # tick-listed at boot could never be woken by an admin enabling one
      # later. What the idle thread costs is now bounded by construction:
      # beat_once leases and returns, so between beats it holds no connection
      # at all, and the per-interval cost of an all-disabled install is one
      # pluck SELECT (see tick_all's selection-first ordering).
      def start!
        return @thread if @thread
        return nil if Rails.env.test?
        return nil if defined?(Foreman) && Foreman.respond_to?(:in_rake?) && Foreman.in_rake?

        @thread = Thread.new { run_loop }
        @thread.name = 'foreman-hyperv-keepalive'
        @thread
      end

      def stop!
        @thread&.kill
        @thread = nil
      end

      attr_reader :thread

      # The global tick interval, clamped into the frozen band: an admin can
      # type anything, and both a runaway timer and a typo that never ticks
      # cost the operator a cold surprise they cannot see coming.
      def interval_seconds
        raw = begin
          Foreman.settings[:hyperv_keepalive_interval_seconds]
        rescue StandardError
          nil
        end
        value = raw.is_a?(Integer) ? raw : begin
          Integer(raw.to_s, 10)
        rescue ArgumentError, TypeError
          nil
        end
        (value || DEFAULT_INTERVAL).clamp(MIN_INTERVAL, MAX_INTERVAL)
      end

      # Overridable so the throttle is testable without a clock; in
      # production it rides the interval (a 60 s tick complains at most
      # every twelve minutes about the same dead cluster).
      attr_writer :warn_window_seconds

      def warn_window_seconds
        @warn_window_seconds || interval_seconds * WARN_EVERY_N_INTERVALS
      end

      # One beat: every enabled Hyperv resource, freshly loaded, ticked in
      # id order — but only if this thread WON the epoch election, and never
      # while another tick is still dialing (the two locks, and what each
      # buys, are documented on their methods). Returns the ids whose tick
      # completed without raising — a failed resource is still ticked (and
      # warned, throttled), it just is not reported as an answer. Empty
      # list, zero cost beyond one SELECT.
      #
      # The beat runs AS THE ANONYMOUS ADMIN, and it is load-bearing: the
      # scheduler thread has no logged-in user, and Foreman's per-user
      # scoping answers any model query made with User.current == nil with
      # a (1=0) — the selection and the per-id find_by would both return
      # nothing, and the tick would silently dial ZERO clusters forever
      # (caught live in production, not by the suite, because every test
      # runs as a user). A tick is "the listing an admin would see", which
      # is exactly the context this block gives it.
      #
      # PLG-42: the election and the dialing run inside ONE transaction
      # (why the xact lock needs it: elect_this_beat; what dialing inside a
      # transaction costs: the module header). Selection stays OUTSIDE it:
      # with nothing enabled the beat opens no transaction and takes no
      # lock, which is the idle cost PLG-42 set out to make honest.
      def tick_all
        Thread.current[LOST_THREAD_KEY] = nil
        User.as_anonymous_admin do
          ids = ForemanHyperv::Hyperv.where(hyperv_keepalive: true).order(:id).pluck(:id)
          next [] if ids.empty?

          # One transaction spans the election and the dialing. The plain
          # call carries the semantics deliberately: on every Rails this
          # plugin runs on, a transaction with one already open JOINS it
          # (no savepoint, no lie about nesting — a rake task driving a
          # manual beat lends its transaction to the election, and the
          # xact lock releases at that CALLER's commit, still bounded by
          # the call), and with none open it starts one for the beat. (No
          # join: kwarg — Rails 7.0 does not know it; the default IS the
          # joinable behavior 7.1 later made explicit.)
          ActiveRecord::Base.transaction do
            won = elect_this_beat
            Thread.current[LOST_THREAD_KEY] = won.nil?
            next [] if won.nil?

            ticked = []
            with_single_runner do
              ids.each do |id|
                cr = ComputeResource.find_by(id: id)
                next if cr.nil? # deleted between the pluck and the dial

                ticked << id if tick_one(cr)
              end
            end
            ticked
          end
        end
      end

      # The beat with a MANAGED context — the pair every sane background-job
      # runtime wraps work in, and the fix for the F10 leak: the executor
      # gives the beat Rails' execution hooks (reload status, shard state)
      # instead of inheriting whatever the boot thread left, and the pool
      # lease borrows exactly one connection for exactly this beat and
      # RETURNS IT before the loop sleeps. A thread that beats for five
      # seconds a minute holds a connection for five seconds a minute.
      # Returns what tick_all reports (the ticked ids); an empty selection
      # never ran an election and costs one SELECT.
      def beat_once
        Rails.application.executor.wrap do
          ActiveRecord::Base.connection_pool.with_connection { tick_all }
        end
      end

      # One resource, one tick, loudly once at most. The rescue is the
      # promise that a tick never reaches a human.
      def tick_one(cr)
        cr.keepalive_tick
        last_warn.delete(cr.id) # recovered: the next failure is news again
        true
      rescue StandardError => e
        warn_throttled(cr, e)
        false
      end

      def warn_throttled(cr, error)
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        previous = last_warn[cr.id]
        return if previous && (now - previous) < warn_window_seconds

        last_warn[cr.id] = now
        Rails.logger.warn "Hyper-V keepalive for #{cr.name} could not be read: " \
                          "#{error.class}: #{error.message.to_s.lines.first.to_s.strip} " \
                          "(the next warning comes no sooner than #{warn_window_seconds}s from now)"
      end

      # PLG-42: who owns THIS interval. The bucket key pair
      # (ADVISORY_LOCK_KEY, epoch) is a TRANSACTION-scoped advisory lock
      # acquired inside the beat's own transaction: TRUE when this beat may
      # dial, NIL when another process's beat owns the epoch, TRUE without
      # elections when Postgres advisory locks are unavailable (non-Postgres:
      # every thread beats). There is no held-bucket bookkeeping and no
      # release path — COMMIT/ROLLBACK IS the release, so a crash, a kill, or
      # a beat dying mid-dial strands nothing, which is the property F10
      # asked to make structural.
      #
      # The result is compared as ::text and read with the ActiveModel
      # boolean type because the answer's WIRE FORM differs by path — the
      # ::text cast answers the strings 'true'/'false' (measured on the CI
      # Postgres), a raw boolean arrives typecast, and the text protocol
      # spells them 't'/'f'. Every one of those is a truthy STRING in Ruby;
      # a truthiness test would hand every epoch to every process.
      #
      # An interval-setting change mid-epoch needs no special case: the epoch
      # is recomputed per beat, and a beat in flight releases its (old-width)
      # bucket at commit like any other.
      def elect_this_beat
        connection = election_connection
        return true unless postgres?(connection)

        epoch = beat_epoch
        won = connection.select_value(
          "SELECT (pg_try_advisory_xact_lock(#{ADVISORY_LOCK_KEY}, #{epoch}))::text AS won"
        )
        # The answer is TEXT — pg answers the ::text cast with the strings
        # 'true'/'false' (a raw boolean column arrives typecast, and the
        # text protocol has yet another shape), and EVERY non-empty string
        # is truthy in Ruby: 'false' as a truthiness test hands every epoch
        # to every process. The ActiveModel boolean type is the reader that
        # knows the false spellings ('f', 'false', false, 0...) from the
        # true ones on any adapter. TRUE / NIL, never false: the caller
        # tells "lost" from every other answer with .nil?.
        ActiveModel::Type::Boolean.new.cast(won) ? true : nil
      rescue ActiveRecord::StatementInvalid
        # No such function on this adapter (an exotic DB the adapter check
        # missed): degrade to everyone-beats, PLG-37c's self-test names the
        # regime.
        true
      end

      # PLG-42 retired release_election: the transaction-scoped bucket has
      # nothing left to release early — the beat's commit is the release.
      # (The session-scoped SINGLE-RUNNER lock below keeps its explicit
      # release; it must outlive statements inside the beat.)

      # The seam through which the scheduler talks to the database layer.
      # Deliberately NOT ActiveRecord::Base.connection itself: a test that
      # stubs THAT would starve the real AR queries (User lookups included)
      # that share it. This is the only database handle the election uses.
      def election_connection
        ActiveRecord::Base.connection
      end

      def postgres?(connection)
        connection.adapter_name =~ /postgres/i
      end

      # The current bucket: UTC epoch seconds floored to the interval. Two
      # processes agree on the number while NTP keeps them within the
      # interval of each other; one that is badly behind merely lets the
      # other win (the draft's risk row: skew can add a beat at a boundary,
      # never open a gap — whoever holds the epoch is dialing).
      def beat_epoch
        (now_seconds / interval_seconds).floor
      end

      # The clock seam the epoch is computed from — stubbable so boundary
      # behavior is testable without sleeping.
      def now_seconds
        Time.now.to_i
      end

      # Seconds from now until the start of the next epoch, always in
      # (0, interval]: landing exactly ON a boundary belongs to the epoch
      # beginning then, so a beat that finished exactly on a boundary still
      # sleeps a whole interval rather than double-beating the epoch it
      # just finished. Public seam: this is the pacing the loop runs on,
      # and the suite pins it the way PLG-34b pinned sleep_seconds_after.
      def seconds_until_next_boundary(interval)
        interval - (Time.now.to_f % interval)
      end

      # Postgres advisory lock, session-scoped: the scheduler that cannot
      # hold it does NOTHING this beat. Non-Postgres deployments (no such
      # function) run the tick unlocked rather than not at all. Since
      # PLG-34b this is the SECOND layer: the election decides whose beat it
      # is, this decides that two ticks never dial at once. A winner that
      # finds it busy skips — and skipping is right, because the nodes are
      # being warmed by the in-flight tick at that very moment.
      #
      # PLG-42 KEEPS this session-scoped lock under the transaction-scoped
      # election, and it is not redundant: the election elects who BEGINS an
      # epoch; this refuses anyone who BEGAN LATE. A winner whose beat
      # overruns its epoch releases the xact bucket at commit, so a
      # straggler that wakes inside the same wall-clock epoch (NTP step, a
      # beat longer than the interval) can win the NEXT epoch's try while
      # the overrunning beat still dials — this lock is what keeps the
      # second beat from dialing CONCURRENTLY with the first. Session scope
      # is required by that job (it must outlive statements), and the
      # explicit release below happens inside the SAME beat's connection
      # lease (beat_once), before the connection goes back to the pool —
      # the pool reaper remains the self-heal for a release that never
      # runs, exactly as before.
      def with_single_runner
        connection = ActiveRecord::Base.connection
        return yield unless postgres?(connection)

        locked = connection.select_value("SELECT pg_try_advisory_lock(#{ADVISORY_LOCK_KEY})")
        return nil unless locked

        begin
          yield
        ensure
          connection.select_value("SELECT pg_advisory_unlock(#{ADVISORY_LOCK_KEY})")
        end
      end

      def last_warn
        @last_warn ||= {}
      end

      # For tests: forget throttle state and the thread. (PLG-42 left
      # nothing epoch-shaped to forget: the xact bucket dies with its
      # transaction.)
      def reset_state
        stop!
        Thread.current[LOST_THREAD_KEY] = nil
        @last_warn = {}
        @warn_window_seconds = nil
      end

      private

      # PLG-42: sleep to the epoch BOUNDARY, then beat — winners and losers
      # alike. Everyone on every node shares the boundary grid (same wall
      # clock, same epoch formula), so all threads wake together at the
      # start of an epoch, the xact election picks exactly one, and nobody
      # busy-polls in between. The first wake lands on the next boundary
      # like every other: booting mid-epoch and dialing at once with the
      # epoch's other would-be beaters is the DESIGN (the election sorts it;
      # the single-runner lock underneath still refuses a concurrent dial),
      # not a restart storm. A beat that finishes after its boundary simply
      # joins the next one; a beat can skip no more epochs than it overruns.
      # The boundary math uses the same wall clock the epoch formula uses —
      # the only clock under which "wake at the next boundary" means the
      # same thing in every process; an NTP step past a boundary makes the
      # next wake early or late by the step, and the election absorbs
      # whichever.
      def run_loop
        loop do
          sleep_interval(seconds_until_next_boundary(interval_seconds))
          begin
            beat_once
          rescue StandardError => e
            Rails.logger.warn "Hyper-V keepalive tick failed: #{e.class}: " \
                              "#{e.message.to_s.lines.first.to_s.strip}"
            # A raise costs one beat, never the loop: the next boundary
            # arrives regardless, and a dead node must not silence the
            # clusters that are alive.
          end
        end
      end

      # Sleep in one-second slices so a changed interval setting takes hold
      # without a restart (a thread asleep toward an old-grid boundary when
      # the operator changes the interval still recomputes from the new
      # width at its next wake).
      def sleep_interval(seconds)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
        loop do
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          break if remaining <= 0

          sleep [remaining, 1.0].min
        end
      end
    end
  end
end
