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
    def initialize(compute_resource)
      @cr = compute_resource
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

      endpoint = endpoint_vms(filters)
      seen = {}
      rows = []
      yield_sources(names, filters, endpoint) do |vms|
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

    # The endpoint's answer, unsaftened — see the class doc.
    def endpoint_vms(filters)
      Array(@cr.send(:client).servers.all(filters)).flatten.compact
    end

    # The cluster's own node list, asked once per listing. Answered nil when
    # the fog cannot be asked at all: the degradation is then exactly the
    # pre-PLG-29b answer (the endpoint's rows), not a raised page.
    def node_names
      @node_names ||= begin
        names = Array(@cr.send(:client).cluster_nodes).map { |node| node.name.to_s.strip }.reject(&:empty?)
        names.presence
      rescue StandardError => e
        Rails.logger.warn "Hyper-V cluster node list for #{@cr.name} could not be read: " \
                          "#{e.class}: #{e.message.to_s.lines.first.to_s.strip}"
        nil
      end
    end

    # Yields each registration read: the endpoint's own rows first, then every
    # cluster node the endpoint does not already speak for. The endpoint's own
    # node appears in the cluster's node list (measured); it is named by the
    # URL the resource was built with, and the endpoint read above already
    # covers it — asking the ladder too would spend a second WinRM round trip
    # on the same answer.
    def yield_sources(names, filters, endpoint)
      yield endpoint
      own = @cr.send(:endpoint_host_name)
      names.each do |node|
        next if own.present? && node.casecmp?(own)

        begin
          yield Array(@cr.send(:client_for_node, node).servers.all(filters)).flatten.compact
        rescue StandardError => e
          # Fail-soft per node, and loud: the rows that exist still print, and
          # the log names the node whose machines are missing from the page.
          Rails.logger.warn "Hyper-V node #{node} of cluster #{@cr.name} did not answer the " \
                            "instance listing: #{e.class}: #{e.message.to_s.lines.first.to_s.strip}"
        end
      end
    end
  end
end
