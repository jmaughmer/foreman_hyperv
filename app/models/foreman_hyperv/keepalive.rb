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
  # how often (one global setting, clamped), that only one Foreman process
  # ticks (a Postgres advisory lock, so puma workers and any extra boots never
  # double-dial the nodes), and how loudly failures speak (throttled warns —
  # a dead node on a 5-minute tick is otherwise a log firehose).
  #
  # A tick never reaches a human: every failure is rescued here, at most one
  # warn per warn-window per resource, and one dead cluster cannot stop the
  # next one. Each tick runs on a FRESHLY loaded resource instance, so no
  # client, gate or pipeline memo ever outlives the tick that made it.
  module Keepalive
    DEFAULT_INTERVAL = 300
    MIN_INTERVAL = 60
    MAX_INTERVAL = 3_600
    # One warn per this many intervals for the SAME still-failing resource.
    WARN_EVERY_N_INTERVALS = 12
    # Fixed advisory-lock key; any Foreman process holding it ticks, the rest
    # skip the beat. pg_try_advisory_lock is session-scoped, so a crashed
    # holder's lock dies with its connection.
    ADVISORY_LOCK_KEY = 48_175_301

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
      # production it rides the interval (5-min tick, hourly complaints).
      attr_writer :warn_window_seconds

      def warn_window_seconds
        @warn_window_seconds || interval_seconds * WARN_EVERY_N_INTERVALS
      end

      # One beat: every enabled Hyperv resource, freshly loaded, ticked in
      # id order behind the single-runner lock. Returns the ids whose tick
      # completed without raising — a failed resource is still ticked (and
      # warned, throttled), it just is not reported as an answer. Empty
      # list, zero cost beyond one SELECT.
      def tick_all
        ids = ForemanHyperv::Hyperv.where(hyperv_keepalive: true).order(:id).pluck(:id)
        return [] if ids.empty?

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

      # Postgres advisory lock, session-scoped: the scheduler that cannot
      # hold it does NOTHING this beat. Non-Postgres deployments (no such
      # function) run the tick unlocked rather than not at all.
      def with_single_runner
        connection = ActiveRecord::Base.connection
        return yield unless connection.adapter_name =~ /postgres/i

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

      # For tests: forget throttle state and the thread.
      def reset_state
        stop!
        @last_warn = {}
        @warn_window_seconds = nil
      end

      private

      def run_loop
        loop do
          sleep_interval
          begin
            tick_all
          rescue StandardError => e
            Rails.logger.warn "Hyper-V keepalive tick failed: #{e.class}: " \
                              "#{e.message.to_s.lines.first.to_s.strip}"
          end
        end
      end

      # Sleep in one-second slices so a changed interval setting takes hold
      # without a restart.
      def sleep_interval
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + interval_seconds
        loop do
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          break if remaining <= 0

          sleep [remaining, 1.0].min
        end
      end
    end
  end
end
