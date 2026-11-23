# frozen_string_literal: true

module ForemanHyperv
  # The listing's endpoint-side reads, started together (PLG-33b).
  #
  # The measured reason (stage decomposition behind §66's ladder, and the
  # production.log rows that opened PLG-33b): one page load runs FIVE remote
  # hops SEQUENTIALLY — the cluster probe (0.67 s warm, 22–44 s cold), the
  # cluster node list (2.6 s), the endpoint's own rows (0.7 s), and then the
  # already-parallel per-node reads (PLG-33). A cold WinRM read costs tens of
  # seconds on EVERY hop, so a first load after an idle gap pays the SUM of the
  # cold hops (measured 172.9 s = 44 s probe + 124 s listing), which is exactly
  # what the workstation waits through. This class starts the three
  # endpoint-side hops at the top of the request so the page waits for its
  # SLOWEST single hop instead of for their sum.
  #
  # Each hop runs on its OWN freshly composed client (Hyperv#fresh_endpoint_client)
  # on its own thread: the WinRM layer under a fog client is per-connection
  # scratch, so one client answers exactly one thread at a time (the rule
  # PLG-33's fan-out holds by construction, and R22 before it). The three
  # shells join the fan-out's bound from the other side — the probe and node
  # list are consumed before the node reads start, so at most one pipeline
  # thread (the endpoint rows) is still in flight during the fan-out.
  #
  # Every read is CONSUMED, never discarded, by the page that started it:
  # the tri-state gate takes the probe, ClusterNodeServers takes the node list
  # and the endpoint rows. A future is taken at most once — a second listing
  # on the same resource re-reads live, exactly as every pre-PLG-33b listing
  # did (the §58 ghost-machine ruling forbids answering a later listing from
  # an earlier read). A speculative read whose answer nobody wants — the gate
  # says stand-alone — is silently discarded: it was not an error the operator
  # needs to see on a resource that has no cluster.
  #
  # PLG-33c adds the fourth hop — the cluster role listing — started the
  # INSTANT the probe lands YES, not by the render that consumes it. The gate
  # is then already answered (the probe said cluster), so the Registration
  # column and the HA rows take this lane instead of paying their own sync
  # confirmation probe + roles read at render time. It is chained to the
  # probe rather than fired at construction because a stand-alone endpoint
  # must never be taxed a roles read on a cluster it does not have.
  #
  # Fail-soft by construction: if a client cannot even be composed the
  # pipeline does not exist and the whole page runs today's sequential path
  # verbatim. Every hop is bounded by the PLG-16 WinRM waits its client was
  # composed with, so a speculative read can never outlive the waits the
  # sequential page already accepted.
  class ListingPipeline
    # One hop's answer or error, delivered to whichever consumer takes it.
    # The error is re-raised on the CONSUMER's thread, not swallowed here:
    # every consumption site already rescues, warns and degrades exactly as
    # the sequential path does, and that is the text the operator reads.
    class Future
      def initialize
        @queue = Queue.new
      end

      def complete(value)
        @queue << [:ok, value]
      end

      def fail_with(error)
        @queue << [:error, error]
      end

      def value
        kind, payload = @queue.pop
        raise payload if kind == :error

        payload
      end
    end

    # Compose the clients and start the reads. Returns nil when the pipeline
    # cannot exist at all (a client will not compose) — the caller then runs
    # today's sequential path, and the page's reads all happen on the
    # resource's own client as they do today. The block is the role-listing
    # reader (PLG-33c): given the fourth fresh client, it answers the roles
    # this page's role index will be built from (Hyperv#pipelined_role_read).
    def self.start(compute_resource, &role_reader)
      clients = Array.new(4) { compute_resource.send(:fresh_endpoint_client) }
      new(clients, &role_reader)
    rescue StandardError => e
      Rails.logger.warn "Hyper-V listing pipeline for #{compute_resource.name} could not start: " \
                        "#{e.class}: #{e.message.to_s.lines.first.to_s.strip}"
      nil
    end

    def initialize(endpoint_clients, &role_reader)
      probe_client, nodes_client, rows_client, roles_client = endpoint_clients
      @probe = take_slot(Future.new)
      @nodes = take_slot(Future.new)
      @rows = take_slot(Future.new)
      @role_reader = role_reader
      @role_client = roles_client
      @role_mutex = Mutex.new
      @role_slot = nil
      # The block never raises: whatever the hop does to the thread's own
      # stack (Exception escapes rescue), the hop's future is answered, so no
      # consumer can block on a thread that has already ended. StandardError
      # is handed to the consumer (its rescue knows the operator-facing
      # words); anything else arrives as an error no rescue claims, matching
      # the sequential path letting it escape.
      start_hop(@probe) do
        answer = probe_client.respond_to?(:supports_clusters?) && probe_client.supports_clusters?
        # PLG-33c: the gate said CLUSTER on this thread — start the roles
        # read NOW so it overlaps the node fan-out instead of following it
        # at render. Chained here rather than fired at construction because
        # a stand-alone answer must not dial a roles read on a cluster the
        # endpoint does not have; starting BEFORE the probe's future answers
        # means any consumer that takes the probe and then takes the lane
        # always finds the slot in place.
        start_role_lane if answer && @role_reader
        answer
      end
      start_hop(@nodes) { nodes_client.cluster_nodes }
      start_hop(@rows) { rows_client.servers.all({}) }
    end

    # The gate's answer (Hyperv#cluster_endpoint?). Taken at most once; nil
    # when already taken, so the caller reads the probe itself.
    def take_probe
      take(@probe)
    end

    # The cluster's node list raw, exactly what client.cluster_nodes answers.
    def take_nodes
      take(@nodes)
    end

    # The endpoint's rows raw, exactly what client.servers.all({}) answers.
    def take_rows
      take(@rows)
    end

    # PLG-33c: the cluster role listing. Started by the probe thread the
    # moment it answers CLUSTER (see initialize), so it overlaps the node
    # fan-out; the page's role index takes the answer instead of paying its
    # own confirmation probe plus roles read at render. Idempotent: a gate
    # re-evaluated in the same request cannot double-dial. Taking before the
    # lane exists (a stand-alone gate, a raising probe, a pipeline built
    # without a reader) answers nil — the consumer then runs the sequential
    # read verbatim. A lane that FAILED raises on this thread, like every
    # other hop.
    def start_role_lane(&read)
      started = false
      @role_mutex.synchronize do
        unless @role_slot
          @role_slot = take_slot(Future.new)
          started = true
        end
      end
      runner = read || @role_reader
      start_hop(@role_slot) { runner.call(@role_client) } if started && runner
      nil
    end

    # The lane's roles raw, or nil when no lane was started (or was already
    # taken — claim-once, exactly like every other hop).
    def take_role_lane
      slot = @role_mutex.synchronize { @role_slot }
      return nil unless slot

      take(slot)
    end

    private

    def take_slot(future)
      { future: future, pending: true, mutex: Mutex.new }
    end

    def start_hop(slot)
      Thread.new do
        begin
          slot[:future].complete(yield)
        rescue StandardError => e
          slot[:future].fail_with(e)
        rescue Exception => e # rubocop:disable Lint/RescueException
          slot[:future].fail_with(e)
        end
      end
    end

    # Claim-once: the first consumer waits for the hop (and receives its
    # raise); later consumers get nil and re-read live. The claim is atomic
    # but the wait happens outside the mutex — a cold hop must not block the
    # other consumers behind a mutex join.
    def take(slot)
      claimed = slot[:mutex].synchronize do
        if slot[:pending]
          slot[:pending] = false
          true
        end
      end
      return nil unless claimed

      slot[:future].value
    end
  end
end
