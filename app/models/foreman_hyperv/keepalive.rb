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
  # THE ELECTION (PLG-34b, Pass 70/§70): every process that boots Foreman
  # carries a scheduler thread — the puma master AND each sidekiq process
  # (the preload-forked workers none). PLG-34's per-tick try-lock serialized
  # OVERLAPPING ticks only, so N threads beat at N independent phases per
  # interval — up to N full page-loads of dialing where one was meant. The
  # election fixes the beat COUNT, not just the overlap: the bucket is
  # pg_try_advisory_lock(KEY, (now / interval).floor), a SESSION-scoped lock
  # the winner HOLDS across its interval. One thread wins each epoch and
  # ticks once in it; losers wake every LOSER_POLL_SECONDS to try the next
  # bucket, so a beat is never late by more than a second past the boundary
  # the winner couldn't keep. Losing the lock costs nothing to repair: a
  # session lock dies with its connection (pool reaper, restart, crash), and
  # the next wake of any thread simply wins the bucket no one else holds.
  # The live lock's objid IS the current epoch — pg_locks filtered to
  # classid = ADVISORY_LOCK_KEY is the operator's heartbeat readout,
  # advancing by one per interval. Off Postgres there is no election and
  # every thread beats (today's PLG-34 behavior): the election is a dialing
  # economy, never a reason to tick zero.
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
    # A losing thread re-tries the next bucket every second; buckets turn
    # over only at epoch boundaries, so the poll never races the winner's
    # tick, it just cannot miss the boundary by more than a second.
    LOSER_POLL_SECONDS = 1
    # One warn per this many intervals for the SAME still-failing resource.
    WARN_EVERY_N_INTERVALS = 12
    # Fixed advisory-lock key. Since PLG-34b it is the CLASSID half of the
    # election's two-key pair (objid = the epoch bucket) and, unchanged from
    # PLG-34, the whole key of the tick-serialization lock below. Both are
    # session-scoped, so a crashed holder's locks die with its connections.
    ADVISORY_LOCK_KEY = 48_175_301
    # Per-thread bookkeeping. The epoch a thread won lives in a thread-local
    # because the session lock it names lives on that thread's checked-out
    # connection — exactly the same lifetime, so the two can never disagree
    # across threads.
    EPOCH_THREAD_KEY = :foreman_hyperv_keepalive_epoch
    LOST_THREAD_KEY = :foreman_hyperv_keepalive_lost

    class << self
      # Tests drive the tick directly; the thread is a production creature.
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
      def tick_all
        Thread.current[LOST_THREAD_KEY] = nil
        User.as_anonymous_admin do
          ids = ForemanHyperv::Hyperv.where(hyperv_keepalive: true).order(:id).pluck(:id)
          next [] if ids.empty?

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

      # The beat as the LOOP needs it: tick_all plus a win/loss outcome, so
      # a winner sleeps the interval and a loser polls for the next bucket.
      # An empty selection never ran an election and counts as won — there
      # was nothing to dial, not a lock to lose.
      def beat_once
        tick_all
        Thread.current[LOST_THREAD_KEY] == true ? :lost : :won
      end

      # How long the loop waits after an outcome. Everything except an
      # observed loss (a raise, an empty selection, a win) waits the full
      # interval: a beat loop must never spin.
      def sleep_seconds_after(outcome)
        outcome == :lost ? LOSER_POLL_SECONDS : interval_seconds
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

      # PLG-34b: who owns THIS interval. The bucket key pair
      # (ADVISORY_LOCK_KEY, epoch) is a session-scoped advisory lock the
      # winner holds until the epoch moves — holding, not re-acquiring: one
      # pg_try_advisory_lock per epoch per session keeps Postgres's re-
      #entrant lock counter at one, so the single pg_advisory_unlock at the
      # boundary really ends the ownership. Returns the epoch won, true when
      # elections are unavailable (non-Postgres: every thread beats), or nil
      # when another thread's connection holds the bucket.
      #
      # An interval-setting change mid-epoch shifts the formula, the winner
      # notices at its next wake (held bucket mismatches the new epoch),
      # releases and re-elects — one benign extra or skipped beat at the
      # boundary, never a silent stop.
      def elect_this_beat
        connection = election_connection
        return true unless postgres?(connection)

        epoch = beat_epoch
        held = Thread.current[EPOCH_THREAD_KEY]
        return held if held == epoch

        if held
          # Our bucket expired (or the interval width moved). The unlock
          # returning false is information only: it means the lock was
          # already gone — the reaper reclaimed the connection and the
          # session lock died with it — which is exactly the self-heal the
          # design runs on. Either way the flag drops and we re-elect.
          connection.select_value("SELECT pg_advisory_unlock(#{ADVISORY_LOCK_KEY}, #{held})")
          Thread.current[EPOCH_THREAD_KEY] = nil
        end

        if connection.select_value("SELECT pg_try_advisory_lock(#{ADVISORY_LOCK_KEY}, #{epoch})")
          Thread.current[EPOCH_THREAD_KEY] = epoch
          epoch
        end
      end

      # Give up an owned epoch early (teardown / shutdown niceness). A lock
      # that cannot be released has nowhere to be released FROM — the
      # connection is already gone, which means the lock is gone too.
      def release_election
        epoch = Thread.current[EPOCH_THREAD_KEY]
        return if epoch.nil?

        Thread.current[EPOCH_THREAD_KEY] = nil
        connection = election_connection
        connection.select_value("SELECT pg_advisory_unlock(#{ADVISORY_LOCK_KEY}, #{epoch})") if postgres?(connection)
      rescue StandardError
        nil
      end

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

      # Postgres advisory lock, session-scoped: the scheduler that cannot
      # hold it does NOTHING this beat. Non-Postgres deployments (no such
      # function) run the tick unlocked rather than not at all. Since
      # PLG-34b this is the SECOND layer: the election decides whose beat it
      # is, this decides that two ticks never dial at once. A winner that
      # finds it busy skips — and skipping is right, because the nodes are
      # being warmed by the in-flight tick at that very moment.
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

      # For tests: forget throttle state, the owned epoch, and the thread.
      def reset_state
        stop!
        release_election
        Thread.current[LOST_THREAD_KEY] = nil
        @last_warn = {}
        @warn_window_seconds = nil
      end

      private

      def run_loop
        # The first wake waits a full interval, exactly as PLG-34 booted:
        # a restart must not add a dial on top of whatever is in flight.
        outcome = :won
        loop do
          sleep_interval(sleep_seconds_after(outcome))
          outcome = begin
            beat_once
          rescue StandardError => e
            Rails.logger.warn "Hyper-V keepalive tick failed: #{e.class}: " \
                              "#{e.message.to_s.lines.first.to_s.strip}"
            # A raise is not a loss: the loop keeps interval pacing, never
            # drops into the loser's 1-second poll.
            :won
          end
        end
      end

      # Sleep in one-second slices so a changed interval setting takes hold
      # without a restart (a winner asleep in a 300 s interval when the
      # operator sets 60 still re-elects within the old sleep, then beats to
      # the new width from the next election up).
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
