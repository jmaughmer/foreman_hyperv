# frozen_string_literal: true

module ForemanHyperv
  # The instance list of a clustered compute resource, read across the cluster.
  #
  # Get-VM answers for the machines registered on the node it ran on and
  # nothing else (measured, evidence §58/§59: a machine owned by another node
  # never appeared on the page — the PLG-28 acceptance row was invisible to the
  # list that created it). Actions already solve this per machine —
  # find_vm_by_uuid asks the cluster who owns the machine and reads that node —
  # but the LISTING never got the same treatment, so a page could never
  # distinguish "this machine was deleted" from "another node owns it". This is
  # that same ladder, pointed at the whole inventory: one read of the cluster's
  # own node list (the list names the node the endpoint itself runs on, so the
  # endpoint read is kept and only the other nodes are asked), then one
  # registration read per node, joined by machine id.
  #
  # The reads are live, per call, exactly like the fog collection this
  # replaces: this page has already had one ghost (a released machine listed
  # forever because nothing cached, so nothing could expire — §58), and a list
  # that cached across calls would resurrect it behind a different door.
  #
  # A node that will not answer costs its own rows and nothing else: nodes
  # join, drain and stop answering with no event Foreman is told about, and a
  # page that blanked on one dead node would tell the operator the cluster is
  # empty. The ENDPOINT's own refusal is different — that is the read today's
  # page already makes, and its failure is the failure the controller already
  # reports; answering the other nodes' rows instead would print a page that
  # looks complete and is not.
  class ClusterNodeServers
    # The reads run concurrently, but WinRM caps shells per user and a large
    # cluster must not stampede it; the bound is also what the test suite
    # pins, so it is part of the contract, not a tuning detail.
    MAX_CONCURRENT_NODE_READS = 8

    # PLG-33b: +pipeline+ carries the endpoint-side reads the request already
    # started (the node list, the endpoint's rows) and hands them to the
    # listing that was always going to make them. Direct instantiation — every
    # existing caller and test — passes no pipeline and reads exactly as
    # PLG-33 left it.
    def initialize(compute_resource, pipeline: nil)
      @cr = compute_resource
      @pipeline = pipeline
    end

    # The union, endpoint node first: a machine the endpoint answers for keeps
    # the endpoint's row (the read the page has always shown), and a machine
    # that answers twice — the same GUID reported by a node with different
    # case, as the cluster reports ids upper-case — is one row. A machine
    # whose id cannot be read is kept once, never joined on.
    # Defaults match the fog collection's own ({}): a no-argument call — the
    # shape that worked before this class existed — must keep working, and
    # fog's all splats its filters, so nil must never be forwarded.
    def all(filters = {})
      names = node_names
      return endpoint_vms(filters) if names.nil?

      seen = {}
      rows = []
      yield_sources(names, filters) do |vms|
        vms.each do |vm|
          id = vm.id.to_s.downcase
          key = id.presence || :"unnamed-#{rows.size}"
          next if seen[key]

          seen[key] = true
          rows << vm
        end
      end
      rows
    end

    # The page links each row through vms.get; a listing that shows a machine
    # whose get answers NotFound would 404 the row the union just surfaced.
    # Same join, same order, so get agrees with all by construction.
    def get(identifier, filters = {})
      wanted = identifier.to_s.downcase
      all(filters).find { |vm| vm.id.to_s.casecmp?(wanted) }
    end

    private

    # The endpoint's answer, unsaftened — see the class doc. PLG-33b: the
    # page's plain listing ({}, the shape the request started) consumes the
    # speculative endpoint read; a filtered listing re-reads with its filters
    # through the resource's client — a speculative read made without them can
    # never answer with them, and a second live read costs one warm round trip
    # on the rare path that asks for one. A speculative read already taken (a
    # second listing on the same request) likewise re-reads live.
    def endpoint_vms(filters)
      raw = filters.empty? ? @pipeline&.take_rows : nil
      raw = @cr.send(:client).servers.all(filters) if raw.nil?
      Array(raw).flatten.compact
    end

    # The cluster's own node list, asked once per listing. Answered nil when
    # the fog cannot be asked at all: the degradation is then exactly the
    # pre-PLG-29b answer (the endpoint's rows), not a raised page. PLG-33b:
    # the request's speculative read answers it when it is still unclaimed —
    # the filters never apply to the node list, and a consumed failure
    # re-raises HERE, into the same rescue, so the operator sees the same
    # "could not be read" line and the page degrades the same way.
    def node_names
      @node_names ||= begin
        raw = @pipeline&.take_nodes
        raw = @cr.send(:client).cluster_nodes if raw.nil?
        Array(raw).map { |node| node.name.to_s.strip }.reject(&:empty?).presence
      rescue StandardError => e
        Rails.logger.warn "Hyper-V cluster node list for #{@cr.name} could not be read: " \
                          "#{e.class}: #{e.message.to_s.lines.first.to_s.strip}"
        nil
      end
    end

    # Yields each registration read: the endpoint's own rows first, then every
    # cluster node the endpoint does not already speak for. The endpoint's own
    # node appears in the cluster's node list (measured); endpoint_serves_node?
    # is what recognizes it — the URL host and its first label always, plus
    # the endpoint's self-reported names once fog (FOG-27) carries them —
    # and the endpoint read above already covers it, so asking the ladder
    # too would spend a second WinRM round trip on the same machine.
    #
    # PLG-33: the reads are independent and each touches exactly one fog
    # client, so they run concurrently — the sequential ladder measured ~10 s
    # of the ~13.5 s an idle three-node page costs. The per-node clients are
    # still RESOLVED on this thread (composition is fail-soft and the
    # resource's client memo is not thread-safe); the threads only perform
    # the reads. Answers are yielded here in the classic order — endpoint
    # first, then the other nodes in the order the cluster names them — so
    # the join's contract never depends on thread timing. A node's failure is
    # fail-soft exactly as before; the endpoint's own failure is re-raised
    # raw on this thread, because answering with the other nodes' rows would
    # print a page that looks complete and is not.
    def yield_sources(names, filters)
      sources = sources_for(names, filters)
      answers = read_concurrently(sources)
      raise answers.first[:error] if answers.first[:error]

      answers.each { |answer| yield answer[:vms] }
    end

    # The sources in yielded order: the endpoint's own read first, then one
    # read per other node, each bound to the client the ladder resolved for
    # that node on THIS thread. A node whose client cannot be composed costs
    # its rows and warns, exactly as a node whose read fails does.
    def sources_for(names, filters)
      sources = [{ node: nil, read: -> { endpoint_vms(filters) } }]
      names.each do |node|
        next if @cr.send(:endpoint_serves_node?, node)

        begin
          node_client = @cr.send(:client_for_node, node)
        rescue StandardError => e
          log_node_failure(node, e)
          next
        end
        sources << { node: node, read: -> { Array(node_client.servers.all(filters)).flatten.compact } }
      end
      sources
    end

    # Runs the reads on a bounded pool (WinRM caps shells per user) and
    # returns the answers in source order. Each thread touches exactly one
    # fog client, so the one-connection-per-client rule holds by
    # construction; the endpoint's refusal is stashed and re-raised on the
    # caller's thread. An exception the inner rescue does not cover escapes
    # through join, raw.
    def read_concurrently(sources)
      answers = Array.new(sources.size) { { vms: [] } }
      queue = Queue.new
      sources.each_with_index { |source, index| queue << [index, source] }
      workers = [sources.size, MAX_CONCURRENT_NODE_READS].min.times.map do
        Thread.new do
          until (item = pop_drain(queue)).nil?
            index, source = item
            answers[index] =
              begin
                { vms: source[:read].call }
              rescue StandardError => e
                if index.zero?
                  { error: e }
                else
                  log_node_failure(source[:node], e)
                  { vms: [] }
                end
              end
          end
        end
      end
      workers.each(&:join)
      answers
    end

    # Non-blocking pop: ThreadError means drained for good, because every
    # source is queued before the first worker starts.
    def pop_drain(queue)
      queue.pop(true)
    rescue ThreadError
      nil
    end

    # Fail-soft per node, and loud: the rows that exist still print, and the
    # log names the node whose machines are missing from the page.
    def log_node_failure(node, error)
      Rails.logger.warn "Hyper-V node #{node} of cluster #{@cr.name} did not answer the " \
                        "instance listing: #{error.class}: #{error.message.to_s.lines.first.to_s.strip}"
    end
  end
end
