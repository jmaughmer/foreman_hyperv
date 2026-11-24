# frozen_string_literal: true

module ForemanHyperv
  class Hyperv < ::ComputeResource
    include ComputeResourceCaching

    # The enablement condition, quoted verbatim from the reviewed plan at every
    # site that refuses one of these operations, so the operator who reads the
    # flash sees the same contract the reviewers did: the refusal lifts by a
    # merged PR once named lab rows have landed, never by configuration.
    # Each is one run of adjacent string literals joined by explicit line
    # continuations: a multiline literal list ending in `+ CONST` silently
    # drops its leading fragments on the parser this plugin is built with
    # (measured on Ruby 3.0.7), and a refusal whose sentence arrives truncated
    # quotes the reviewed plan wrongly. No shared REFUSAL_SENTENCE either, so
    # no literal-plus-constant concatenation anywhere here.
    # PLG-15b opened the create path for stand-alone machines only; a create
    # that asks for a cluster is still refused exactly as PLG-15 refused it,
    # and the cluster path lifts with PLG-15c — by a merged PR, with the same
    # enablement contract quoted, never by configuration.
    CLUSTER_CREATE_REFUSAL = 'Creating a virtual machine in a cluster is refused in every Hyper-V ' \
                             'compute resource in this plugin version; the cluster create path lifts ' \
                             'with PLG-15c by a merged PR, never by configuration. All disk removals ' \
                             'and VM destroys on cluster compute resources are refused in code until ' \
                             'FOG-10, PLG-15b and PLG-21b have merged and (m) and its (k″) rows have ' \
                             'landed; removal based solely on an absent role additionally requires a ' \
                             'named method that proves node-set completeness; enablement is a code ' \
                             'PR, not a configuration.'

    # PLG-15b's stand-alone gate refuses on every unknown, so the message says
    # what the gate asks and what an unknown costs; it is not a lock to be
    # configured away — the reads are made again on every create.
    STANDALONE_CREATE_REFUSAL = 'Creating a virtual machine on this Hyper-V compute resource is ' \
                                'refused: the endpoint did not read as a stand-alone Hyper-V host on ' \
                                'this attempt — the cluster membership read, the cluster-service ' \
                                'registry marker, or the cluster database file marker did not answer ' \
                                'as not found. Nothing was asked of the host and nothing was created. ' \
                                'A host that reads as clustered, or that cannot be read at all, stays ' \
                                'refused; this lifts by a merged PR, never by configuration.'

    # PLG-30: the two shapes of "you asked for failback where failback cannot
    # land". Automatic failback is a property of a cluster ROLE — a stand-alone
    # machine, or a cluster create that opted out of the role (ha_enabled=0),
    # has no object to set it on — and this plugin refuses the contradiction
    # before the wire rather than silently dropping the checkbox an operator
    # just ticked. The fog-side refusal is the same rule aimed at the partner:
    # a fog that never promised the failback contract does not receive a
    # setting it cannot keep.
    FAILBACK_NO_ROLE_REFUSAL = 'Automatic failback was asked for a machine that will not carry a ' \
                               'cluster role: failback is a property of the role, so there is nothing ' \
                               'to set it on. Choose a cluster (and keep the machine clustered), or ' \
                               'uncheck failback. Nothing was asked of the host and nothing was ' \
                               'created.'
    FAILBACK_FOG_REFUSAL = 'Setting automatic failback needs a fog-hyperv that answers the cluster ' \
                           'role failback contract; this one does not, and a setting the operator ' \
                           'asked for is not silently dropped. Nothing was asked of the host and ' \
                           'nothing was created.'

    # PLG-15c opened the destroy path for machines on endpoints PROVEN
    # stand-alone (standalone_destroy_state below). Everything the definition
    # calls a cluster compute resource stays refused — a clustered reading, a
    # sticky sighting, a configured marker that answered present, a machine
    # reporting a cluster role — and it hears the enablement contract as
    # written. The until-clause has landed; §4(22) says it is necessary, not
    # sufficient, and the remaining lifting is the enablement PR's, never a
    # setting's.
    DESTROY_REFUSAL = 'Destroying a virtual machine on this Hyper-V compute resource is refused: the ' \
                      'endpoint was not proven a stand-alone Hyper-V host — a cluster membership ' \
                      'reading, a stored cluster sighting, a configured-cluster marker, or the ' \
                      'machine’s own cluster role answered instead. All disk removals and VM destroys ' \
                      'on cluster compute resources are refused in code until FOG-10, PLG-15b and ' \
                      'PLG-21b have merged and (m) and its (k″) rows have landed; removal based solely ' \
                      'on an absent role additionally requires a named method that proves node-set ' \
                      'completeness; enablement is a code PR, not a configuration. Nothing was stopped ' \
                      'and nothing was deleted.'

    # The destroy gate refuses on every unknown, as its sister create gate
    # does, and the message says what the gate asks and what an unknown costs.
    STANDALONE_DESTROY_REFUSAL = 'Destroying a virtual machine on this Hyper-V compute resource is ' \
                                 'refused: the endpoint did not read as a stand-alone Hyper-V host on ' \
                                 'this attempt — the cluster membership read, the cluster-service ' \
                                 'state read, the cluster-service registry marker, or the cluster ' \
                                 'database file marker did not answer as expected. Nothing was ' \
                                 'stopped and nothing was deleted. A host that reads as clustered, or ' \
                                 'that cannot be read at all, stays refused; this lifts by a merged ' \
                                 'PR, never by configuration.'

    # The destroy-side self rung: the same N6 refusal the create path answers
    # with, worded for a machine that already exists. Per-node addressing is
    # PLG-5a's; until it lands, a VM on another node stays refused — the
    # pre-registered shipping state.
    DESTROY_SELF_RUNG_REFUSAL = 'Destroying a virtual machine on a computer other than this compute ' \
                                'resource’s own endpoint is refused until per-node addressing lands: ' \
                                'the name the endpoint gives itself did not match the machine’s ' \
                                'computer name. Nothing was stopped and nothing was deleted.'

    DISK_REFUSAL = 'Removing disks from a virtual machine is refused in every Hyper-V compute resource ' \
                   'in this plugin version. All disk removals and VM destroys on cluster compute ' \
                   'resources are refused in code until FOG-10, PLG-15b and PLG-21b have merged and ' \
                   '(m) and its (k″) rows have landed; removal based solely on an absent role ' \
                   'additionally requires a named method that proves node-set completeness; ' \
                   'enablement is a code PR, not a configuration.'

    # PLG-22: the enablement set. Everything this PR unlocks stands on six
    # behaviours of the fog it is built against — the tri-state cluster reads,
    # the exact-host connection gate (FOG-11), the literal-path destructive
    # calls (FOG-14), the stdout hygiene contract (FOG-15), the input
    # hardening (FOG-9) and the cluster capacity projection (FOG-8) — and the
    # runtime check asks the installed fog for ALL of them: the constant list
    # AND the per-behaviour predicate every client of that build answers. A
    # fog missing any one is the pre-enablement era again, and every
    # operation this PR unlocks refuses exactly as it refused before. The
    # constant is FOG-9's, and the plugin gate trusts it for the rule behind
    # it (R13): the builder validator and the connection gate are ONE pure
    # function there, so there is nothing here for a second list to re-prove.
    # (PLG-5b grew the set with FOG-8's sixth: the capacity read PLG-14 puts
    # in front of placement stands or falls on that projection.)
    ENABLEMENT_CAPABILITIES = {
      tri_state_cluster: :supports_clusters?,
      exact_host_connection: :supports_exact_host_connections?,
      literal_path_destructive: :supports_literal_path_destructive?,
      stdout_json_hygiene: :supports_stdout_json_hygiene?,
      input_hardening: :supports_input_hardening?,
      cluster_capacity_projection: :supports_cluster_capacity_projection?
    }.freeze

    # The WinRM waits every client this resource composes insists on (PLG-16,
    # evidence §37.6): fog sends operation_timeout/receive_timeout ONLY when
    # configured, and nothing had ever configured them — the gem's own
    # measured 60 s/70 s then capped the path under the >=90 s the plan chose
    # over the NTLM/fresh-connection worst case, and a stalled cold cluster
    # read ran against whatever the gem guesses. The receive wait stays above
    # the operation wait so a receive never kills an operation still inside
    # its own cap; at the cap the answer comes back partial (measured, §42.4)
    # and the reads' own validation refuses it rather than trusting it.
    WINRM_OPERATION_TIMEOUT = 90
    WINRM_RECEIVE_TIMEOUT = 120

    # The capability-era refusal: the plugin build is enabled, the installed
    # fog is not. Names the missing behaviours so the operator knows what to
    # upgrade, and quotes no remote text.
    FOG_CAPABILITY_REFUSAL = 'This operation is refused: the fog-hyperv this plugin runs against does ' \
                             'not answer every behaviour the enablement depends on (missing: ' \
                             '%<missing>s). Nothing was stopped, deleted or created. Upgrade ' \
                             'fog-hyperv to the build the plugin declares, or use a plugin version ' \
                             'whose refusals match the fog you have.'

    # The enablement era still refuses a destroy whose classification reads did
    # not answer: indeterminate is not a decision enablement can spend. The
    # machine stays exactly as it is, with the reads made again on the next
    # attempt — the same cost the pre-enablement unknown carried, worded for
    # the era where clustered machines ARE destroyable.
    DESTROY_INDETERMINATE_REFUSAL = 'Destroying a virtual machine on this Hyper-V compute resource is ' \
                                    'refused: the cluster classification reads did not answer on this ' \
                                    'attempt, and an unreadable endpoint is not a license to delete. ' \
                                    'Nothing was stopped and nothing was deleted; the reads are made ' \
                                    'again on the next attempt.'

    # F2's guard: a node-identity name is quoted into the remote guard script
    # only in this shape — a host or node name, nothing a shell or PowerShell
    # reads as special. A name outside it is refused before anything is sent:
    # the guard is a server-side check, not a string exercise, and a name that
    # cannot be quoted safely is not a name to dial.
    NODE_NAME_SHAPE = /\A[A-Za-z0-9][A-Za-z0-9.-]{0,252}\z/

    # What $env:COMPUTERNAME answers with is the NETBIOS computer name: up to 15
    # characters, uppercase. Cluster node lists and operator overrides carry the
    # full (possibly DNS, possibly longer) name, so the guard accepts the full
    # name AND its 15-character truncation, for the node's own name and for the
    # first label of the identity host. PowerShell's -in comparison is
    # case-insensitive, so no Ruby-side case folding rides the wire.
    NETBIOS_MAX_LENGTH = 15

    # The enabled era's disk-removal refusal: the fog is the enablement's
    # partner, but THIS disk's file cannot be proven safe to delete — its
    # path is not attributable to the machine, or its sharing state is not
    # proven absent (fog's own contract refuses a drive whose persistent
    # reservations are true or unread, because deleting a disk another running
    # machine reads destroys that machine's data). The whole edit refuses; no
    # part of it half-completes.
    DISK_UNATTRIBUTED_REFUSAL = 'Removing that disk is refused: its file is not attributable to this ' \
                                'machine’s folder or a storage root the hypervisor named, or its ' \
                                'sharing state is not proven absent, and deleting a disk another ' \
                                'machine may be reading destroys the wrong thing. Nothing was ' \
                                'detached and no file was deleted; the disk stays exactly as it is.'

    # The folder pre-flight, one round trip: the folder's existence, its
    # reparse/hidden attributes, and its descendants' names (recursive — the
    # config lives one level down). The tokens are fixed words, never remote
    # text beyond the child NAMES (which this parses but never re-quotes);
    # %<folder>s arrives from the string rule, already attributed and
    # single-quoted.
    FOLDER_PREFLIGHT_SCRIPT = <<~SCRIPT
      $p = %<folder>s
      if (-not (Test-Path -LiteralPath $p)) { 'ABSENT' }
      else {
        $i = Get-Item -LiteralPath $p -Force
        if ($i.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { 'KEEP:JUNCTION' }
        elseif ($i.Attributes -band [System.IO.FileAttributes]::Hidden) { 'KEEP:HIDDEN' }
        else { 'NAMES:' + ((Get-ChildItem -LiteralPath $p -Force -Recurse | ForEach-Object { $_.Name }) -join ';') }
      }
    SCRIPT

    # PLG-21a: a fog write over WinRM is INDETERMINATE once the request has been
    # sent — the measured behaviour at the pinned fog is a successful
    # Add-ClusterVirtualMachineRole raising Fog::JSON::DecodeError on the empty
    # reply — so the only proof of success is a post-write read of the role,
    # keyed on the machine's id, taken as a cluster read on the compute
    # resource's own endpoint (an answer from any node was measured: the cluster
    # service replies for the whole cluster). Absent, empty or partial after
    # these attempts is indeterminate, and indeterminate means touch nothing.
    # The per-attempt cap is the WinRM operation timeout; this is the wait
    # between attempts.
    ROLE_READBACK_ATTEMPTS = 3
    ROLE_READBACK_INTERVAL = 30

    # Both templates take their values as Foreman::Exception params, which the
    # class sprints exactly once when it renders: a value that carries a percent
    # sign can never break the render, and every value passes through
    # strand_param anyway. The class name is always bare words; the first line is
    # fog's own text and is carried sanitized, with `readback-empty` for the
    # case where the write itself did not raise.
    ROLE_STRAND_FAILURE = 'Placing the virtual machine %<uuid>s in the cluster did not provably succeed ' \
                          '(the request reached the cluster, its outcome is unknown): %<error_class>s — ' \
                          '%<first_line>s. The machine at %<path>s named %<name>s has been left exactly as ' \
                          'it is: nothing was stopped, deleted or un-clustered, because tearing down a ' \
                          'machine the cluster may already own destroys the wrong thing. The strand is ' \
                          'in the log for an operator to resolve by hand.'

    ROLE_STRAND_EMPTY = 'Placing the virtual machine %<uuid>s in the cluster did not provably succeed ' \
                        '(the request reached the cluster, its outcome is unknown): readback-empty. ' \
                        'The machine at %<path>s named %<name>s has been left exactly as it is: nothing ' \
                        'was stopped, deleted or un-clustered, because tearing down a machine the ' \
                        'cluster may already own destroys the wrong thing. The strand is in the log ' \
                        'for an operator to resolve by hand.'

    # Hyper-V names a machine's cluster role after the machine; the prefix is
    # what a readback falls back to when the role's VM-id property is not
    # populated (see add_cluster_role_proven).
    ROLE_NAME_PREFIX = 'Virtual Machine '

    # PLG-35: how many live reads the role index demands before it believes
    # a flap-shaped answer, and how long it waits between asks. Two asks a
    # pause apart: the WinRM flaps on record cleared within seconds (a
    # fresh instance read correctly while the memo still held the flap's
    # answer), and the cap keeps a true outage at one pause with the same
    # honest answer it gives today.
    ROLE_INDEX_PROBE_ATTEMPTS = 2
    ROLE_INDEX_READ_ATTEMPTS = 2
    ROLE_INDEX_RETRY_DELAY_SECONDS = 2

    # PLG-31: the value a clustered group carries on BOTH ends of its
    # failback window when no window is set — measured on HV-CL01 (§60,
    # re-grounded §74) and documented by this fog's role model. Named here
    # rather than borrowed from fog so the display reads the wire value
    # even on a fog whose model predates that constant.
    FAILBACK_WINDOW_DISABLED = 4_294_967_295

    # PLG-15b arm (a): the cluster membership read is one minimal-property WQL
    # query against the cluster's own namespace — the same fog run_wql path
    # supports_clusters? uses (which appends the `/*` grammar itself), pinned
    # by red test to this exact query string and namespace.
    CLUSTER_MEMBERSHIP_QUERY = 'SELECT Name FROM MSCluster_Cluster'
    CLUSTER_MEMBERSHIP_NAMESPACE = 'root/mscluster'

    # The two wire answers that read, through this exact query path, as
    # "not clustered", both measured on the lab node through the fog wire:
    # WSMAN 1359 (the cluster WMI provider has nothing to answer with on a
    # machine not joined to a cluster — nested ProviderFault, WsmWmiPl.dll)
    # and WMI 2150858778 (the MSCluster_* classes themselves are absent —
    # the failover-cluster feature is not installed). Anything else — the
    # auth and transport failures that say nothing about membership
    # included — is indeterminate (N3).
    WIRE_CODE_CLUSTER_UNAVAILABLE = 1359
    WIRE_CODE_FEATURE_ABSENT = 2_150_858_778

    # B2's dual configured-marker, with the primitive each is read with
    # (measured paths, hyperv-e-results §52 and the d16b rows). The primitive
    # is NAMED = OPEN/READ, never a metadata or existence check: the registry
    # key is opened and its values enumerated (Get-ItemProperty, whose
    # measured missing-key answer is ItemNotFoundException), and the file is
    # opened and its first line read (Get-Content — Get-Item would answer
    # from the directory entry and never open a file an ACL denies to us,
    # which is exactly what row (v) has to be able to see fail).
    MARKER_READS = {
      params_registry: {
        cmdlet: 'Get-ItemProperty',
        path: 'HKLM:\SYSTEM\CurrentControlSet\Services\ClusSvc\Parameters'
      }.freeze,
      clusdb_file: {
        cmdlet: 'Get-Content',
        args: '-TotalCount 1',
        path: 'C:\Windows\Cluster\CLUSDB'
      }.freeze
    }.freeze

    # PLG-15c's belt-and-braces cluster-service state read. GetNodeClusterState
    # (clusapi.dll) — the enum is MS Learn fetched 2026-11-19 and every value
    # this gate acts on is a measured lab cell (hyperv-e-results §45.2, §46.4):
    # a healthy member reads 19, a stopped-joined one 3, and joined-and-Disabled
    # 1 — BYTE-IDENTICAL to never-joined, which is why the dual markers, not
    # this read, carry the maintenance refusal (plan §2 item 9's honest role
    # statement). 0 means "no cluster service or config", not "feature absent":
    # feature-absent (d19) and registration-destroyed (d23g) read it alike, and
    # the mid-removal cell answered rc=2 — which is why rc≠0 and a raising
    # P/Invoke are ALWAYS indeterminate (N2), never a feature-absent reading.
    # Hosts that block Add-Type (R11: Constrained Language Mode, WDAC, AppLocker)
    # read indeterminate PERMANENTLY, so standalone destroy never unlocks on
    # them — the accepted availability trade, with a manual runbook in
    # docs/RUNBOOK.md.
    CLUSAPI_NO_CLUSTER_SERVICE = 0
    CLUSAPI_NOT_CONFIGURED = 1
    CLUSAPI_NOT_RUNNING = 3
    CLUSAPI_RUNNING = 19

    # The two stores the state-0 branch additionally asks about, read with the
    # same named-primitive discipline as the markers (N3): the service record is
    # what the lab measured it as — the ClusSvc service key itself, opened with
    # the primitive whose not-found answer row (v) measured — and the cluster
    # directory is read the same way but is NOT a configured-marker: an evicted
    # node keeps it as an empty husk and a feature install recreates it empty
    # (twice measured, §45.2/§46.5), so the gate consults it only where the
    # plan's B9/N2 rule names it, beside a missing service record.
    SERVICE_RECORD_READ = {
      cmdlet: 'Get-ItemProperty',
      path: 'HKLM:\SYSTEM\CurrentControlSet\Services\ClusSvc'
    }.freeze
    CLUSTER_DIRECTORY_READ = {
      cmdlet: 'Get-Item',
      path: 'C:\Windows\Cluster'
    }.freeze
    # The reviewed P/Invoke definition, carried as a constant so the script
    # built further below never breaks the length rule. Nothing else reaches
    # it; it sits with the two reads it belongs to, not in the private
    # section (Lint/UselessConstantScoping).
    CLUSTER_API_SIGNATURE = '[DllImport("clusapi.dll", CharSet=CharSet.Unicode, SetLastError=true)] ' \
                            'public static extern int GetNodeClusterState(' \
                            'string pszNodeName, out uint pdwClusterState);'

    # PLG-5a: the shape of one `NODE = host[:port]` line of the operator's
    # node→endpoint override. Both sides are bare host names — never a
    # scheme, never a path, never whitespace. A value outside the shape is
    # REFUSED at save, not sanitized: the whole point of the override is that
    # exactly one string becomes the endpoint, and a silently repaired value
    # hides which string that was. (Backticks refused, not stripped — the
    # PLG-15 discipline.)
    NODE_OVERRIDE_HOST = /\A[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*\z/
    NODE_OVERRIDE_PORT = /\A[1-9][0-9]{0,4}\z/
    # R17's enforcement point, rewritten by PLG-5b: the check runs on the
    # COMPOSED endpoint, not the identity source — the compute resource
    # supplies scheme and TLS, so an https resource would otherwise compose an
    # https node endpoint and simply WORK, unvalidated. The (w) matrix
    # validated exactly two families: http+negotiate for any identity (rows
    # HTTP-NEG-IP and HTTP-NEG-FQDN, OK on all three nodes), and https with
    # hostname verification against an explicit CA trust (row HTTPS-NEG-FQDN,
    # OK on all three nodes once the CA file was wired). Every other
    # composition stays refused, and the refusal names it out loud.
    NODE_ENDPOINT_REFUSAL = 'Refusing to reach a cluster node through %<endpoint>s: the composed ' \
                            'per-node endpoint uses a transport the (w) matrix did not validate. Only ' \
                            'http, and https with a certificate-verifiable name and a ' \
                            'hyperv_ca_trust_path or the hyperv_ssl_verify opt-out, are composed. ' \
                            'No node operation was attempted.'

    # PLG-5b, row (w): HTTPS-NEG-IP was the measured dead end — an IPv4
    # identity gives the node certificate no hostname to verify against.
    # PLG-32 hands the fix to the operator: the refusal fired while
    # verification is ON names hyperv_ssl_verify as the lever, so the text
    # never sells a dead end that a checkbox now opens.
    NODE_TLS_IP_REFUSAL = 'Refusing to reach %<endpoint>s over https: an IPv4 identity gives the ' \
                          'certificate no hostname to verify against (the (w) transport matrix found ' \
                          'no hostname-verified path to an IP endpoint). A hyperv_node_overrides ' \
                          'entry naming the node with a verifiable hostname composes, or the ' \
                          'hyperv_ssl_verify opt-out composes it as it stands — verification off is ' \
                          'the operator’s deliberate choice, never this plugin’s. No node operation ' \
                          'was attempted.'

    # The other half of row HTTPS-NEG-FQDN: the chain verified ONLY against
    # the explicit CA file; fog's default store does not see the system
    # anchors on this platform (measured, (w) final rows). PLG-32: naming the
    # CA file is no longer the only lever left, so the text says so.
    NODE_TLS_TRUST_REFUSAL = 'Refusing to reach %<endpoint>s over https: hyperv_ca_trust_path is ' \
                             'not set on this compute resource, so the node certificate has nothing ' \
                             'to verify against — the (w) matrix validated https only with an ' \
                             'explicit CA trust. Either name the CA file, or take the ' \
                             'hyperv_ssl_verify opt-out — verification off is the operator’s ' \
                             'deliberate choice, never this plugin’s. No node operation was ' \
                             'attempted.'

    # PLG-5b: the address the cluster gives its own nodes is a fact with a
    # shape; anything outside the shape is REFUSED naming the node and the
    # reason (the capacity-read discipline), never guessed.
    NODE_ADDRESS_REFUSAL = 'Refusing to address cluster node %<node>s: %<reason>s ' \
                           'No node operation was attempted.'
    NODE_ADDRESS_CLIENT_REFUSAL = 'the cluster’s own network interfaces could not be read through ' \
                                  'this compute resource’s client, so the node has no address to dial.'
    NODE_ADDRESS_NO_ROWS = 'the cluster’s network-interface read names no interface for it, so it ' \
                           'has no client-reachable address to dial.'
    NODE_ADDRESS_NO_CLIENT_ROLE = 'its cluster network interfaces sit on no client-role (Role 3) ' \
                                  'cluster network, so it has no address reachable from outside the ' \
                                  'cluster — a hyperv_node_overrides entry naming the node carries ' \
                                  'placement traffic there.'
    NODE_ADDRESS_AMBIGUOUS = 'more than one client-role address answered for it (%<candidates>s) — ' \
                             'refusing to pick between them; a hyperv_node_overrides entry states ' \
                             'the operator’s choice.'
    NODE_ADDRESS_NOT_IPV4 = 'its client-role address %<address>s is not a plain IPv4 address, and ' \
                            'this plugin dials discovered nodes by IPv4 only.'
    NODE_IPV4 = /\A\d{1,3}(?:\.\d{1,3}){3}\z/

    # PLG-5b: the CA file the hardened per-node composition verifies against,
    # read on the FOREMAN host (fog builds the trust store there), so it is an
    # absolute POSIX path and nothing shell- or normalization-flavoured. The
    # PLG-15 discipline again: refused at save, not repaired.
    CA_TRUST_PATH_SHAPE = %r{\A/[A-Za-z0-9._\-/]+\z}

    # PLG-14: the cluster resource states the capacity projection was MEASURED
    # to answer (evidence §30.2, re-confirmed §34.5): 2 = Online, 3 = Offline.
    # Anything else — including silence — is excluded from placement storage
    # WITH A REASON, never treated as either (FOG-8's own rule, passed through
    # uninterpreted by fog on purpose).
    VOLUME_STATE_ONLINE = 2
    VOLUME_STATE_OFFLINE = 3

    # PLG-14: the two ways a placement read can say "not this volume" and mean
    # different things. A volume the cluster ANSWERS but does not offer (it is
    # offline, stateless, or answers no mount path) gets its exclusion named —
    # the operator picked a real volume and deserves to hear why the cluster
    # declined it. A volume never answered at all keeps the membership refusal
    # word for word, because that is a different fact.
    STORAGE_EXCLUDED_REFUSAL = 'Refusing to place a disk on the shared volume %<volume>s: %<reason>s. ' \
                               'It is a volume of this cluster but not placement storage; nothing was ' \
                               'asked of the host.'
    # The chosen storage answering no mount path is the one shape where the
    # create used to GUESS: `storage&.id || hypervisor.virtual_machine_path`
    # fell through to the node's local disk — off the CSV for a clustered
    # machine — and [nil, name].join('\\') named the disk folder relatively
    # (the FOG-17 read-side shape). Both guesses are refusals now.
    STORAGE_BLANK_PATH_REFUSAL = 'Refusing to place the virtual machine on the shared volume ' \
                                 '%<volume>s: the volume answers no mount path, and no config path ' \
                                 'or disk folder may be guessed from its name — a guessed path lands ' \
                                 'the files on one node’s local disk, off the cluster. Nothing was ' \
                                 'asked of the host and nothing was created.'

    # The self rung's refusal (N6): a target that is not the endpoint's own
    # machine is per-node territory, and per-node addressing needs an
    # identity. Failing closed here is the pre-registered shipping state,
    # not a bug.
    SELF_RUNG_REFUSAL = 'Creating a virtual machine on a computer other than this compute ' \
                        'resource’s own endpoint needs per-node addressing: the name the endpoint ' \
                        'gives itself did not match, and no node→endpoint override and no cluster ' \
                        'address read routed the target. Nothing was asked of the host and nothing ' \
                        'was created.'

    # B6: a cluster reading the ledger could not hold is a reading no future
    # decision may lean on, so the write failing is itself a refusal.
    SIGHTING_WRITE_REFUSAL = 'Refusing to act on this cluster reading because the sightings record ' \
                             'could not be written: the ledger is what keeps a later destroy from ' \
                             'trusting a host that once answered as a cluster, and an unreadable ' \
                             'ledger is not a safe one. Nothing was asked of the host and nothing ' \
                             'was created.'

    validates :url, :user, :password, presence: true
    validate :hyperv_node_overrides_shape
    validate :hyperv_ca_trust_path_shape
    after_validation :validate_connectivity unless Rails.env.test?

    def self.provider_friendly_name
      'Hyper-V'
    end

    def to_label
      "#{name} (#{provider_friendly_name})"
    end

    def self.available?
      Fog::Compute.providers.include?(:hyperv)
    end

    def self.model_name
      ComputeResource.model_name
    end

    def supports_update?
      true
    end

    def editable_network_interfaces?
      true
    end

    def capabilities
      [:build]
    end

    def test_connection(options = {})
      validate_connectivity(options)
    end

    def validate_connectivity(_options = {})
      return unless connection_properties_valid?
      return false if errors.any?

      error = connection_error
      errors.add(:base, error) if error
    end

    # Fog's valid? reads a Msvm_ComputerSystem instance, which any authenticated
    # user may query: it reports success for hosts the account can not manage,
    # and before fog-hyperv 0.2.2 (unreleased) it never returned true for a
    # remote host at all. Get-VMHost is the call the rest of the provider needs
    # anyway, so validating with it also proves the account can manage Hyper-V.
    #
    # @return [String, nil] the reason the connection can not be used
    def connection_error
      client.hosts.first ? nil : format(_('%<url>s did not return a Hyper-V host'), url: url)
    rescue StandardError => e
      e.message
    end

    def connection_valid?
      return false if url.blank? || user.blank? || password.blank?

      connection_error.nil?
    end

    def connection_properties_valid?
      errors[:url].empty? && errors[:user].empty? && errors[:password].empty?
    end

    def caching_enabled
      true
    end

    def provided_attributes
      super.merge(mac: :mac)
    end

    # TODO
    def max_cpu_count(host = nil)
      (host || hypervisor).logical_processor_count
    end

    def max_memory(host = nil)
      (host || hypervisor).memory_capacity
    end

    def available_hypervisors
      client.hosts.load(
        cache.cache(hypervisors_cache_key) do
          cluster_backed_hosts(endpoint_cluster).map(&:attributes)
        end
      )
    end
    alias hosts available_hypervisors

    # The public accessor the VM form and the API use. Routed through
    # cluster_named, which compares a cached listing in Ruby: fog's
    # clusters.get(name) interpolated the name into a Get-Cluster filter, so
    # this was the one public method a view-permission parameter could push
    # into the builder by itself. A name that is not a member now answers nil
    # — the form falls back to the resource's own hosts — where it used to
    # raise Fog::Errors::NotFound and error the page.
    def cluster(name)
      cluster_named(name)
    end

    # The computers the machine form offers its Computer Name select between
    # (PLG-25). The named cluster is listed through cluster_backed_hosts — the
    # resilient per-node listing — and NOT through fog's Cluster#hosts, which
    # dials every node through this resource's own client and takes the whole
    # listing down with the first node that client refuses (every
    # non-endpoint node, under exact_host_connection). With no cluster named
    # the resource's own listing answers, endpoint cluster included, already
    # cached.
    def form_computers(cluster_name = nil)
      cluster = cluster_named(cluster_name)
      return hosts if cluster.nil?

      cluster_backed_hosts(cluster)
    end

    def clusters
      client.clusters.load(
        cache.cache(:clusters) do
          _clusters.map(&:attributes)
        end
      )
    end

    # Mirror available_networks above: core renders the clusters endpoint from
    # vSphere flavoured fields the Hyper-V cluster model does not have.
    ApiCluster = Struct.new(:name, :id, :full_path, :datacenter, :num_host)

    def available_clusters
      clusters.map do |cluster|
        ApiCluster.new(cluster.name, cluster.id, nil, nil, cluster_node_count(cluster))
      end
    end

    def hypervisor
      client.hosts.new(
        cache.cache(hypervisor_cache_key) do
          client.hosts.first.attributes
        end
      )
    end

    def associated_host(vm)
      associate_by('mac', vm.network_adapters.map(&:mac))
    end

    delegate :servers, to: :client

    def switches(host)
      host ||= hosts.first
      client.switches.load(
        cache.cache(switches_cache_key(host)) do
          host.switches.all.map(&:attributes)
        end
      )
    end

    # Core's api/v2/compute_resources/available_networks.rabl renders a flat
    # collection of VMware/libvirt flavoured network objects. Hyper-V exposes
    # virtual switches instead of fog networks, and the switch models are
    # bound to a live connection, so map them into plain structs.
    ApiNetwork = Struct.new(:name, :id, :datacenter, :virtualswitch, :vlanid)

    # Core renders this from one flat list of network objects. With a cluster named
    # the choices are the switches its nodes have, which is not one host's list: a
    # virtual switch exists per node, and the same name on two nodes is two switches
    # with two GUIDs. A machine is connected by name, so names are what this lists —
    # all of them, including a name one node is missing, because dropping it silently
    # would leave the user wondering where the switch they built went. What is missing
    # where is logged; picking such a name for a machine that lands on the node
    # without it stays a creation error, which is the honest place to say it.
    def available_networks(cluster_id = nil)
      cluster = cluster_named(cluster_id)
      return api_networks(switches(nil)) if cluster.nil?

      hosts = cluster_backed_hosts(cluster)
      return api_networks(switches(nil)) if hosts.empty?

      switches_by_host = hosts.each_with_object({}) do |host, acc|
        acc[host.name] = begin
          switches(host)
        rescue StandardError => e
          Rails.logger.warn "Hyper-V switches for #{host.name} could not be read: #{e.message.lines.first}"
          []
        end
      end
      first_by_name = {}
      switches_by_host.each_value { |list| list.each { |sw| first_by_name[sw.name] ||= sw } }
      shared = switches_by_host.values.map { |list| list.map(&:name) }.reduce(&:&)
      (first_by_name.keys - shared).each do |name|
        without = switches_by_host.reject { |_host, list| list.any? { |sw| sw.name == name } }.keys
        Rails.logger.warn "Hyper-V switch #{name} is missing from #{without.join(', ')} in cluster #{cluster.name}"
      end

      first_by_name.values.map { |sw| ApiNetwork.new(sw.name, sw.id, nil, sw.name, nil) }
    end

    # Core's base #available_storage_domains answers "Not implemented for Hyper-V",
    # which the API returns as a 500 for a question that has an honest answer: a
    # stand-alone Hyper-V host has no datastores. A clustered one has its Cluster
    # Shared Volumes, and those are what a machine's disks go on, so this returns
    # them once there is a cluster to ask. An empty list rather than an exception
    # means the UI says "no datastores" and the API says 200 with [], which is the
    # truth about this host.
    #
    # PLG-14: what is offered is what is PLACEABLE. The volumes come from fog's
    # capacity projection (FOG-8) and only its measured Online state (2) with a
    # confirmed mount path is offered at all; an offline volume (3), an
    # unmeasured state, a silence, and an online volume answering no path are
    # each excluded, logged naming the volume and the reason. The fields are
    # core's rabl's (available_storage_domains.rabl reads name, id, capacity,
    # freespace, uncommitted) rather than Hyper-V's own names, and the id stays
    # the mount path because that is what the form and the deprecated
    # /available_storage_domains/:name route address volumes by.
    ApiStorageDomain = Struct.new(:name, :id, :capacity, :freespace, :uncommitted)

    def available_storage_domains(cluster_id = nil)
      return [] if cluster_id.blank?

      # Looked up in the cached cluster list rather than asked for by name: on a host
      # with no cluster, asking fog for one raises, and a stale cluster id in a URL is
      # not a reason to find out whether it does.
      cluster = clusters.detect { |c| c.id == cluster_id || c.name == cluster_id }
      placement_storage_domains(cluster).first
    end

    # The deprecated /available_storage_domains/:name route asks for one by name with
    # no cluster named to look in, so it looks in all of them.
    def storage_domain(name)
      clusters.flat_map { |cluster| available_storage_domains(cluster.id) }
              .detect { |domain| domain.id == name || domain.name == name }
    end

    # --- bootdisk PR-2: the iso_* quartet --------------------------------------
    #
    # foreman_bootdisk's Orchestration::Compute calls exactly these four on the
    # COMPUTE RESOURCE (contract verbatim from the installed 24.1.0):
    #
    #   iso_upload(isofile, uuid, storage_id:)                    before_build 6
    #   iso_attach(File.basename(isofile), uuid, storage_id:)     before_build 900
    #   iso_detach(uuid)                                          after_build 52
    #   iso_delete(isofile, uuid)                                 after_build 53
    #
    # The bytes move by the host's own HTTP pull (Decision 2): iso_upload puts
    # the file on BootdiskTransfer's shelf and hands the host fog's
    # fetch_url_to_path, which refuses anything whose size or host-side sha256
    # disagrees BEFORE the file takes its final name. The host-side file is
    # named for the ISO's basename — attach and delete receive that basename
    # and no nonce, so the nonce guards the URL, never the path. Attach sets
    # the drive's media and moves the DVD to the front of the UEFI boot order
    # in one VM-off step (both Add/Set-VMDvdDrive and Set-VMFirmware fail on a
    # running machine — measured, spike 0.4); detach ejects; delete sweeps the
    # basename out of every root the host itself reported, fog's scoped
    # remove_file answering absence as false so a repeated cleanup is an
    # answer, not a failure.
    #
    # The gates (the fork's rule: capabilities, never versions): the pull
    # requires the enablement era AND :file_pull/fetch_url_to_path; attach
    # requires the era and its five drive/order requests; the scoped delete
    # requires :contained_file_removal/remove_file and deliberately NOT the
    # era — fog's own request carries its own scope guard, and the cleanup
    # rides a destroy path that must not be gated on the create era. The
    # two bootdisk words sit on the plugin's opt-in side (the enablement
    # entries are predicate-paired and fog pairs no predicate with these;
    # see the pin in HypervEnablementTest).

    BOOTDISK_CAPABILITY_REFUSAL = 'This bootdisk operation is refused: the fog-hyperv this plugin runs ' \
                                  'against does not carry the %<capability>s behaviour (no %<request>s). ' \
                                  'Nothing was transferred, attached, detached or deleted. Upgrade ' \
                                  'fog-hyperv to the build the bootdisk flow declares.'

    BOOTDISK_REQUEST_REFUSAL = 'This bootdisk operation is refused: the fog-hyperv this plugin runs ' \
                               'against cannot send %<requests>s. Nothing was changed on the machine.'

    BOOTDISK_POWER_REFUSAL = 'The boot disk cannot be attached while the machine is %<state>s: ' \
                             'setting a DVD image and moving the boot order both require the ' \
                             'machine powered off (measured). Nothing was changed.'

    BOOTDISK_GEN1_REFUSAL = 'The boot disk is refused for a generation %<generation>s machine: this ride ends ' \
                            'in a UEFI boot-order write (fog reads and writes the preferred boot order ' \
                            'through the VMM V2 root, a generation 2 surface), and a BIOS machine boots a ' \
                            'bootdisk ISO through its legacy DVD path with no write needed. Nothing was changed.'

    BOOTDISK_NO_MACHINE_REFUSAL = 'The boot disk ride is refused: no virtual machine %<vm_id>s answers on this ' \
                                  'resource (the catalog does not hold it and the cluster-owner lookup found ' \
                                  'nothing). Nothing was transferred or changed.'

    BOOTDISK_NODE_REFUSAL = 'The boot disk ride is refused: the machine lives on cluster node %<node>s, which ' \
                            'this endpoint cannot write (the cluster role names no owner, or an owner whose ' \
                            'endpoint is not this one). The cluster shared volume the ISO lands on is only ' \
                            'reachable from the owning side. Nothing was transferred or changed.'

    BOOTDISK_NO_ROOTS_WARNING = 'The boot disk file cannot be deleted: the host reported no storage ' \
                                'roots, so the sweep had nowhere to look. The file is left in place and ' \
                                'the build proceeds.'

    BOOTDISK_TRANSFER_FAILED = 'The boot disk ISO did not reach the host: the host reported receiving ' \
                               '%<received>s bytes of the %<requested>s it was asked to fetch. Nothing ' \
                               'was attached; the build is aborted rather than left to hang on a missing ' \
                               'disc (measured failure mode).'

    # foreman_bootdisk before_build prio 6 (Orchestration::Compute#setBuild):
    # move the generated bootdisk ISO onto the Hyper-V host's storage so the
    # attach step can mount it. The file RIDES, it is not pushed: Decision 2
    # measured the WinRM push at 0.54-0.75 MB/s against the host's own HTTP
    # pull at 148.9 MB/s, so the plugin stages the ISO under a one-shot nonce
    # and fog's fetch_url_to_path has the HOST pull it — verifying status,
    # byte count and sha256 on the host BEFORE the file takes its final name,
    # and refusing to overwrite one that exists. The staged copy is deleted in
    # the ensure either way: a leaked served ISO holds disk and host keys.
    # Answers the transferred byte count; raises on any failure, because a
    # build that proceeds without its media installs from the network instead.
    def iso_upload(isofile, vm_id, options = {})
      storage_id = options.is_a?(Hash) ? options[:storage_id] : nil
      raise ArgumentError, 'iso_upload requires the generated ISO file' if isofile.blank? || !File.file?(isofile)
      raise ArgumentError, 'iso_upload requires a virtual machine id' if vm_id.blank?
      raise ArgumentError, 'iso_upload requires a storage id' if storage_id.blank?

      # Gates first — every one of them, before a single read (round 17). A
      # refused ride must refuse before 245 MB stages and before any WinRM.
      refuse_without_enablement!
      require_bootdisk_pull!
      bootdisk_ride_check!(vm_id)
      root = bootdisk_storage_root!(storage_id, 'iso_upload', 'transferred', storage_roots)

      nonce = nil
      begin
        staged = ForemanHyperv::BootdiskTransfer.stage(isofile, machine: vm_id)
        nonce = staged.nonce
        # The host-side name is the ISO's basename, never the nonce: iso_attach
        # and iso_delete receive only the basename (core hands them
        # File.basename(isofile)), and fetch_url_to_path's no-overwrite rule
        # turns a stale file here into a refusal that reaches a human.
        target = bootdisk_host_path(root, File.basename(isofile))
        received = client.fetch_url_to_path(url: staged.url, path: target,
                                            sha256: staged.sha256, size: staged.bytes)
        unless received == staged.bytes
          raise ForemanHyperv::OperationRefused,
                format(BOOTDISK_TRANSFER_FAILED, requested: staged.bytes, received: received.inspect)
        end
        staged.bytes
      ensure
        ForemanHyperv::BootdiskTransfer.discard(nonce) if nonce
      end
    end

    # foreman_bootdisk before_build prio 900 (Orchestration::Compute#setBuild):
    # mount the transferred ISO and put the DVD first in the boot order. The
    # machine must be Off (measured: Set-VMDvdDrive refuses a running machine)
    # and generation 2 (this ride ends in the UEFI boot-order write). fog's
    # drive reads answer nil, ONE bare Hash, or an Array (measured) —
    # dvd_drive_list normalizes all three. Fog's write requests take the
    # computer_name of the node whose Get-VM printed the row (fog's own
    # Servers#get answers it, including through the cluster-owner fallback);
    # every drive call and both boot-order calls ride it, which is also what
    # keeps a clustered machine's writes on the node that holds it.
    def iso_attach(filename, vm_id, options = {})
      storage_id = options.is_a?(Hash) ? options[:storage_id] : nil
      name = bootdisk_filename!(filename, 'iso_attach')
      raise ArgumentError, 'iso_attach requires a virtual machine id' if vm_id.blank?
      raise ArgumentError, 'iso_attach requires a storage id' if storage_id.blank?

      refuse_without_enablement!
      require_fog_requests!(:get_vm_dvd_drive, :add_vm_dvd_drive, :set_vm_dvd_drive,
                            :get_vm_boot_order, :set_vm_boot_order)
      server = bootdisk_ride_check!(vm_id)
      root = bootdisk_storage_root!(storage_id, 'iso_attach', 'attached', storage_roots)
      node = reading_node(server)

      drives = dvd_drive_list(client.get_vm_dvd_drive(vm_id: vm_id, computer_name: node))
      drive = drives.first || client.add_vm_dvd_drive(vm_id: vm_id, computer_name: node)
      drive_id = drive.is_a?(Hash) ? drive['id'] || drive[:id] : drive
      if drive_id.blank?
        raise ForemanHyperv::OperationRefused,
              'The boot disk cannot be attached: the host answered no DVD-drive id. Nothing was changed.'
      end
      client.set_vm_dvd_drive(id: drive_id, vm_id: vm_id, computer_name: node,
                              path: bootdisk_host_path(root, name))
      boot = boot_order_with_dvd_first(drive_id, client.get_vm_boot_order(vm_id: vm_id, computer_name: node))
      client.set_vm_boot_order(vm_id: vm_id, order: boot, computer_name: node)
      true
    end

    # foreman_bootdisk after_build prio 52 (Orchestration::Compute#built):
    # eject the media, and ALWAYS answer true (round 17, finding 3). The
    # answer runs inside the /unattended/built save, and core fails the whole
    # save on a falsy step answer (evidence/core-orchestration.rb:149) — which
    # would leave the host in build mode with a live token forever. Detach
    # runs for EVERY build, bootdisk or not, and "nothing to do" is its normal
    # answer; a host refusal too is logged, never raised. The machine read is
    # best-effort: whatever node fog's fallback can reach gets the eject.
    def iso_detach(vm_id)
      raise ArgumentError, 'iso_detach requires a virtual machine id' if vm_id.blank?

      begin
        refuse_without_enablement!
        require_fog_requests!(:get_vm_dvd_drive, :eject_vm_dvd_drive)
        server = find_vm_by_uuid(vm_id)
        node = reading_node(server)
        drives = dvd_drive_list(client.get_vm_dvd_drive(vm_id: vm_id, computer_name: node))
        loaded = drives.select { |drive| drive.is_a?(Hash) && (drive['path'] || drive[:path]).present? }
        if loaded.empty?
          logger.debug "Hyperv #{name}: bootdisk iso_detach: no drive holds media for #{vm_id}, nothing to eject"
        else
          loaded.each do |drive|
            drive_id = drive['id'] || drive[:id]
            next if drive_id.blank?

            path = drive['path'] || drive[:path]
            begin
              client.eject_vm_dvd_drive(id: drive_id, vm_id: vm_id, computer_name: node)
              logger.info "Hyperv #{name}: bootdisk iso_detach ejected #{path} from #{vm_id}"
            rescue StandardError => e
              logger.warn "Hyperv #{name}: bootdisk iso_detach could not eject #{path} from #{vm_id} " \
                          "(#{e.message}); the machine stays as it is and the build proceeds"
            end
          end
        end
      rescue StandardError => e
        logger.warn "Hyperv #{name}: bootdisk iso_detach for #{vm_id} refused (#{e.message}); the build proceeds"
      end
      true
    end

    # foreman_bootdisk after_build prio 53 (Orchestration::Compute#built):
    # delete the transferred ISO, and ALWAYS answer true — same built-save
    # arithmetic as detach, and worse here: delete runs AFTER detach already
    # ejected, so the path cannot be read from the drive any more and the step
    # sweeps the host-reported roots for the basename instead. A raise would
    # make every later built retry fail at detach with nothing left to eject,
    # wedging the machine in build mode forever. Absence is the common answer
    # (every non-bootdisk build sweeps nothing), so each root answers quietly
    # and only a real host error is logged.
    def iso_delete(isofile, vm_id)
      name = bootdisk_filename!(isofile.nil? ? nil : File.basename(isofile.to_s), 'iso_delete')
      raise ArgumentError, 'iso_delete requires a virtual machine id' if vm_id.blank?

      begin
        refuse_without_enablement!
        require_fog_requests!(:remove_file)
        unless bootdisk_contained_file_removal_supported?
          logger.warn "Hyperv #{name}: bootdisk iso_delete: this fog partner cannot scope a delete, " \
                      'the transferred file is left in place and the build proceeds'
          return true
        end
        roots = storage_roots
        if roots.blank?
          logger.warn "Hyperv #{name}: bootdisk iso_delete: #{BOOTDISK_NO_ROOTS_WARNING}"
          return true
        end
        roots.each do |root|
          path = bootdisk_host_path(root, name)
          begin
            removed = client.remove_file(path: path, root: root)
            if removed
              logger.info "Hyperv #{name}: bootdisk iso_delete removed #{path}"
            else
              logger.debug "Hyperv #{name}: bootdisk iso_delete: #{path} was not there"
            end
          rescue StandardError => e
            logger.warn "Hyperv #{name}: bootdisk iso_delete could not sweep #{path} (#{e.message}); " \
                        'the remaining roots are swept anyway'
          end
        end
      rescue StandardError => e
        logger.warn "Hyperv #{name}: bootdisk iso_delete for #{name} failed (#{e.message}); the build proceeds"
      end
      true
    end

    # Hyper-V has no zones — the word names another provider's layout (core aliases
    # it to EC2 availability zones) — and core's base raises "Not implemented for
    # Hyper-V", which the API serves as a 500 for a question whose honest answer is
    # that there are none. Same reasoning as available_storage_domains above. The
    # other endpoints core leaves unimplemented (folders, resource pools, storage
    # pods, flavors, security groups) are left as they are: nothing on the Hyper-V
    # path asks them, and each deserves its own answer rather than a blanket [].
    def available_zones
      []
    end

    def new_vm(attr = {})
      # Before super: core's new_vm mass-assigns this whole hash onto the fog
      # model, and the fog_extensions cluster_name= setter asks the host during
      # assignment. Nothing of the user's has reached fog by the time these two
      # lines finish, and nothing hostile gets past them.
      ForemanHyperv::InputValidation.validate_hash!(attr, context: :vm)
      validate_placement!(attr)
      apply_firmware_attributes(attr)
      attr.delete :id

      # logger.debug "New VM with arguments;\n#{attr}"
      vm = super
      iface_nested_attrs = nested_attributes_for :interfaces, attr[:interfaces_attributes]
      vm.network_adapters = iface_nested_attrs.map do |attr|
        attr.delete :id
        Fog::Hyperv::Compute::NetworkAdapter.new(service: vm.service, vm: vm).tap do |nic|
          attr.select { |_, v| v.present? }.each do |k, v|
            nic.send(:"#{k}=", v)
          end
        end
      end
      volume_nested_attrs = nested_attributes_for :volumes, attr[:volumes_attributes]
      vm.hard_drives = volume_nested_attrs.map do |attr|
        attr.delete :id
        Fog::Hyperv::Compute::HardDrive.new(service: vm.service, vm: vm).tap do |hdd|
          attr.select { |_, v| v.present? }.each do |k, v|
            hdd.send(:"#{k}=", v)
          end
        end
      end
      vm.id = nil
      vm
    end

    def create_vm(attr = {})
      # PLG-15's first act survives PLG-15b's unlock: input validation runs
      # before anything else, so a hostile hash hears about the string, not
      # just about the refusal.
      ForemanHyperv::InputValidation.validate_hash!(attr, context: :vm)
      attr = attr.to_hash.deep_symbolize_keys if attr.respond_to?(:to_hash)

      # PLG-15b opened creates for stand-alone machines; PLG-22 enables the
      # cluster create path — with the era rule the destroy path uses too:
      # a fog that does not answer the six behaviours gets the pre-enablement
      # refusals verbatim (the cluster ask refused before any read of the
      # endpoint, the stand-alone gate refusing on every unknown), and only
      # the enablement's partner fog runs the unlocked path below.
      unless enablement_supported?
        raise ForemanHyperv::OperationRefused, CLUSTER_CREATE_REFUSAL if attr[:cluster_name].present?
        raise ForemanHyperv::OperationRefused, STANDALONE_CREATE_REFUSAL unless create_allowed?
      end

      attr = vm_instance_defaults.merge(attr)
      attr.delete :computer_name if attr[:computer_name].blank?
      start = Foreman::Cast.to_bool(attr.delete(:start))

      apply_firmware_attributes(attr)

      validate_vm(attr, new: true)
      validate_interfaces(attr)
      validate_volumes(attr)

      # PLG-30: the failback checkbox is decided before the machine exists. A
      # setting the cluster cannot hold — asked for with no cluster, with the
      # role explicitly opted out, or against a fog that never promised the
      # failback contract — hears a named refusal now, on a create that has
      # touched nothing, rather than watching the plugin quietly build a
      # machine that never got the HA setting it was ordered with.
      auto_failback = Foreman::Cast.to_bool(attr[:auto_failback])
      if auto_failback && (attr[:cluster_name].blank? || !clusterize?(attr))
        raise ForemanHyperv::OperationRefused, FAILBACK_NO_ROLE_REFUSAL
      end
      raise ForemanHyperv::OperationRefused, FAILBACK_FOG_REFUSAL if auto_failback && !cluster_failback_supported?

      # The enabled era's membership rule: every placement string the form
      # carries (computer_name, cluster_name, per-volume datastore) must be a
      # member of what the hypervisor itself reports — the character allowlist
      # ran first (validate_hash! above), the membership reads are unfiltered,
      # and a read that does not answer refuses the create. The pre-enablement
      # era needs none of this on the create path: its gate already refused
      # anything the endpoint read as clustered, and the self-rung check below
      # decides its one allowed target.
      validate_placement!(attr) if enablement_supported?

      # logger.debug "Creating VM with arguments; #{attr}"
      cluster = cluster_named(attr[:cluster_name])
      storage = placement_storage(cluster, attr)

      # PLG-14: a chosen storage that answers no mount path refuses the create
      # outright. The pre-PLG-14 code GUESSED twice here — `storage&.id ||
      # hypervisor.virtual_machine_path` put a clustered machine's config on
      # the node's local disk, and the placement folder join named the disk
      # folder relatively (C:\<name>) — and both guesses put files where
      # the cluster cannot follow them. The stand-alone case (no storage at
      # all) keeps its honest fallback below, untouched.
      if storage && storage.id.to_s.strip.empty?
        raise ForemanHyperv::OperationRefused, format(STORAGE_BLANK_PATH_REFUSAL, volume: storage.name)
      end

      # The identity ladder (N6), decided before the model is built so the
      # model rides the RIGHT client: the self rung serves through this
      # resource's own client; a named node reaches its SEPARATE per-node
      # client through the operator override (PLG-5a — the operator's own
      # assertion, validated at save) or through the address the cluster
      # itself gives the node (PLG-5b — the (w) MSI read, client-role pick
      # rule), with that identity spliced into the model's computer name
      # (N4). A named node neither overridden nor discoverable is per-node
      # addressing with nothing to dial, and the refusal names it — the same
      # fail-closed the reads use. In the pre-enablement era the named target
      # had nowhere to go anyway, and the self-rung check below answers
      # exactly as it did before.
      build_client = client
      computer = attr[:computer_name].presence
      routed_via_node = false
      if enablement_supported? && computer && !self_rung_name?(computer)
        override = node_override(computer)
        computer = override.split(':', 2).first if override
        computer = discover_node_address(computer) if override.nil?
        build_client = client_for_node(attr[:computer_name])
        routed_via_node = true
      end

      # PLG-16: the placement folder rides the model through fog's own
      # declared attribute, named BEFORE the machine is built. FOG-17 made fog
      # the one place that composes a machine's disk folder — an absolute
      # placement folder replaces the node's disk root outright, and every
      # shape that used to answer a relative join is refused there by name,
      # not joined. The value is the placed volume's mount folder plus a
      # folder named for the machine: a clustered machine's VHDXs have to sit
      # where every node can reach them. nil — the stand-alone case — names no
      # placement and leaves fog's host-root default in charge (likewise
      # refused rather than joined when the host answers no root).
      placement_path = [storage.id, attr[:name]].join('\\') if storage

      vm = build_client.servers.new(
        name: attr[:name],
        computer_name: computer || hypervisor.name,
        placement_path: placement_path,
        generation: attr[:generation],
        dynamic_memory_enabled: Foreman::Cast.to_bool(attr[:dynamic_memory_enabled]),
        memory_startup: attr[:memory_startup].to_i,
        memory_minimum: attr[:memory_minimum].to_i,
        memory_maximum: attr[:memory_maximum].to_i,
        processor_count: attr[:processor_count].to_i,
        notes: attr[:notes]
      )
      # N6 self rung: a machine built through this resource's own client has
      # to carry the name the endpoint gives itself (Get-VMHost), compared
      # case-insensitively — a node-routed machine is the one exception the
      # ladder allows, its identity an assertion the ladder already checked:
      # the operator's (validated at save) or the cluster's own network read
      # (PLG-5b), dialled through the node's own client. servers.new has
      # built a model and sent nothing, so this raise tears nothing down.
      raise ForemanHyperv::OperationRefused, SELF_RUNG_REFUSAL unless routed_via_node || self_rung?(vm)

      vm.create(
        # TODO: should be :VHD if image build - when image build support exists
        boot_device: attr[:boot_device].present? ? attr[:boot_device].to_sym : :NetworkAdapter,
        path: storage&.id || hypervisor.virtual_machine_path
      )
      # The host's New-VM answer merges back over the model with every
      # return field — and placement is not something a host knows: it
      # answers the placement an EMPTY STRING, which erases the one named at
      # construction (measured: at disk-build time the live model answered
      # placement "" and the disk took the host's own disk root — empty is
      # fog's own "no placement", so the refused join never saw the folder).
      # The placement is therefore re-asserted, unconditionally, through
      # fog's declared writer while the machine's disks are still to be
      # built; vm.vhds is bound to this exact model, so fog's refused join
      # (FOG-17) composes the disk folder from it.
      vm.placement_path = placement_path if placement_path

      if vm.generation == :UEFI
        vm.secure_boot_enabled = attr[:secure_boot_enabled]
        if attr[:tpm_enabled] == '1'
          security = vm.security
          security.change_key_protector :new
          security.tpm_enabled = true
          security.save
        end
      end

      create_interfaces(vm, attr)
      create_volumes(vm, attr)

      # The role goes on last, once the machine and its disks are where every node
      # can reach them — Add-ClusterVirtualMachineRole will not take a machine whose
      # storage is on a local path. It runs while the machine is off, which it still
      # is at this point, and before the start below.
      #
      # A machine placed into a cluster is clustered by default: on shared storage
      # with no role it fails over as nothing at all, and leaving that out should be
      # the explicit choice (an HA checkbox per VM is the plan for the form; until
      # it exists, ha_enabled answers "no" and nothing else does).
      if cluster && clusterize?(attr)
        # PLG-21a: the Add's own exception proves nothing once it has been sent,
        # so success is proven here by reading the role back, and anything short
        # of finding it raises StrandIndeterminate — which the rescue below
        # answers by touching nothing. role_added stays false until the readback
        # has actually found the role.
        #
        # PLG-27: the Add runs on the client the machine was BUILT on, at the
        # identity the ladder resolved for it. vm.computer_name is not safe on
        # a node-routed machine: the host's create answer merges back over the
        # model, and its ComputerName field is the node's own name (measured:
        # "HV-NODE2"). Fog's host set registers each client's endpoint and the
        # names discovered FOR THAT ENDPOINT — so the owning node's name lives
        # in the per-node client's set and never in the endpoint's, and the
        # endpoint client refused the Add before the cmdlet ran. The self rung
        # keeps the model's name verbatim: the check above proved it is the
        # name the endpoint gives itself, and fog registers that for it.
        role_target = routed_via_node ? computer : vm.computer_name
        role_added = add_cluster_role_proven(vm, service: build_client, target: role_target)

        # PLG-30: the failback the form asked for rides the client the machine
        # was built on at the identity the ladder resolved — the same routing
        # rule the Add above obeys, because this is the same class of cluster
        # write against the same owner. It runs only after the add has been
        # PROVEN (an unproven add strands above and never reaches here), and a
        # cluster that refuses the setting raises through the rollback below:
        # the role this strand provably added comes off and the machine goes
        # with it, rather than half-shipping a machine ordered with a HA
        # setting it does not have. fog's request answers true only when its
        # own read-back proved the write; anything else is an exception.
        if auto_failback
          build_client.set_cluster_virtual_machine_role_auto_failback(
            id: vm.id, auto_failback: true, computer_name: role_target
          )
        end
      end

      # PLG-28: hand the machine core holds (setComputeDetails reads THIS object
      # back to assign MACs) the endpoint's switch-name translation. The NIC
      # records carry the endpoint's GUID for the switch the form offered; the
      # queried adapter of a node-routed machine answers the node's own GUID for
      # the same switch, and only the endpoint's listing proves the two are one
      # name. The lambda reads that listing lazily (it is cached) and answers
      # only what the endpoint itself reports — an unknown GUID stays unresolved.
      vm.switch_name_resolver = lambda do |guid|
        next if guid.blank?

        switches(nil).detect { |sw| sw.id.to_s.casecmp?(guid.to_s) }&.name
      end

      vm.start if start
      vm
    rescue StrandIndeterminate
      # Neither success nor failure is established: the machine may already be a
      # cluster-owned role (stop and disk deletes then fight the cluster over
      # the files — TEST-RESULTS finding 22) or may never have reached it. Every
      # teardown would be a guess, so there is none. The strand record went out
      # with the exception's own raise.
      logger.warn 'Cluster role add ended indeterminate: the virtual machine, its disks and any role ' \
                  "at #{strand_param(vm&.path)} were left untouched"
      raise
    rescue StandardError
      if vm&.persisted?
        # The rollback stays what PLG-15b made it for the drives: DETACHED,
        # not deleted — a strand's disk files may include a pre-existing disk
        # the form attached, and no rollback may destroy a file it did not
        # prove this strand created. The machine's own folder is the one piece
        # a post-enablement rollback CAN decide (the two-root rule plus its
        # pre-flight below), and it decides it only with the survivor rule:
        # any disk file still living inside the folder keeps the folder,
        # because the folder delete recurses and a silent attach-disk loss is
        # exactly what the rule exists to stop. The pre-enablement era keeps
        # the literal false it shipped with. remove_cluster_role is live now:
        # the enabled cluster create path reaches this rollback with a role
        # the strand provably added.
        remove_cluster_role(vm) if role_added
        vm.stop
        vm.hard_drives.each { |hdd| hdd.destroy(underlying: false) }
        vm.destroy(enablement_supported? && rollback_folder_delete?(vm))
      end

      raise
    end

    def save_vm(uuid, web_attr)
      ForemanHyperv::InputValidation.validate_id!(uuid)
      attr = web_attr.deep_symbolize_keys
      ForemanHyperv::InputValidation.validate_hash!(attr, context: :vm)
      # Disk removals are refused everywhere this version runs, checked on the
      # submitted form before anything is fetched: the fog call that answers
      # hard_drives.get(id) interpolates the id, and the destroy behind it is
      # the Remove-Item path the wildcard campaign measured.
      refuse_disk_removal!(attr)
      # Placement strings the edit form round-trips (computer_name, cluster_name
      # and per-volume datastore) must still be members of what the hypervisor
      # reports, character allowlist first, membership read unfiltered.
      validate_placement!(attr)
      attr.delete :start

      validate_vm(attr)
      validate_interfaces(attr)
      validate_volumes(attr)

      vm = find_vm_by_uuid(uuid)
      # logger.debug "Updating VM #{vm} with arguments; #{attr}"

      vm.processor_count = attr[:processor_count].to_i
      vm.notes = attr[:notes].presence
      vm.dynamic_memory_enabled = Foreman::Cast.to_bool(attr[:dynamic_memory_enabled])
      if vm.dynamic_memory_enabled
        vm.memory_minimum = attr[:memory_minimum].to_i
        vm.memory_maximum = attr[:memory_maximum].to_i
      end
      if vm.generation == :UEFI && attr[:tpm_enabled].present?
        security = vm.security
        security.tpm_enabled = attr[:tpm_enabled] == '1'
        security.change_key_protector :new if security.tpm_enabled && security.key_protector.nil?
        security.save
      end
      if attr[:foreman_firmware].present?
        # The generation of an existing VM can not be changed, only its secure boot setting
        apply_firmware_attributes(attr, set_generation: false)
        vm.secure_boot_enabled = attr[:secure_boot_enabled]
      end

      update_interfaces(vm, attr)
      update_volumes(vm, attr)
      vm.save if vm.dirty?
      # PLG-36: the Preferred owners list the edit form submitted, applied
      # after the machine's own save and with its own honest silences and
      # refusals (see apply_preferred_owners). It rides AFTER vm.save so a
      # refused setting fails the save carrying the cluster's words, never
      # leaving the CPU/memory edit half-written on the machine.
      apply_preferred_owners(vm, attr[:preferred_owners]) if attr.key?(:preferred_owners)
      vm
    end

    # Core's find_vm_by_uuid asks the endpoint for the machine, and Get-VM answers
    # for the machines registered on the machine it ran on and nothing else. That is
    # enough on a stand-alone host; on a cluster it goes stale the moment a role
    # moves — the machine is the same GUID, it is just on another node now, and the
    # endpoint can no longer see it. Every action on a machine starts with this
    # lookup, so when the endpoint's answer fails, ask the cluster which node owns
    # the machine and ask that node. Whatever the endpoint says stands.
    def find_vm_by_uuid(uuid)
      # The URL VM id is a view-permission surface, and fog's Servers#get sends
      # any non-GUID identifier down its name path — straight into the builder
      # sink. GUID-only, before super, before the cluster-owner lookup.
      ForemanHyperv::InputValidation.validate_id!(uuid)
      super
    rescue ActiveRecord::RecordNotFound, Fog::Errors::NotFound, Fog::Hyperv::Errors::PSError => e
      vm = vm_from_cluster_owner(uuid)
      raise e unless vm

      vm
    end

    def destroy_vm(uuid)
      # PLG-15c opened destroy for proven-stand-alone machines; PLG-22
      # enables it. The lookup still comes first (the gate and the teardown
      # decide on the machine fog reported), the id is still validated before
      # anything else, and a fog that answers no machine at all is still the
      # same nothing the rescue answers "done" for.
      ForemanHyperv::InputValidation.validate_id!(uuid)
      vm = find_vm_by_uuid(uuid)
      return true if vm.nil?

      unless enablement_supported?
        # The pre-enablement gate, verbatim: a fog that does not answer the
        # six behaviours gets the refusals this plugin shipped with, word for
        # word — enablement is a property of the fog+plugin pair, and the
        # plugin does not run a decision its partner cannot keep.
        case standalone_destroy_state(vm)
        when :standalone
          nil
        when :clustered
          raise ForemanHyperv::OperationRefused, DESTROY_REFUSAL
        when :not_self
          raise ForemanHyperv::OperationRefused, DESTROY_SELF_RUNG_REFUSAL
        else
          raise ForemanHyperv::OperationRefused, STANDALONE_DESTROY_REFUSAL
        end
        vm.stop turn_off: true
        vm.hard_drives.each { |hdd| hdd.destroy(underlying: false) }
        vm.destroy(false)
        return true
      end

      # The enabled era. The classification reads are still made — they record
      # sightings and they still refuse an unknown — but a clustered answer is
      # now a shape, not a refusal: the machine is un-clustered first, then
      # deleted. Everything decidable is decided BEFORE anything is mutated:
      # the folder verdict (one pre-flight script, fog's literal-path guard on
      # fog's side) and each drive's file verdict (call-site attribution plus
      # the model's own sharing read), so a destroy whose decisions could not
      # be read keeps exactly the pieces it could not decide, not a
      # half-torn-down machine guessing the rest.
      state = standalone_destroy_state(vm)
      raise ForemanHyperv::OperationRefused, DESTROY_INDETERMINATE_REFUSAL if state == :indeterminate
      # The enablement unlocks CLUSTERED machines; a stand-alone-proven
      # endpoint wearing someone else's machine name is still per-node
      # addressing, and that stays PLG-5b's, refusing with the same sentence
      # as before: an enabled plugin does not stretch further than its own
      # reviewed unlocks.
      raise ForemanHyperv::OperationRefused, DESTROY_SELF_RUNG_REFUSAL if state == :not_self

      machine_folder = folder_deletion_path(vm)
      folder_delete = !machine_folder.nil? && folder_preflight(vm, machine_folder) == :ok
      drive_deletes = []
      vm.hard_drives.each do |hdd|
        delete_file = drive_deletion_allowed?(vm, hdd)
        if !delete_file && file_lives_in?(hdd, machine_folder)
          # The folder delete recurses. A file this destroy refused to delete
          # must not be taken by the recursion it inherits — that is the same
          # silent wrong-thing in a new costume — so a kept file inside the
          # machine's folder keeps the folder too.
          logger.warn "The disk file #{hdd.path} of #{vm.name} stays, and its folder with it: " \
                      'a folder delete that recurses over a file this destroy refused is not a verdict'
          folder_delete = false
        end
        drive_deletes << [hdd, delete_file]
      end

      vm.stop turn_off: true
      # The role only when the machine reports one: fog's removal asserts a
      # matching role before it deletes anything, and a machine the cluster
      # does not hold has nothing to release. A cluster that will not give the
      # role up stops the destroy here — before the machine or a file goes.
      remove_cluster_role(vm) if vm.respond_to?(:clustered?) && vm.clustered?
      drive_deletes.each { |hdd, delete_file| hdd.destroy(underlying: delete_file) }
      vm.destroy(folder_delete)
      true
    rescue ActiveRecord::RecordNotFound, Fog::Errors::NotFound
      # if the VM does not exists, we don't really care.
      true
    end

    def update_required?(old_attrs, new_attrs)
      new_attrs.deep_symbolize_keys[:volumes_attributes]&.each_value do |hdd|
        if hdd[:id].present? && hdd[:_delete] == '1'
          Rails.logger.debug 'Scheduling compute instance update because a volume was removed'
          return true
        elsif hdd[:id].blank? && hdd[:_delete] != '1'
          Rails.logger.debug 'Scheduling compute instance update because a new volume was added'
          return true
        end
      end
      new_attrs.deep_symbolize_keys[:interfaces_attributes]&.each_value do |iface|
        if iface[:id].present? && iface[:_destroy] == '1'
          Rails.logger.debug 'Scheduling compute instance update because an interface was removed'
          return true
        elsif iface[:id].blank? && iface[:_destroy] != '1'
          Rails.logger.debug 'Scheduling compute instance update because a new interface was added'
          return true
        end
      end

      deep_update_required = proc do |path, old, new|
        old.merge(new) do |k, old_v, new_v|
          k_path = path + [k]
          if %i[allowed_vlan_ids secondary_vlan_ids].include?(k)
            tmp = Fog::Hyperv::Compute::NetworkAdapter.new

            old_v = Fog::Hyperv::Compute::NetworkAdapterVlan.render_vlan_list(tmp.send(:parse_vlan_list, old_v.to_s))
            new_v = Fog::Hyperv::Compute::NetworkAdapterVlan.render_vlan_list(tmp.send(:parse_vlan_list, new_v.to_s))
          end

          if old_v.is_a?(Hash) && new_v.is_a?(Hash)
            deep_update_required.call(k_path, old_v, new_v)
          elsif old_v.to_s != new_v.to_s
            Rails.logger.debug do
              "Scheduling compute instance update because #{k_path.join('.')} " \
                "changed it's value from '#{old_v}' (#{old_v.class}) " \
                "to '#{new_v}' (#{new_v.class})"
            end
            return true
          end
          new_v
        end
      end
      deep_update_required.call([], old_attrs.deep_symbolize_keys, new_attrs.deep_symbolize_keys)

      false
    end

    # def console(uuid)
    #   vm = find_vm_by_uuid(uuid)
    #
    #   {
    #     type: 'rdp',
    #     host: vm.computer.fully_qualified_domain_name,
    #   }
    # end

    def new_interface(attr = {})
      ForemanHyperv::InputValidation.validate_hash!(attr, context: :nic)
      Fog::Hyperv::Compute::NetworkAdapter.new attr
    end

    def new_volume(attr = {})
      ForemanHyperv::InputValidation.validate_hash!(attr, context: :hdd)
      basename = attr.delete(:basename) { 'Disk' }
      size = attr.delete(:size)

      vhd = client.vhds.new({ basename: basename, size: size }.compact)
      Fog::Hyperv::Compute::HardDrive.new vhd: vhd, **attr
    end

    # No caller in this plugin, and the fog model's mass-assign is raw, so this
    # is validated rather than deleted: a core form or API surface that grows a
    # cdrom path today would otherwise walk straight past every guard the other
    # seven sites have.
    def new_cdrom(attr = {})
      ForemanHyperv::InputValidation.validate_hash!(attr, context: :dvd)
      Fog::Hyperv::Compute::DvdDrive.new attr
    end

    def vm_instance_defaults
      super.merge(
        generation: 2,
        memory_startup: 1024.megabytes,
        processor_count: 1,
        interfaces: [new_interface]
      )
    end

    def vm_compute_attributes(vm)
      attr = super.slice(
        :computer_name, :name, :generation,
        :dynamic_memory_enabled,
        :memory_maximum, :memory_minimum, :memory_startup,
        :notes, :processor_count
      )
      attr[:foreman_firmware] = vm.foreman_firmware_type
      attr[:tpm_enabled] = vm.tpm_enabled
      # PLG-36: the current preferred-owners list, when the control could be
      # honestly offered (see cluster_preferred_owners_for for the refuses).
      # This is what makes core's change-detect SEE an owners-only edit at
      # all: it compares this fresh read against the submitted form, and a
      # key missing here on both sides round-trips as "not submitted".
      owners = cluster_preferred_owners_for(vm)
      attr[:preferred_owners] = owners if owners

      attr
    end

    def set_vm_volumes_attributes(vm, vm_attrs)
      volumes = vm.hard_drives || []
      vm_attrs[:volumes_attributes] = volumes.each_with_index.to_h do |volume, index|
        [index.to_s, volume.compute_attributes]
      end
      vm_attrs
    end

    def set_vm_interfaces_attributes(vm, vm_attrs)
      interfaces = vm.interfaces || []
      vm_attrs[:interfaces_attributes] = interfaces.each_with_index.to_h do |interface, index|
        interface_attrs = {
          mac: interface.mac,
          compute_attributes: interface.compute_attributes
        }
        [index.to_s, interface_attrs]
      end
      vm_attrs
    end

    # PLG-29a: the registration verdict for one listed machine.
    #
    # The instance list printed only vm.computer_name, which is the node that
    # ANSWERED the read: a clustered machine's owner is whichever node holds it
    # now, and a machine the cluster released without deleting it looks, on that
    # list, exactly like a healthy one (evidence §58: the operator released a
    # machine through Failover Cluster Manager and the row kept reading as a
    # machine that belonged there). The cluster's own role listing answers the
    # question for every machine on the page in one read, so the column joins
    # against that.
    #
    # This is a display verdict only. No destroy or disk path reads it — the
    # destructive gates keep their own fresh, per-machine role proof, because
    # "no role" is the answer that licenses removing disks and one page render's
    # memory of the cluster is not a basis for deleting them.
    Registration = Struct.new(:state, :owner_node, :cluster_name, :auto_failback, keyword_init: true) do
      # The two states an operator acts on: the release-without-delete (delete
      # it), and the answer too degraded to trust (verify before deleting).
      def warning?
        %i[clustered_storage_without_role unknown].include?(state)
      end

      def label
        case state
        when :clustered
          # PLG-30: the failback word rides only when the cluster REPORTED it —
          # on a fog without the contract, or a role whose property never
          # arrived, the row is the exact pre-PLG-30 text. nil is not "off",
          # and a column that operators trust never prints a claim it did
          # not read.
          parts = ['Clustered', cluster_name.presence, owner_node.presence && "owner #{owner_node}"]
          parts << "automatic failback #{auto_failback ? 'on' : 'off'}" unless auto_failback.nil?
          parts.compact.join(' — ')
        when :clustered_storage_without_role then 'Cluster storage, no cluster role'
        when :standalone then "Stand-alone on #{owner_node}"
        when :standalone_no_cluster then 'Stand-alone'
        else 'Unknown'
        end
      end
    end

    # See Registration. Public because the instance table calls it with the
    # compute resource as receiver. A machine with no id is answered :unknown
    # rather than name-matched: the name join exists for a role whose
    # undocumented id field came back empty, not for a machine the page cannot
    # key, and a column that tells an operator what is safe to delete earns
    # trust by never guessing. A cluster that raises, and a fog that cannot be
    # asked at all, are likewise :unknown — never stand-alone verdicts, which is
    # where a stale "no role" would invite deleting a clustered machine's disks.
    def vm_registration(vm)
      return Registration.new(state: :unknown) if vm.id.blank?

      roles = cluster_role_index
      return Registration.new(state: :unknown) if roles.nil? || roles == :unsupported
      return Registration.new(state: :standalone_no_cluster, owner_node: reading_node(vm)) if roles == :not_a_cluster

      role = roles[vm.id.to_s.downcase] || roles["#{ROLE_NAME_PREFIX}#{vm.name}"]
      if role
        # PLG-30: the failback word is asked of the role only when the fog
        # answers the failback contract AND this role model actually carries
        # the field; either absence answers nil, which the label renders as
        # silence — never as off. This stays a display join: nothing on the
        # destructive side reads it.
        reported = cluster_failback_supported? && role.respond_to?(:auto_failback)
        failback = reported ? role.auto_failback : nil
        return Registration.new(state: :clustered, owner_node: role.owner_node,
                                cluster_name: endpoint_cluster&.name, auto_failback: failback)
      end

      if vm.path.to_s.include?('\\ClusterStorage\\')
        Registration.new(state: :clustered_storage_without_role, owner_node: reading_node(vm))
      else
        Registration.new(state: :standalone, owner_node: reading_node(vm))
      end
    end

    # PLG-31: what the cluster will DO about a machine — failover priority,
    # automatic failback, the failback window — for the VM detail page. The
    # values ride the role objects the Registration column already joins
    # against, so the section costs the page no round trip the listing does
    # not already pay. PLG-31b adds the fourth row: the cluster's PREFERRED
    # OWNERS for this role, which the same role read now carries.
    #
    # Display honesty, the rules the labels enforce: a documented number is
    # shown as its documented word WITH the raw value the cluster actually
    # answered; an undocumented number is shown raw, never mapped by guess;
    # an attribute the cluster never sent is Unknown; and a fog without the
    # contract says NOTHING — the PLG-30 silence rule, because "Off" (or
    # "Any node") is a claim the read never made. The maps and the window
    # sentinel are grounded against the live cluster (§74), not folklore, and
    # the owner row's three states — names, the unset [], and a failed read —
    # are three different claims measured on HV-CL01 (§76), kept that far
    # apart here. Nothing destructive reads any of this: the knobs are
    # changed in Failover Cluster Manager until a failover-safe write path
    # exists.
    HASettings = Struct.new(:state, :priority, :auto_failback_type, :failback_window_start, :failback_window_end,
                            :preferred_node_names,
                            keyword_init: true) do
      def found?
        state == :found
      end

      def priority_label
        return nil unless found?

        case priority
        when nil then 'Unknown'
        when 0 then 'None (0)'
        when 1_000 then 'Low (1000)'
        when 2_000 then 'Medium (2000)'
        when 3_000 then 'High (3000)'
        else priority.to_s
        end
      end

      def auto_failback_label
        return nil unless found?
        return nil if auto_failback_type == :unreported

        case auto_failback_type
        when nil then 'Unknown'
        when 0 then 'Off (0)'
        when 1 then 'On (1)'
        when 2 then 'On, in failback window (2)'
        # fog's own rule for this property: 0 is off, any other value is
        # some flavour of on — so an unmapped nonzero says On, with its raw
        # value beside it for the operator to see the map did not know it.
        else "On (#{auto_failback_type})"
        end
      end

      def failback_window_label
        return nil unless found?
        return nil if failback_window_start == :unreported

        if failback_window_start.nil? || failback_window_end.nil?
          'Unknown'
        elsif failback_window_start == ForemanHyperv::Hyperv::FAILBACK_WINDOW_DISABLED ||
              failback_window_end == ForemanHyperv::Hyperv::FAILBACK_WINDOW_DISABLED
          'None'
        else
          # The sentinel's meaning is measured; the pair's UNIT is not —
          # so a real window renders exactly what the cluster said.
          "#{failback_window_start}\u2013#{failback_window_end} (raw cluster values)"
        end
      end

      # PLG-31b: the cluster's preferred owners for this role. The three
      # states HV-CL01 answers (§76) are three different claims, and the
      # label keeps them that far apart: a list of names is a restricted
      # preference and says the names; [] is the cluster's own POSITIVE "no
      # restricted list — any node may own" answer; and nil means this
      # group's owner read FAILED, which is Unknown — never "Any node",
      # because a read that failed cannot claim what the cluster prefers.
      # :unreported is the fourth state, the plugin's own: a fog without
      # the contract, and the row prints nothing (the PLG-30 silence rule).
      def preferred_owners_label
        return nil unless found?
        return nil if preferred_node_names == :unreported

        case preferred_node_names
        when nil then 'Unknown'
        when [] then 'Any node (no restriction)'
        else Array(preferred_node_names).join(', ') # join stringifies each name itself
        end
      end
    end

    # See HASettings. Public because the VM detail view calls it with the
    # compute resource as receiver, exactly like vm_registration. The lookups
    # and the index states are the Registration column's own: a machine with
    # no id, a machine the index does not carry, and a cluster that could not
    # answer (nil, :unsupported, :not_a_cluster) all answer :not_found, which
    # renders the section as silence. The failback trio and PLG-31b's owner
    # list are each gated on their fog contract; priority predates both
    # contracts and shows regardless.
    def cluster_ha_settings(vm)
      return HASettings.new(state: :not_found) if vm.id.blank?

      roles = cluster_role_index
      return HASettings.new(state: :not_found) if roles.nil? || roles == :unsupported || roles == :not_a_cluster

      role = roles[vm.id.to_s.downcase] || roles["#{ROLE_NAME_PREFIX}#{vm.name}"]
      return HASettings.new(state: :not_found) unless role

      attrs = role.respond_to?(:attributes) ? role.attributes : {}
      reported = cluster_failback_supported? && role.respond_to?(:auto_failback_type)
      # The owner list is a FIELD of the role read, not a request of its
      # own, so the second half of its gate is the role in hand: a fog whose
      # constant says yes but whose model cannot answer preferred_node_names
      # is a mismatched partner, and the row answers with silence.
      owner_reported = cluster_owner_nodes_supported? && role.respond_to?(:preferred_node_names)
      HASettings.new(state: :found,
                     priority: attrs[:priority],
                     auto_failback_type: reported ? attrs[:auto_failback_type] : :unreported,
                     failback_window_start: reported ? attrs[:failback_window_start] : :unreported,
                     failback_window_end: reported ? attrs[:failback_window_end] : :unreported,
                     preferred_node_names: owner_reported ? attrs[:preferred_node_names] : :unreported)
    end

    # PLG-36: set the machine's preferred owners — the nodes the cluster may
    # run it on — through fog's measured write (evidence §76: the cmdlet is
    # Set-ClusterOwnerNode -Owners and the write sticks; [] clears through the
    # one measured clear spelling). Every name is membership-checked against
    # the cluster's OWN node list first: a name this side cannot point at in
    # the cluster's answer has no business being dialled, and a node list that
    # cannot be read is unknown, not permission. Accepted names are replaced by
    # the cluster's own spelling of them, so the stored value, the read-back,
    # and the form's option list are the same strings (the cluster is measured
    # not to preserve case).
    #
    # computer_name is deliberately nil: preferred owners are pure cluster
    # state — any node's cluster service answers for the whole cluster, which
    # is how the role read already reaches machines owned by other nodes —
    # while a node-routed name on the endpoint client walks straight into the
    # PLG-27 trap (the endpoint's set never registered that name).
    #
    # fog answers true only when its own read-back proved the setting landed;
    # its refusals (RolePropertyWriteRefused carrying the cluster's words,
    # ClusterRoleNotFound for a machine with no role) are re-raised as the
    # plugin's own OperationRefused, unchanged in what they say, so every
    # caller — the edit save above all — fails on a refused setting rather
    # than half-applying an edit.
    def set_cluster_vm_preferred_owners(vm, owner_nodes)
      names = Array(owner_nodes).map { |node| node.to_s.strip }.reject(&:empty?)
      doubled = names.map(&:downcase).tally.select { |_node, count| count > 1 }.keys
      if doubled.any?
        raise ForemanHyperv::OperationRefused,
              "preferred owners name the same node more than once (#{doubled.join(', ')} matched " \
              'case-insensitively); the cluster keeps one entry per node, so list each node once'
      end

      # An empty list names no node, so membership has nothing to check —
      # and a node read that fails must not refuse the one state (§76) that
      # carries no names at all.
      canonical =
        if names.empty?
          []
        else
          nodes = cluster_node_names
          if nodes.nil?
            raise ForemanHyperv::OperationRefused,
                  'the cluster node list could not be read, so no owner name could be checked against it; ' \
                  'unknown nodes are not permission to write'
          end

          names.map do |node|
            nodes.find { |known| known.casecmp(node).zero? } ||
              raise(ForemanHyperv::OperationRefused,
                    "the cluster has no node named #{node}: preferred owners must be nodes this " \
                    'compute resource reports')
          end
        end

      client.set_cluster_virtual_machine_role_owner_nodes(id: vm.id, owner_nodes: canonical, computer_name: nil)
    rescue Fog::Hyperv::Errors::RolePropertyWriteRefused, Fog::Hyperv::Errors::ClusterRoleNotFound => e
      raise ForemanHyperv::OperationRefused, e.message.to_s
    end

    # PLG-36: the edit form's honest answer to "may I offer the Preferred
    # owners control, and with what selection". nil is the refuse — a
    # stand-alone endpoint (asked BEFORE any role read, the gate's own
    # answer), a fog whose write gate is closed, a machine the cluster
    # carries no role for, and an owner read that failed all render no
    # control, because each of them would offer a selection the form cannot
    # claim to show. The names come back SORTED: the option DOM order is what
    # the browser submits and what core's change-detect compares against the
    # fresh read, so both sides must be canonical without the cluster having
    # preserved anything (§76 measured it does not).
    def cluster_preferred_owners_for(vm)
      return nil unless cluster_endpoint? && cluster_owner_nodes_write_supported?

      ha = cluster_ha_settings(vm)
      return nil unless ha.found?

      names = ha.preferred_node_names
      return nil unless names.is_a?(Array)

      names.sort
    end

    # PLG-36: the cluster's node names, sorted for the edit form's options.
    # A list that cannot be read answers nil — the control offers nothing
    # rather than a guess, and the page does not die (the listing's own node
    # read degrades the same way).
    def cluster_node_names
      nodes = Array(client.cluster_nodes).map { |node| node.name.to_s.strip }.reject(&:empty?).sort
      nodes.presence
    rescue StandardError => e
      Rails.logger.warn "Hyper-V cluster node list for #{name} could not be read: " \
                        "#{e.class}: #{e.message.to_s.lines.first.to_s.strip}"
      nil
    end

    # PLG-29b: on a cluster, the instance list is the CLUSTER's inventory.
    # Core builds it from the endpoint's fog collection, and Get-VM answers
    # only for the machines registered on the node it ran on — a clustered
    # machine owned by another node was invisible to the page (evidence
    # §58/§59: the machine the PLG-28 acceptance created never appeared in
    # the list that was meant to clean it up). Actions already route per
    # machine through the cluster's owner answer (PLG-27); this gives the
    # listing the same reach. A stand-alone endpoint keeps the exact
    # pre-PLG-29b answer — the live fog collection, untouched.
    # PLG-33b: the first listing per request starts the pipeline — the probe,
    # the node list and the endpoint's rows run concurrently on their own
    # fresh clients, and this same request's gate and listing CONSUME them,
    # turning a page's sequential cold-hop SUM into its slowest single hop.
    # Everything else about this method is PLG-29b verbatim: a stand-alone
    # endpoint keeps the exact pre-PLG-29b answer — the live fog collection,
    # the speculative reads silently discarded.
    def vms(attrs = {})
      launch_listing_pipeline unless instance_variable_defined?(:@listing_pipeline)

      return client.servers(attrs) unless cluster_endpoint?

      ClusterNodeServers.new(self, pipeline: @listing_pipeline)
    end

    # PLG-34: one keepalive tick is exactly one page load's worth of endpoint
    # reads, answers dropped. It IS the public read path — the pipeline launch
    # inside vms, the gate, the per-node Get-VM ladder, the role index — so it
    # composes with PLG-33b (the tick's own speculative reads are consumed by
    # the tick's own listing, never double-dialled) and warms precisely the
    # hops a human pays: WSMan shell allocation, PowerShell startup, the
    # cluster cmdlets. A stand-alone tick is the endpoint branch only: the
    # gate's probe plus the fog collection read, no node list, no roles.
    # Hard failures RAISE to ForemanHyperv::Keepalive.tick_one, which is what
    # rescues and throttles them; the per-node fail-soft ladder stays inside
    # the listing, exactly as it does for a page. Called on a freshly loaded
    # instance every tick, so every memo here dies with its tick.
    def keepalive_tick
      rows = vms.all
      cluster_role_index if cluster_endpoint?
      rows.respond_to?(:size) ? rows.size : 0
    end

    protected

    # PLG-33b: start the speculative endpoint-side reads, once per resource
    # instance (one page load). A pipeline that cannot start is nil, and a nil
    # pipeline is today's sequential page, verbatim — no read is lost, only
    # the overlap is given up.
    #
    # PLG-33c: the block is the fourth hop's body — the cluster role listing,
    # which the pipeline starts on its own fresh client the moment the probe
    # answers CLUSTER. The role index built at render consumes that answer;
    # the page never dials a second probe or a second roles read for it.
    def launch_listing_pipeline
      @listing_pipeline = ListingPipeline.start(self) do |roles_client|
        pipelined_role_read(roles_client)
      end
    end

    def client
      @client ||= Fog::Compute.new(fog_client_options(url))
    end

    # The one place a fog client's wire options are composed (PLG-33b): the
    # endpoint client, the per-node routed clients and the pipeline's fresh
    # copies all get trust, the PLG-32 opt-out and the PLG-16 waits from here,
    # so a future wire option lands on every dial at once. The semantics that
    # used to sit at each site: the SAME trust the per-node compositions get —
    # over https these clients run the address read, the cluster reads and
    # test_connection against the very certificates hyperv_ca_trust_path
    # exists to verify (the revalidation row that caught the omission refused
    # with a bare SSLError before any composition decision was reached).
    # Absent the attribute, absent the option — the pre-PLG-5b build,
    # verbatim. PLG-32: the opt-out ONLY — a resource that never opted out
    # keeps the pre-PLG-32 wire byte-identical and fog's own verified default;
    # it reaches every client or Test Connection would contradict the
    # checkbox. The waits PLG-16 says on EVERY composed client — these are the
    # clients the stalled-cold-cmdlet finding is about.
    def fog_client_options(endpoint)
      options = {
        provider: :HyperV,
        hyperv_endpoint: endpoint,
        hyperv_username: user,
        hyperv_password: password
      }
      options[:hyperv_ca_trust_path] = hyperv_ca_trust_path if hyperv_ca_trust_path.present?
      options[:hyperv_ssl_verify] = false if hyperv_ssl_verify == false
      options[:hyperv_operation_timeout] = WINRM_OPERATION_TIMEOUT
      options[:hyperv_receive_timeout] = WINRM_RECEIVE_TIMEOUT
      options
    end

    private

    # PLG-15's refusal switchboard, opened one path at a time by reviewed PRs.
    # PLG-15b opens creates for stand-alone machines only; PLG-15c opens
    # destroys for stand-alone machines only (standalone_destroy_state below);
    # disk removals stay refused everywhere and every cluster path stays
    # locked behind the canonical enablement sentence the refusal messages
    # quote — those lifts belong to the enablement PR. Lifting a guard is a
    # merged PR whose gate those messages name, never a setting. They read as
    # predicates rather than bare raises so the code below each guard stays
    # live for the reader: it is the path that runs the day a guard flips,
    # not dead text.
    #
    # The stand-alone create gate (PLG-15b): arm (a) must answer not-clustered
    # on the endpoint, and BOTH configured markers must answer the not-found
    # exception — not-found-only, B2, concordant or not. Every unknown refuses:
    # a clustered reading, an unreadable classifier, a present marker, a
    # denied read, an unparsable token. The gate makes its reads again on
    # every create; there is nothing to configure.
    def create_allowed?
      case cluster_membership_state
      when :not_clustered
        nil
      when :clustered
        logger.warn 'Refusing to create a virtual machine: the endpoint answered a cluster membership row'
        return false
      else
        logger.warn 'Refusing to create a virtual machine: the cluster membership read did not answer'
        return false
      end

      MARKER_READS.each_key do |marker|
        state = marker_state(marker)
        next if state == :absent

        logger.warn "Refusing to create a virtual machine: the #{marker} marker read answered #{state}"
        return false
      end
      true
    end

    def disk_removal_allowed?
      enablement_supported?
    end

    # --- PLG-22: the enablement and its runtime check ---------------------------

    # Every behaviour the enablement stands on, asked of the fog actually
    # installed: the CAPABILITIES constant AND the predicate every client of
    # that build answers (a fog that has the list but not the behaviour, or
    # the behaviour but not the list, is not this build's partner). A fog too
    # old to even define CAPABILITIES answers "everything missing" — the
    # pre-enablement era, refusing exactly what it refused before enablement.
    # The whole check is a local constant read and six respond_to?/predicate
    # calls on the client object: no wire traffic, and it is safe to ask on
    # every operation.
    # @return [Boolean] does the installed fog answer all six?
    def enablement_supported?
      missing_enablement_capabilities.empty?
    end

    # The capabilities the installed fog does NOT answer, in the order of the
    # frozen list — empty means enablement stands. A predicate that raises is
    # an unanswered predicate, same as a missing one: the check asks the fog,
    # and an fog that cannot answer has not answered.
    # @return [Array<Symbol>] the missing behaviour names, for the refusal
    def missing_enablement_capabilities
      list = Fog::Hyperv.const_defined?(:CAPABILITIES) ? Fog::Hyperv::CAPABILITIES : []
      ENABLEMENT_CAPABILITIES.select do |capability, predicate|
        list.exclude?(capability) || !client_answers?(capability, predicate)
      end.keys
    rescue StandardError
      ENABLEMENT_CAPABILITIES.keys
    end

    def client_answers?(capability, predicate)
      client.respond_to?(predicate) && client.public_send(predicate) == true
    rescue StandardError => e
      logger.warn "The fog capability check for #{capability} did not answer: #{e.class}"
      false
    end

    # The refusal every unlocked operation answers with when the fog is not
    # the enablement's partner — one message, naming what is missing, quoting
    # no remote text (the names are this file's constants).
    def refuse_without_enablement!
      missing = missing_enablement_capabilities
      return if missing.empty?

      raise ForemanHyperv::OperationRefused, format(FOG_CAPABILITY_REFUSAL, missing: missing.join(', '))
    end

    # --- PLG-22: the two-root folder rule ---------------------------------------

    # The roots a machine's files may provably live under, from the endpoint's
    # own reports: the config root (virtual_machine_path), the disk root
    # (virtual_hard_disk_path — the two roots the folder rule must know both
    # of, measured ≠ on the lab host), and every shared volume of the cluster
    # the endpoint belongs to (a clustered machine's config folder lives on a
    # cluster shared volume, not on either node-local root). Nothing the user
    # typed is in this list; it is what the hypervisor itself named.
    #
    # A root that cannot be read is simply not a root: attribution against a
    # missing root fails closed (no delete), exactly as a missing shared-volume
    # listing leaves a clustered machine's folder unattributed.
    # @return [Array<String>] the normalized roots
    def storage_roots
      roots = []
      begin
        host = hypervisor
        roots << host.virtual_machine_path if host.respond_to?(:virtual_machine_path)
        roots << host.virtual_hard_disk_path if host.respond_to?(:virtual_hard_disk_path)
      rescue StandardError => e
        logger.warn "The endpoint could not name its storage roots for the delete decision: #{e.class}"
      end
      begin
        clusters.each do |cluster|
          next unless cluster.respond_to?(:shared_volumes)

          cluster.shared_volumes.each do |volume|
            roots << volume.volume_path if volume.respond_to?(:volume_path)
          end
        end
      rescue StandardError => e
        logger.warn "The cluster shared volumes could not be read for the delete decision: #{e.class}"
      end
      roots.map { |root| normalize_windows_path(root) }.reject(&:empty?).uniq
    end

    # Windows paths, made comparable: forward slashes to backslashes, repeated
    # separators collapsed, trailing separators trimmed (a root reported as
    # `C:\VMs\` and a path built as `C:\VMs\vm1` are the same folder). Case is
    # NOT folded here — the comparisons that consume this fold as they compare,
    # so the value stays quotable back to an operator read.
    def normalize_windows_path(path)
      path.to_s.tr('/', '\\').gsub(/\\{2,}/, '\\').sub(/\\\z/, '')
    end

    # The folder a machine's config lives in, deleted with the machine, only
    # when BOTH answers say so — and any answer that cannot be had says keep:
    #
    # 1. the string rule: the folder's own name is the machine's name (exact,
    #    case-insensitively) and it sits directly under one of the roots the
    #    hypervisor itself named (the two roots and the shared volumes), with
    #    that root spelled out in full — no 8.3 short-name root (a `PROGRA~1`
    #    segment could alias any long name, and attribution against an alias
    #    is not attribution) and no name shape a filesystem read could not
    #    tie back (`\ / : * ? " < > |`, a `..` segment, a trailing `.` or
    #    space, control or non-printing characters — all keep the folder);
    # 2. the wire preflight (measured exists shape, §45.4; folder-level
    #    collision itself NOT separately measured — stated): the folder is
    #    there, is not a reparse point (a junction's contents live wherever
    #    the junction points, and recursing through one deletes someone
    #    else's tree), is not hidden (a hidden folder wearing the machine's
    #    name is not provably the machine's), and its contents carry this
    #    machine's config — every `*.vmcx`/`*.vmrs` in it named for this
    #    machine, and at least one `.vmcx` present.
    #
    # @return [Boolean] delete the folder with the machine (fog's destroy(true))
    def destroy_folder?(vm)
      folder = folder_deletion_path(vm)
      return false unless folder

      case folder_preflight(vm, folder)
      when :ok
        true
      when :absent
        logger.info "The config folder #{folder} of #{vm.name} is already gone; nothing to delete with it"
        false
      else
        false
      end
    end

    # The string rule alone, without the wire read: the folder path if the
    # name and root attribution hold, nil if not. Kept apart from destroy_folder?
    # so the create-rollback decision and the pre-flight gate read the same rule,
    # and so a path the rule refuses never reaches the pre-flight script at all.
    def folder_deletion_path(vm)
      name = vm.name.to_s
      path = normalize_windows_path(vm.path)
      return nil if name.empty? || path.empty?

      # The name shape a filesystem read could tie back: no path or wildcard
      # characters, no control or non-printing characters, no traversal
      # segment (`..` anywhere — the plan's red list), no trailing `.` or
      # space (Windows trims them and the trimmed folder is not provably the
      # named one). A single dot inside the name is legal (vm.old is a VM
      # name); a component bound at Windows' own 255.
      return nil unless name.match?(%r{\A[^\\/:*?"<>|\x00-\x1f](?:[^\\/:*?"<>|\x00-\x1f]| )*[^\\/:*?"<>|\x00-\x1f]?\z})
      return nil if name.include?('..') || name.match?(/[. ]\z/)
      return nil unless name.length <= 255
      return nil if path.split('\\').any? { |segment| segment == '..' }
      return nil if path.split('\\').any? { |segment| segment.match?(/~\d+\z/) }

      folder_name = path.split('\\').last.to_s
      return nil unless folder_name.casecmp(name).zero?

      parent = normalize_windows_path(path.split('\\')[0..-2]&.join('\\'))
      return nil if parent.empty?

      roots = storage_roots
      return nil if roots.empty?

      roots.any? { |root| parent.casecmp(root).zero? } ? path : nil
    end

    # The wire half, one script, one round trip: exists, attributes, contents
    # in a single answer. The path riding the script is one the string rule
    # already attributed (its components matched a hypervisor-named root and a
    # clean machine name) — the escaping is belt, the string rule is braces.
    # Any read that cannot be had (fog error, unparsable answer) keeps the
    # folder: the pre-flight licenses the delete, and no answer licenses nothing.
    # @return [Symbol] :ok, :absent, or :keep (with the reason logged)
    def folder_preflight(vm, folder)
      quoted = "'#{folder.gsub("'", "''")}'"
      script = format(FOLDER_PREFLIGHT_SCRIPT, folder: quoted)
      out = vm.service.run_cmd(script, _skip_json: true)
      answer = out.stdout.to_s.strip
      case answer
      when 'ABSENT' then :absent
      when 'KEEP:JUNCTION' then keep_folder(folder, 'it is a reparse point (junction or symlink)')
      when 'KEEP:HIDDEN' then keep_folder(folder, 'it is hidden')
      when /\AFORBIDDEN:/ then keep_folder(folder, 'the remote refused the path itself')
      when /\ANAMES:/ then folder_contents_ok?(vm, folder, answer.delete_prefix('NAMES:'))
      else keep_folder(folder, 'the pre-flight answer was not the shape this rule understands')
      end
    rescue StandardError => e
      logger.warn "The config-folder pre-flight for #{folder} did not answer (#{e.class}); the folder stays"
      :keep
    end

    def keep_folder(folder, reason)
      logger.info "The config folder #{folder} stays: #{reason}"
      :keep
    end

    # The content attribution, measured against the layout the hypervisor
    # actually writes: the config lives ONE LEVEL DOWN in `Virtual Machines\`
    # and is named for the machine's GUID (`{id}.vmcx`, `{id}.vmrs`), not for
    # its name — so attribution runs on the id (the machine name second, for
    # any layout that spells it), and the read is recursive. A second
    # machine's config in this folder is the collision the rule exists for —
    # recursing would delete both. Snapshots, avhdx files and the snapshot
    # directories carry no config signature and pass with the folder.
    def folder_contents_ok?(vm, folder, names_blob)
      names = names_blob.split(';').map(&:strip).reject(&:empty?).map(&:downcase)
      configs = names.select { |n| n.end_with?('.vmcx', '.vmrs') }
      attributed = [vm.id.to_s.downcase, vm.name.to_s.downcase]
      foreign = configs.reject { |n| attributed.include?(n.sub(/\.(vmcx|vmrs)\z/, '')) }
      return keep_folder(folder, 'another machine’s config file lives in it') unless foreign.empty?

      unless configs.any? { |n| n.end_with?('.vmcx') && attributed.include?(n.delete_suffix('.vmcx')) }
        return keep_folder(folder, 'this folder holds no config file of this machine')
      end

      :ok
    end

    # A create rollback's folder verdict (see the rollback in create_vm): the
    # machine's own folder per the two-root rule and its pre-flight, kept if
    # any disk file still lives inside it — the rollback detached every drive
    # without deciding any file, so an attached pre-existing disk inside the
    # folder is a survivor by definition, and the recursing folder delete
    # would take it without being asked to.
    def rollback_folder_delete?(vm)
      machine_folder = folder_deletion_path(vm)
      return false unless machine_folder
      return false unless folder_preflight(vm, machine_folder) == :ok

      survivor = vm.hard_drives.any? { |hdd| file_lives_in?(hdd, machine_folder) }
      if survivor
        logger.warn "The config folder of #{vm.name} keeps itself: a disk file still lives in it, " \
                    'and the rollback detached rather than decided it'
        false
      else
        true
      end
    end

    def file_lives_in?(hdd, folder)
      parent = normalize_windows_path(hdd.path.to_s.split('\\')[0..-2]&.join('\\'))
      !parent.empty? && parent.casecmp(folder.to_s).zero?
    end

    # --- PLG-22: the drive rule (call-site path check) ----------------------------

    # A disk file is deleted (not just detached) only when its path is
    # attributable to this machine the same way the folder is: its parent
    # folder is this machine's folder or one of the roots the hypervisor
    # named, no traversal or short-name segment, and no fog error along the
    # way. The fog model's own sharing check rides the delete itself
    # (destroy(underlying: true) refuses a drive whose persistent-reservations
    # state is not proven absent — SharedDiskDeleteRefused), and this plugin
    # reads that same property before the wire so a destroy whose disk cannot
    # be proven unshared detaches and leaves the file rather than failing
    # half-torn-down: an orphaned file is recoverable, a wrongly deleted one
    # is not.
    # @return [Boolean] delete the file with the detach
    def drive_deletion_allowed?(vm, hdd)
      path = normalize_windows_path(hdd.path)
      return false if path.empty?
      return false if path.split('\\').any? { |segment| segment == '..' || segment.match?(/~\d+\z/) }

      parent = normalize_windows_path(path.split('\\')[0..-2]&.join('\\'))
      machine_folder = folder_deletion_path(vm)
      roots = storage_roots
      return false if roots.empty?

      attributable = parent.casecmp(machine_folder.to_s).zero? || roots.any? { |root| parent.casecmp(root).zero? }
      return false unless attributable

      if hdd.respond_to?(:support_persistent_reservations) && hdd.support_persistent_reservations != false
        logger.warn "The disk #{path} of #{vm.name} keeps its file: its sharing state reads " \
                    "#{hdd.support_persistent_reservations.inspect}, and only a proven-absent one licenses the delete"
        return false
      end
      true
    end

    # Where a machine (or a disk of one) is asked to go, checked against what
    # the hypervisor itself named — never by asking the hypervisor about the
    # string. computer_name must be the endpoint host, the name the host gives
    # itself, or a name on the cluster's unfiltered Get-ClusterNode list;
    # cluster_name must be a member of the cached cluster listing; a volume's
    # datastore must be one of that cluster's shared volumes. The character
    # allowlist already ran (InputValidation is the first act at every site),
    # so the strings reaching the fog reads below are ours, not the user's, and
    # every read is unfiltered — a membership read IS a fog call, and it is the
    # one the user's string never enters.
    #
    # Fail closed: a membership read that does not answer refuses the
    # operation. Falling back to "probably fine" is how a machine gets placed
    # somewhere nobody checked.
    def validate_placement!(attr)
      # Form hashes arrive with string keys and API hashes with symbols; the
      # membership reads below are keyed by symbol either way.
      attr = attr.to_hash.deep_symbolize_keys if attr.respond_to?(:to_hash)

      computer = attr[:computer_name].presence
      if computer && placement_target_names.none? { |host| host == computer.to_s.downcase }
        raise ForemanHyperv::OperationRefused,
              'Refusing to place a machine on a computer this compute resource has not seen its own ' \
              'host or cluster report; nothing was asked of the host with that name'
      end

      cluster_name = attr[:cluster_name].presence
      if cluster_name && cluster_named(cluster_name).nil?
        raise ForemanHyperv::OperationRefused,
              'Refusing to place a machine in a cluster this compute resource has not read from its ' \
              'endpoint; nothing was asked of the host with that name'
      end

      asked_volumes = nested_attributes_for(:volumes, attr[:volumes_attributes]).filter_map { |vol| vol[:datastore] }
      return if asked_volumes.empty?

      cluster = cluster_name ? cluster_named(cluster_name) : endpoint_cluster
      offered, excluded = placement_storage_domains(cluster)
      asked_volumes.each do |asked|
        next if offered.any? { |domain| domain.name == asked || domain.id == asked }

        # Two different facts, two different refusals: a volume the cluster
        # ANSWERS but declines (offline, no path, an unmeasured state) names
        # itself with its reason; a volume never answered at all keeps the
        # membership refusal — the ask could not have come from this endpoint.
        hit = excluded.detect { |volume, _reason| volume.name == asked || volume.volume_path == asked }
        if hit
          raise ForemanHyperv::OperationRefused, format(STORAGE_EXCLUDED_REFUSAL, volume: asked, reason: hit.last)
        end

        raise ForemanHyperv::OperationRefused,
              'Refusing to place a disk on a shared volume this compute resource has not read from ' \
              'its cluster; nothing was asked of the host with that name'
      end
    end

    # The node names a machine may be placed on: the configured endpoint, the
    # name the host gives itself, and every node of the cluster it belongs to.
    # Read fresh rather than cached — placement is exactly the decision a stale
    # list gets wrong — and a failed read is a refusal, not an empty set.
    def placement_target_names
      names = []
      begin
        names << URI.parse(url.to_s).host
        names << hypervisor.name
        if (cluster = endpoint_cluster)
          names.concat(cluster.nodes.map(&:name))
        end
      rescue StandardError => e
        # The fog error's own text can echo the remote command line, so it is
        # logged as its class only and never quoted back to the user.
        logger.warn "Refusing to read placement targets: the membership read answered #{e.class}"
        raise ForemanHyperv::OperationRefused,
              'Refusing to choose a placement target while the hypervisor could not report its own nodes'
      end
      names.compact.map { |host| host.to_s.downcase }
    end

    # Disk removals are refused on every Hyper-V compute resource, checked on
    # the submitted hash so the refusal lands before any lookup — and carrying
    # the canonical enablement sentence in the message.
    def refuse_disk_removal!(attr)
      return if disk_removal_allowed?

      volumes = nested_attributes_for(:volumes, attr[:volumes_attributes])
      return if volumes.none? { |vol| vol[:_delete].to_s == '1' }

      raise ForemanHyperv::OperationRefused, DISK_REFUSAL
    end

    # --- PLG-15b: the stand-alone create gate -----------------------------------

    # arm (a): one minimal-property WQL read of the cluster itself, on the
    # compute resource's own endpoint, through fog's run_wql (which appends
    # the namespace's `/*` grammar itself — passing the wildcard in here would
    # double it, a shape measured to raise "invalid namespace" instead of
    # answering). A row means membership; the two measured wire faults mean
    # the opposite; everything else — auth failures, transport errors, a
    # provider that answers with no row at all — says nothing, and N3 makes
    # everything that says nothing indeterminate. A positive reading is a
    # cluster sighting (B6): it goes into the insert-only ledger before this
    # method answers, and a ledger that cannot take the row is a refusal.
    def cluster_membership_state
      unless client.respond_to?(:run_wql)
        logger.warn 'The cluster membership read could not run: this fog exposes no WQL query path'
        return :indeterminate
      end

      rows = client.run_wql(CLUSTER_MEMBERSHIP_QUERY, _namespace: CLUSTER_MEMBERSHIP_NAMESPACE)
      if rows.is_a?(Hash) && rows[:name].to_s.strip.present?
        record_cluster_sighting(cluster_name: rows[:name].to_s.strip)
        :clustered
      else
        # The measured not-joined machine raises 1359 rather than answering an
        # empty row set; a provider that answers with nothing, or with a row
        # that carries no name, is a shape that has not been measured.
        :indeterminate
      end
    rescue ForemanHyperv::OperationRefused
      # The ledger's own refusal (write-fail, B6) is a decision, not an
      # unreadable wire: it travels up as itself instead of being folded into
      # the indeterminate class that says "the read did not answer".
      raise
    rescue StandardError => e
      arm_a_consistent_wire_error?(e) ? :not_clustered : :indeterminate
    end

    # The two faults that read as not-clustered through this exact query path,
    # as exceptions (WinRMWSManFault 1359, WinRMWMIError 2150858778) or as the
    # same reading one layer up — a fog PSError whose captured streams quote
    # one of the two wire codes is the machine's answer arriving as a command
    # failure rather than a transport exception, and it is the same answer.
    # Any other error, PSError included, is not an answer about membership.
    def arm_a_consistent_wire_error?(error)
      if defined?(::WinRM) && error.is_a?(::WinRM::WinRMWSManFault) &&
         error.fault_code.to_i == WIRE_CODE_CLUSTER_UNAVAILABLE
        return true
      end

      if defined?(::WinRM) && error.is_a?(::WinRM::WinRMWMIError) &&
         error.error_code.to_i == WIRE_CODE_FEATURE_ABSENT
        return true
      end

      return false unless error.is_a?(Fog::Hyperv::Errors::PSError)

      streams = "#{error.message}\n#{error.stderr}"
      streams.include?("WSMAN ERROR CODE: #{WIRE_CODE_CLUSTER_UNAVAILABLE}") ||
        streams.include?("WMI ERROR CODE: #{WIRE_CODE_FEATURE_ABSENT}")
    end

    # B2's dual-marker read, executed entirely server-side as one fog command.
    # The ONLY branch that may answer absent is the not-found exception the
    # named primitive raises for a missing path (N3: fog's single PSError and
    # its nil-on-empty-stdout replies make plugin-side discrimination from an
    # exit code impossible, so the machine's answer arrives as one JSON token
    # written by typed catches). The full exception class name rides the token
    # so the row-(v) arms can assert the exact per-marker shape the F3 table
    # names. present and absent are the only answers the gate acts on; denied
    # — a read the machine refused, of any class the F3 table expects under a
    # deny — and unreadable (every other exception) read as indeterminate, and
    # so does anything short of a well-formed token, empty stdout included.
    def marker_state(marker)
      out = client.run_cmd(marker_read_script(marker), _skip_json: true)
      reply = out.stdout.to_s.strip
      return :indeterminate if reply.empty? || reply.length > 1_024

      token = Fog::JSON.decode(reply)
      return :indeterminate unless token.is_a?(Hash)

      result = token['result'].to_s
      logger.debug "The #{marker} marker read answered #{result} (#{sanitize_text(token['type'].to_s)})"
      %w[present absent].include?(result) ? result.to_sym : :indeterminate
    rescue StandardError => e
      # fog raising at all — transport, auth, parse — says nothing (N3).
      logger.warn "The #{marker} marker read did not answer: #{e.class}"
      :indeterminate
    end

    # The script the marker read runs. Only the two constants in MARKER_READS
    # are interpolated — no user input is anywhere near it, and the whole read
    # is one command: open/read, five typed catches, one JSON line.
    def marker_read_script(marker)
      read = MARKER_READS.fetch(marker)
      probe = [read[:cmdlet], "-LiteralPath '#{read[:path]}'", read[:args], '-ErrorAction Stop'].compact.join(' ')
      <<~MARKER_READ
        $ForemanHypervMarkerRead = try {
          $null = #{probe}
          [pscustomobject]@{ result = 'present'; type = $null }
        } catch [System.Management.Automation.ItemNotFoundException] {
          [pscustomobject]@{ result = 'absent'; type = $_.Exception.GetType().FullName }
        } catch [System.Security.SecurityException] {
          [pscustomobject]@{ result = 'denied'; type = $_.Exception.GetType().FullName }
        } catch [System.UnauthorizedAccessException] {
          [pscustomobject]@{ result = 'denied'; type = $_.Exception.GetType().FullName }
        } catch [System.IO.IOException] {
          [pscustomobject]@{ result = 'denied'; type = $_.Exception.GetType().FullName }
        } catch {
          [pscustomobject]@{ result = 'unreadable'; type = $_.Exception.GetType().FullName }
        }
        $ForemanHypervMarkerRead | ConvertTo-Json -Compress
      MARKER_READ
    end

    # --- PLG-15c: the stand-alone destroy gate ---------------------------------------

    # The rule as plan §2 item 9 writes it, in the plan's own order, and every
    # reading is made again on this attempt — there is nothing to configure and
    # nothing is cached. The answers it gives: :standalone (every condition
    # provably met), :clustered (any reading that makes this a cluster compute
    # resource by the definition — a stored sighting, a reported role, a
    # membership row, a present marker, a joined or maintenance service state),
    # :indeterminate (anything that says nothing: denied reads, unparsable
    # tokens, rc≠0, a raising P/Invoke, an unreadable ledger), and :not_self
    # (the machine's computer name re-read at destroy time is not the name the
    # endpoint gives itself — per-node addressing is PLG-5a's). Destroy-side
    # safety on the accepted-on-argument broken-node shape (§47.4, d23g) rides
    # on the ledger alone, with its pre-15b blind spot — stated plainly in the
    # plan and nowhere hidden here.
    def standalone_destroy_state(vm)
      return :clustered if sticky_cluster_sighting?

      # The machine's own reported role, before any gate read: a role is a
      # claim on config and disks no stand-alone proof can talk anyone out of.
      # B6's mirror on the destroy side (plan §2 item 9): every clustered
      # observation the gate makes lands on the insert-only ledger before the
      # refusal returns — the membership read already records its own row, so
      # the readings this gate adds append theirs here, and a later run of
      # clean reads can never unlock this endpoint.
      if vm.respond_to?(:clustered?) && vm.clustered?
        persist_cluster_sighting(kind: 'sighting', reason: 'the machine fog reported a cluster role')
        return :clustered
      end

      case cluster_membership_state
      when :not_clustered
        nil
      when :clustered
        # The sighting went out with the read itself (cluster_membership_state
        # appends it); this branch only decides and refuses.
        logger.warn 'Refusing to destroy a virtual machine: the endpoint answered a cluster membership row'
        return :clustered
      else
        logger.warn 'Refusing to destroy a virtual machine: the cluster membership read did not answer'
        return :indeterminate
      end

      MARKER_READS.each_key do |marker|
        state = marker_state(marker)
        case state
        when :absent
          next
        when :present
          # Both stores present under a not-clustered membership read is the
          # measured maintenance shape (d22): "not proven stand-alone" is
          # exactly what the definition of a cluster compute resource turns on.
          persist_cluster_sighting(kind: 'sighting', reason: "the #{marker} cluster marker read answered present")
          logger.warn "Refusing to destroy a virtual machine: the #{marker} marker read answered present"
          return :clustered
        else
          logger.warn "Refusing to destroy a virtual machine: the #{marker} marker read answered #{state}"
          return :indeterminate
        end
      end

      case cluster_service_state
      when :standalone
        nil
      when :clustered
        persist_cluster_sighting(kind: 'sighting', reason: 'the cluster-service state read answered joined')
        logger.warn 'Refusing to destroy a virtual machine: the cluster-service state read answered joined'
        return :clustered
      else
        logger.warn 'Refusing to destroy a virtual machine: the cluster-service state read did not answer'
        return :indeterminate
      end

      # The destroy-time re-read (plan §2 item 9): the machine is where the
      # endpoint says it is, or the destroy is per-node addressing wearing a
      # UUID.
      return :not_self unless self_rung?(vm)

      :standalone
    end

    # B6's ledger read, on the destroy side: a sticky sighting is the endpoint's
    # own past, and the definition is a SIGHTING row — a strand record is one
    # machine with an unresolved role write, not an endpoint that ever answered
    # as a cluster, and it does not make a host sticky. An endpoint that does
    # not parse to a host, or a ledger that cannot be read, answers sticky: the
    # gate's "no sticky sighting" is not provable there, and B6's rule is that
    # an unreadable ledger is a refusal, not an absence.
    def sticky_cluster_sighting?
      host = endpoint_host_name
      unless host
        logger.warn 'The destroy gate could not ask the ledger: the configured endpoint does not name a host'
        return true
      end

      ForemanHyperv::ClusterSighting.exists?(endpoint_host: host, kind: 'sighting')
    rescue ActiveRecord::ActiveRecordError => e
      logger.warn "The destroy gate could not read the sightings ledger: #{e.class}"
      true
    end

    # The clusapi leg, read entirely server-side as one command answering one
    # JSON token: the P/Invoke's rc and state, the service record's answer and
    # the cluster directory's answer — each through typed catches, so absent is
    # only ever the measured not-found exception (N3, the same discipline and
    # the same catch table as the marker read). The acceptance set is measured
    # shapes only: state 1 with the service record present (never-joined,
    # §45.2), and state 0 with the service record AND the cluster directory
    # also answering not-found — the B9/N2 branch, where the marker loop has
    # already read PARAMS and CLUSDB not-found, so all three stores are gone
    # (d19, d23g). State 1 beside a missing record, and state 0 under a present
    # record, are shapes no measurement produced — they read indeterminate, and
    # so does every rc≠0 and every raising call (N2).
    def cluster_service_state
      out = client.run_cmd(cluster_service_read_script, _skip_json: true)
      reply = out.stdout.to_s.strip
      return :indeterminate if reply.empty? || reply.length > 2_048

      token = Fog::JSON.decode(reply)
      return :indeterminate unless token.is_a?(Hash)
      return :indeterminate unless %w[clusapi svc cdir].all? { |leg| token[leg].is_a?(Hash) }

      clusapi = token['clusapi']
      unless clusapi['result'].to_s == 'ok' && clusapi['rc'].is_a?(Integer) && clusapi['state'].is_a?(Integer)
        logger.warn "The cluster-service state read did not answer: #{sanitize_text(clusapi['type'].to_s)}"
        return :indeterminate
      end
      return :indeterminate unless clusapi['rc'].zero?

      service_record = token['svc']['result'].to_s
      case clusapi['state']
      when CLUSAPI_RUNNING, CLUSAPI_NOT_RUNNING
        :clustered
      when CLUSAPI_NOT_CONFIGURED
        # clusapi=1 beside a service record that is not present is not a cell
        # the battery ever produced, and the plan names it indeterminate.
        return :standalone if service_record == 'present'

        logger.warn "Refusing to trust clusapi=1 with the service record answered #{service_record}"
        :indeterminate
      when CLUSAPI_NO_CLUSTER_SERVICE
        # The 0 means "no cluster service or config" (d23g): accepted, as the
        # plan argues, exactly when every store says gone — the markers above,
        # the service record here, and the cluster directory here. Anything
        # else under a 0, including the never-measured record-present shape,
        # says nothing.
        cluster_directory = token['cdir']['result'].to_s
        return :standalone if service_record == 'absent' && cluster_directory == 'absent'

        logger.warn "Refusing to trust clusapi=0 with the service record #{service_record} " \
                    "and the cluster directory #{cluster_directory}"
        :indeterminate
      else
        :indeterminate
      end
    rescue StandardError => e
      # fog raising at all — transport, auth, parse — says nothing (N3).
      logger.warn "The cluster-service state read did not answer: #{e.class}"
      :indeterminate
    end

    # The script the service-state read runs. Three named primitives, typed
    # catches carrying the full exception class on every token, one JSON line:
    # the P/Invoke under its own type guard (a warm runspace already knows the
    # type), the service registry key opened with the same primitive whose
    # not-found answer row (v) measured for the PARAMS marker, and the cluster
    # directory opened with Get-Item. Only the two path constants and the
    # reviewed P/Invoke definition are interpolated — no user input is anywhere
    # near it, and the whole read is one command.
    def cluster_service_read_script
      svc = SERVICE_RECORD_READ
      cdir = CLUSTER_DIRECTORY_READ
      <<~CLUSTER_SERVICE_READ
        $ForemanHypervServiceRead = [pscustomobject]@{ clusapi = $null; svc = $null; cdir = $null }
        $ForemanHypervCluster = [pscustomobject]@{ result = 'error'; rc = $null; state = $null; type = $null }
        try {
          if (-not ('ForemanHyperv.ClusterApi' -as [type])) {
            Add-Type -Namespace ForemanHyperv -Name ClusterApi -ErrorAction Stop `
              -MemberDefinition '#{CLUSTER_API_SIGNATURE}'
          }
          $ForemanHypervState = [uint32]0
          $ForemanHypervRc = [ForemanHyperv.ClusterApi]::GetNodeClusterState($null, [ref]$ForemanHypervState)
          $ForemanHypervCluster.result = 'ok'
          $ForemanHypervCluster.rc = $ForemanHypervRc
          $ForemanHypervCluster.state = $ForemanHypervState
        } catch {
          $ForemanHypervCluster.type = $_.Exception.GetType().FullName
        }
        $ForemanHypervServiceRead.clusapi = $ForemanHypervCluster
        $ForemanHypervSvc = try {
          $null = #{svc[:cmdlet]} -LiteralPath '#{svc[:path]}' -ErrorAction Stop
          [pscustomobject]@{ result = 'present'; type = $null }
        } catch [System.Management.Automation.ItemNotFoundException] {
          [pscustomobject]@{ result = 'absent'; type = $_.Exception.GetType().FullName }
        } catch [System.Security.SecurityException] {
          [pscustomobject]@{ result = 'denied'; type = $_.Exception.GetType().FullName }
        } catch [System.UnauthorizedAccessException] {
          [pscustomobject]@{ result = 'denied'; type = $_.Exception.GetType().FullName }
        } catch [System.IO.IOException] {
          [pscustomobject]@{ result = 'denied'; type = $_.Exception.GetType().FullName }
        } catch {
          [pscustomobject]@{ result = 'unreadable'; type = $_.Exception.GetType().FullName }
        }
        $ForemanHypervServiceRead.svc = $ForemanHypervSvc
        $ForemanHypervCdir = try {
          $null = #{cdir[:cmdlet]} -LiteralPath '#{cdir[:path]}' -ErrorAction Stop
          [pscustomobject]@{ result = 'present'; type = $null }
        } catch [System.Management.Automation.ItemNotFoundException] {
          [pscustomobject]@{ result = 'absent'; type = $_.Exception.GetType().FullName }
        } catch [System.Security.SecurityException] {
          [pscustomobject]@{ result = 'denied'; type = $_.Exception.GetType().FullName }
        } catch [System.UnauthorizedAccessException] {
          [pscustomobject]@{ result = 'denied'; type = $_.Exception.GetType().FullName }
        } catch [System.IO.IOException] {
          [pscustomobject]@{ result = 'denied'; type = $_.Exception.GetType().FullName }
        } catch {
          [pscustomobject]@{ result = 'unreadable'; type = $_.Exception.GetType().FullName }
        }
        $ForemanHypervServiceRead.cdir = $ForemanHypervCdir
        $ForemanHypervServiceRead | ConvertTo-Json -Compress
      CLUSTER_SERVICE_READ
    end

    # N6's self rung: the endpoint's own Get-VMHost name against the machine's
    # computer name, case-insensitively. A name that does not match — or an
    # endpoint that cannot name itself — is refused: per-node addressing is
    # PLG-5a's, and "fail-closed until PLG-5a" lives here until that PR lands
    # (the pre-registered shipping state, not an oversight).
    def self_rung?(vm)
      self_rung_name?(vm&.computer_name)
    end

    # The same rung for a name before any model exists (the create path
    # decides which client to build on): case-insensitive equality with the
    # name the endpoint gives itself over Get-VMHost. An endpoint that cannot
    # name itself matches nothing.
    def self_rung_name?(asked)
      asked = asked.to_s.strip
      return false if asked.empty?

      host_name = hypervisor.name.to_s.strip
      return false if host_name.empty?

      asked.casecmp(host_name).zero?
    rescue StandardError => e
      logger.warn "The endpoint could not name itself for the self-check: #{e.class}"
      false
    end

    # --- B6: the insert-only sightings ledger -------------------------------------

    # The endpoint host in the shape the ledger stores: the configured
    # endpoint's host, trimmed and downcased — the identity a later destroy
    # gate reads by. An endpoint that does not parse to a host is not a
    # host the ledger can hold a row for.
    def endpoint_host_name
      URI.parse(url.to_s).host.to_s.strip.downcase.presence
    rescue URI::Error
      nil
    end

    def record_cluster_sighting(cluster_name:)
      persist_cluster_sighting(kind: 'sighting', cluster_name: cluster_name)
    end

    # The write-fail rule (B6): every cluster-row sighting appends, and a
    # ledger that will not take the row means the reading cannot be recorded —
    # so the reading is refused, not trusted and not silently dropped. Values
    # go through the same sanitizers the strand log record uses: cluster and
    # machine names are machine-sourced text.
    def persist_cluster_sighting(kind:, vm_uuid: nil, vm_name: nil, cluster_name: nil, reason: nil)
      host = endpoint_host_name
      raise ForemanHyperv::OperationRefused, SIGHTING_WRITE_REFUSAL if host.nil?

      ForemanHyperv::ClusterSighting.create!(
        endpoint_host: host,
        kind: kind,
        vm_uuid: strand_param(vm_uuid).presence,
        vm_name: strand_param(vm_name).presence,
        cluster_name: sanitize_text(cluster_name.to_s).presence,
        reason: sanitize_text(reason.to_s).presence
      )
    rescue ActiveRecord::ActiveRecordError => e
      logger.error "The sightings ledger refused a #{kind} record and the reading goes with it: #{e.class}"
      raise ForemanHyperv::OperationRefused, SIGHTING_WRITE_REFUSAL
    end

    def _clusters
      return [] if client.respond_to?(:supports_clusters?) && !client.supports_clusters?

      client.clusters.all
    rescue StandardError
      []
    end

    # The cluster an endpoint belongs to, or nil for a stand-alone host — and for a
    # fog too old to have read a cluster's node list, which is the same nothing as far
    # as a caller is concerned.
    def endpoint_cluster
      return nil unless client.respond_to?(:supports_clusters?) && client.respond_to?(:cluster_nodes)
      return nil unless client.supports_clusters?

      clusters.first
    rescue StandardError
      nil
    end

    def cluster_named(identifier)
      return nil if identifier.blank?

      clusters.detect { |cluster| cluster.id == identifier || cluster.name == identifier }
    end

    # The hosts a placement choice is made between: the endpoint on its own, or every
    # node of the cluster when it belongs to one. Get-VMHost answers for the machine it
    # ran on and nothing else, so a cluster's other nodes come from the cluster's node
    # list and their details from each node in turn — through that node's own client
    # (client_for_node, PLG-5a/5b), because fog's exact_host_connection capability
    # refuses to dial any name the resource's own client has not already spoken to,
    # and node.host would ride that client for every non-endpoint node (PLG-25: the
    # VM tab's first load, refused on hv-node2). A node that cannot be reached stays
    # in the list with only its name: the machine form leans on this listing, and one
    # node being down is a thing to report, not a reason to hide the node or to fail
    # the page.
    def cluster_backed_hosts(cluster = nil)
      return client.hosts.all unless cluster

      cluster.nodes.each_with_object([]) do |node, hosts|
        hosts << begin
          client_for_node(node.name).hosts.first
        rescue StandardError => e
          Rails.logger.warn "Hyper-V node #{node.name} is in cluster #{cluster.name} but not reachable over WinRM: #{e.message.lines.first}"
          node_only = client.hosts.new(name: node.name)
          # A node that answers the cluster but not WinRM is where the plugin learns a
          # node has gone quiet, so what it cached for that node while it answered goes
          # with it: a switch list read through an outage is a placement guess, and the
          # first read after the node comes back asks the node instead of serving that
          # list out its remaining lifetime. Nowhere else can this be noticed — a
          # cached switch list means the node is never asked, and a failed read means
          # there was nothing cached to drop.
          invalidate_hyperv_cache(switches_cache_key(node_only))
          node_only
        end
      end
    end

    # vSphere's clusters endpoint reports a size as a node count; for Hyper-V that is
    # Get-ClusterNode's list. Nil when fog cannot read it, because zero reads as an
    # empty cluster, which is a different claim from an unreadable one.
    def cluster_node_count(cluster)
      return nil unless cluster.respond_to?(:nodes)

      cluster.nodes.count
    rescue StandardError
      nil
    end

    def api_networks(list)
      list.map { |switch| ApiNetwork.new(switch.name, switch.id, nil, switch.name, nil) }
    end

    # How long this resource's listings are held. Core's own three hours suits a
    # stand-alone host: its node list and virtual switches change when an
    # administrator changes them, and each of those reads costs seconds of WinRM. A
    # cluster has no such quiet — nodes join, drain and stop answering without
    # touching the Foreman record, and Hyper-V gives out no event to listen for — so
    # its answers do not get to live as long. Five minutes puts a node that joined the
    # cluster into the next page load rather than hours away, and costs one re-read of
    # the cluster per page load.
    CLUSTER_CACHE_EXPIRY = 5.minutes

    # Core's cache object, built with the lifetime this endpoint deserves. The cluster
    # question is asked of fog rather than of the listings, because what is being
    # decided here is how long those listings live: reading them would ask the cache
    # object that is still being built.
    def cache
      @cache ||= if cluster_endpoint?
                   ComputeResourceCache.new(self, cache_duration: CLUSTER_CACHE_EXPIRY)
                 else
                   ComputeResourceCache.new(self)
                 end
    end

    # Whether the endpoint answers as a cluster, asked once and remembered: fog asks
    # the host every time, and every cache key would otherwise ask with it.
    def cluster_endpoint?
      return @cluster_endpoint if instance_variable_defined?(:@cluster_endpoint)

      # PLG-33b: when this request started a listing, the probe is already in
      # flight — take that answer instead of asking again. The rescue and the
      # warn below are today's, unchanged: a consumed failure re-raises on
      # THIS thread and degrades exactly like the sequential read did. With
      # no pipeline (every other caller) this is the sync read, verbatim.
      probe = @listing_pipeline&.take_probe
      @cluster_endpoint =
        if probe.nil?
          client.respond_to?(:supports_clusters?) && client.supports_clusters?
        else
          !!probe
        end
    rescue StandardError => e
      Rails.logger.warn "Hyper-V cluster support for #{name} could not be read: #{e.message.lines.first}"
      @cluster_endpoint = false
    end

    # The cluster's roles keyed by BOTH identities that name a machine: its
    # reported machine id — case-insensitively, because the cluster reports ids
    # upper-case and the plugin holds them lower-case, and fog's own -VMId filter
    # matches case-insensitively too — and the group name the cluster builds from
    # the machine's name, because the id field is reported on ClusterGroup but
    # undocumented and can come back empty (the same acceptance readback_finds_role?
    # uses on the create path). One read answers the whole page; a per-machine
    # probe would multiply a 2–8 s round trip by the row count.
    #
    # Three ways this answers WITHOUT an index, kept distinct from each other and
    # from an empty index because they license different operator actions:
    # :not_a_cluster (the endpoint disproved the question — everything it holds
    # is stand-alone), :unsupported (a fog that cannot be asked), and nil (asked,
    # could not answer). Only the empty index is the answer "no role".
    def cluster_role_index
      return @cluster_role_index if instance_variable_defined?(:@cluster_role_index)

      @cluster_role_index = build_cluster_role_index
    end

    # PLG-35: the answers this builds its verdicts from are LIVE reads, and
    # fog's Real#supports_clusters? rescues every transport error into
    # false — so one WinRM flap used to write :not_a_cluster into this
    # instance's memo and the page printed "Stand-alone" for a clustered
    # machine (observed live; a fresh instance seconds later read
    # correctly). The retry below is the plugin's only lever: a flap
    # answers differently one pause later, a genuine stand-alone host does
    # not. The tri-state is untouched — a read that raises through the
    # retry is still nil, "could not answer".
    def build_cluster_role_index
      return :unsupported unless client.respond_to?(:cluster_virtual_machine_roles) &&
                                 client.respond_to?(:supports_clusters?)

      # PLG-33c: a listing in flight started this read the moment its probe
      # answered CLUSTER. That YES is the membership answer — PLG-35's
      # confirmation exists for a flapped NO, and a flapped no never started
      # a lane — so the lane's array, even an empty one, builds the index
      # with ZERO reads on the resource's own client. No lane (no listing, a
      # stand-alone gate, a failed lane) runs the sequential path below
      # verbatim, retry and all.
      lane = take_pipelined_role_read
      return index_cluster_roles(lane) if lane

      return :not_a_cluster unless cluster_membership_confirmed?

      index_cluster_roles(read_cluster_roles)
    rescue StandardError => e
      # "Could not answer" stays its own answer — see vm_registration. A
      # probe that RAISES (a fog outside this fork's swallow-everything
      # contract) rides here too, and is not the flap the retry speaks of.
      logger.warn "The instance list could not read cluster roles for #{name}: " \
                  "#{e.class}: #{e.message.to_s.lines.first.to_s.strip}"
      nil
    end

    # PLG-33c: the lane's roles, or nil for "no lane" (never started — the
    # common no-listing case — or already claimed). A lane that FAILED is
    # named once with its own words, then answers nil so the sequential path
    # runs: the operator sees the pipelined read failed, and the page still
    # gets the retry the sequential path has always had.
    def take_pipelined_role_read
      return nil unless instance_variable_defined?(:@listing_pipeline) && @listing_pipeline

      @listing_pipeline.take_role_lane
    rescue StandardError => e
      logger.warn "The pipelined cluster role read for #{name} failed " \
                  "(#{e.class}: #{e.message.to_s.lines.first.to_s.strip}); reading cluster roles synchronously"
      nil
    end

    # The lane's read body (PLG-33c): the roles listing on the pipeline's
    # OWN fresh client — the one-client-one-thread WinRM rule the whole
    # pipeline holds — normalized exactly like the sequential read so both
    # paths hand index_cluster_roles the same shape.
    def pipelined_role_read(roles_client)
      Array(roles_client.cluster_virtual_machine_roles.all).flatten.compact
    end

    # Roles keyed by BOTH identities that name a machine — the shared body
    # of the lane-delivered and the sequential index, so the two paths can
    # never drift (see cluster_role_index for why both keys exist).
    def index_cluster_roles(roles)
      roles.each_with_object({}) do |role, index|
        role_id = role.respond_to?(:virtual_machine_id) ? role.virtual_machine_id : nil
        index[role_id.to_s.downcase] = role if role_id.present?
        role_name = role.respond_to?(:name) ? role.name.to_s : ''
        index[role_name] = role if role_name.start_with?(ROLE_NAME_PREFIX)
      end
    end

    # A false from the membership probe is confirmed by ONE more probe a
    # pause later. Two consistent answers ARE the verdict — no third
    # attempt, so a stand-alone deployment pays one confirmation and never
    # a spin, and a flapped no followed by a yes never reaches the page.
    def cluster_membership_confirmed?
      (1..ROLE_INDEX_PROBE_ATTEMPTS).each do |attempt|
        return true if client.supports_clusters?

        role_index_flap_pause if attempt < ROLE_INDEX_PROBE_ATTEMPTS
      end
      false
    end

    # The roles listing retried once on a raise — the same flap, the same
    # pause. A read that raises through the retry re-raises the original
    # error into the outer rescue: the page answers :unknown exactly as it
    # does today, one pause later.
    def read_cluster_roles
      (1..ROLE_INDEX_READ_ATTEMPTS).each do |attempt|
        return Array(client.cluster_virtual_machine_roles.all).flatten.compact
      rescue StandardError
        raise if attempt >= ROLE_INDEX_READ_ATTEMPTS

        role_index_flap_pause
      end
    end

    # The pause between retry attempts, on its own method so tests pin the
    # CALLS without running the clock. Two seconds is a rounding error
    # against the 2–8 s a healthy cluster read already costs, and well
    # inside the flaps on record.
    def role_index_flap_pause
      sleep ROLE_INDEX_RETRY_DELAY_SECONDS
    end

    # The node that answered the read. Printed for stand-alone machines, where
    # the answering node IS the owner; never called an owner elsewhere, because
    # computer_name is the reader and goes stale on a live move (PLG-27's lesson).
    def reading_node(vm)
      vm.respond_to?(:computer_name) ? vm.computer_name : nil
    end

    # Which shape the cached listings hold: a stand-alone host's answers, or a named
    # cluster's. A cluster forming around an endpoint changes the cluster and not the
    # Foreman record, so nothing flushes the caches; naming the keys for the shape
    # means a resource that has started listing nodes cannot be served the stand-alone
    # answer it wrote when it was not. Parameterised because a deployment may be
    # running a cache store whose keys take no spaces.
    def hyperv_cache_scope
      cluster = endpoint_cluster
      return 'standalone' if cluster.nil?

      cluster.name.to_s.parameterize.presence || 'cluster'
    end

    def hypervisors_cache_key
      :"#{hyperv_cache_scope}-hypervisors"
    end

    def hypervisor_cache_key
      :"#{hyperv_cache_scope}-hypervisor"
    end

    def switches_cache_key(host)
      :"#{host.name.to_s.parameterize.presence || host.name}-switches"
    end

    # Drops a cached answer that has been shown wrong, so the next read asks the host
    # again rather than repeating a stale answer until core's expiry — or until someone
    # notices and saves the resource, which is the other way core's cache scope rolls.
    def invalidate_hyperv_cache(*keys)
      keys.compact.uniq.each do |key|
        Rails.logger.info "Dropping the cached Hyper-V answer for #{key} on #{name}"
        cache.delete(key)
      end
    end

    # The node list is the cached answer the cluster can prove wrong: a role is owned
    # by a node of this cluster by definition, so an owner the list does not name means
    # the cluster has a node Foreman has not been told about. The names are read from
    # the cache alone — checking against a fresh host read would answer the question
    # with the thing being checked. The hypervisor key is deliberately not touched: it
    # holds the endpoint node's own attributes, which a role moving to another node says
    # nothing about.
    def drop_hypervisor_list_unless_named(node_name)
      return if node_name.blank?

      key = hypervisors_cache_key
      cached = cache.read(key)
      return if cached.blank?

      names = Array(cached).map { |attrs| attrs[:name] || attrs['name'] }.compact.map(&:downcase)
      invalidate_hyperv_cache(key) unless names.include?(node_name.to_s.downcase)
    rescue StandardError => e
      Rails.logger.warn "The cached Hyper-V node list for #{name} could not be inspected: #{e.message.lines.first}"
    end

    # The shared volume a clustered machine's config and disks go on: the one its
    # volumes asked for (the volumes of a machine share one folder, so the first
    # one named wins), or the cluster's first volume when nothing was named. Raising
    # on a volume that is not there — silently placing onto a different one than the
    # user asked for is how machines end up on the wrong storage.
    # Where a clustered machine's config and disks go. PLG-14 made every
    # branch here name itself: an empty placement set says whether the
    # cluster answered no volumes at all or answered volumes it excluded
    # (with each volume's reason), and a named ask that is not placeable
    # distinguishes "this cluster has no such volume" from "it has this one
    # and declined it for a reason" — the operator who typed a real volume
    # name deserves the second answer when it is the truth.
    def placement_storage(cluster, attr)
      return nil unless cluster

      offered, excluded = placement_storage_domains(cluster)
      if offered.empty?
        if excluded.empty?
          raise Foreman::Exception, "Cluster #{cluster.name} has no shared volumes to place a virtual machine on"
        end

        listing = excluded.map { |volume, reason| "#{volume.name} — #{reason}" }.join('; ')
        raise Foreman::Exception,
              "Cluster #{cluster.name} has no placeable shared volume to place a virtual machine on " \
              "(excluded: #{listing})"
      end

      asked = nested_attributes_for(:volumes, attr[:volumes_attributes]).map { |vol| vol[:datastore] }.compact.first
      return offered.first unless asked

      match = offered.detect { |domain| domain.name == asked || domain.id == asked }
      return match if match

      hit = excluded.detect { |volume, _reason| volume.name == asked || volume.volume_path == asked }
      if hit
        raise Foreman::Exception,
              "Cluster #{cluster.name} has no placeable shared volume named #{asked}: #{hit.last}"
      end

      raise Foreman::Exception, "Cluster #{cluster.name} has no shared volume named #{asked}"
    end

    # ONE read of the cluster's projected volumes answers both questions this
    # era asks: what to OFFER (name/mount-path/size/free-space, ready for the
    # rabl and the form) and what to REFUSE WITH A REASON (each volume that is
    # not placement storage, paired with why). A capacity read that fog itself
    # refuses — a contradicted witness, an uninterpretable answer — travels
    # up untouched: fog already refuses rather than guess, and a rescue here
    # would turn a stated refusal back into silence.
    def placement_storage_domains(cluster)
      return [[], []] unless cluster&.respond_to?(:shared_volumes)

      offered = []
      excluded = []
      cluster.shared_volumes.each do |volume|
        reason = placement_exclusion_reason(volume)
        if reason
          logger.info "Shared volume #{volume.name} of cluster #{cluster.name} is not placement storage: #{reason}"
          excluded << [volume, reason]
          next
        end

        offered << ApiStorageDomain.new(volume.name, volume.volume_path, volume.size, volume.free_space, nil)
      end
      [offered, excluded]
    end

    # The exclusion, decided as ONE pure function so the list, the placement
    # refusals and the membership refusals cannot drift apart on what counts
    # as storage. The online branch still checks the path: a mount path is
    # never synthesised from the volume name (FOG-8), and without one the
    # config path and disk folder would both be guesses.
    def placement_exclusion_reason(volume)
      case volume.state
      when VOLUME_STATE_ONLINE
        return nil if volume.volume_path.to_s.strip.present?

        'it answers no mount path on the node it was read from, and a path is never synthesised from the volume name'
      when VOLUME_STATE_OFFLINE
        'it is offline (cluster resource state 3)'
      when nil
        'it answered no cluster resource state at all'
      else
        "it answers cluster resource state #{volume.state.inspect}, which is neither " \
        'measured Online (2) nor Offline (3)'
      end
    end

    # A machine placed into a cluster is clustered by default; the planned HA
    # checkbox is the way to opt out, and until the form has one, only ha_enabled=0
    # (API and hammer) says so.
    def clusterize?(attr)
      attr[:ha_enabled].to_s != '0'
    end

    # PLG-30: does the installed fog answer the cluster role failback
    # contract? The same two-part shape the enablement check uses — the
    # capability constant (a fog too old to define it answers "nothing") and
    # a vocabulary probe on the client itself (a fog with the list but not
    # the request is not this build's partner, and vice versa). A raise is an
    # unanswered question, same rule as client_answers?. This gates the
    # failback write and the failback word in the Registration column; it
    # deliberately does NOT join the enablement six — enablement is the era
    # partnership every unlocked operation runs on, and failback is one
    # opt-in setting riding on top of it.
    def cluster_failback_supported?
      list = Fog::Hyperv.const_defined?(:CAPABILITIES) ? Fog::Hyperv::CAPABILITIES : []
      list.include?(:cluster_role_failback) &&
        client.respond_to?(:set_cluster_virtual_machine_role_auto_failback)
    rescue StandardError
      false
    end

    # PLG-31b: does the installed fog carry the cluster owner-node READ —
    # each role answering preferred_node_names? The capability constant is
    # the whole client-side question here: unlike failback's write there is
    # no request method to probe, because the owner list is a FIELD of the
    # role read the plugin already performs, not an extra shell. The other
    # half of the check lives where the roles are — cluster_ha_settings only
    # speaks owners when the role in hand responds to preferred_node_names,
    # which catches the mismatched partner a constant alone would bless.
    # A raise is an unanswered question, same rule as every gate beside it.
    def cluster_owner_nodes_supported?
      list = Fog::Hyperv.const_defined?(:CAPABILITIES) ? Fog::Hyperv::CAPABILITIES : []
      list.include?(:cluster_role_owner_nodes)
    rescue StandardError
      false
    end

    # PLG-36: the write gate. Unlike the read's field, the write IS a request
    # with a client method, so this gate probes both halves the fork's gating
    # rule asks for — the constant (a partner that never promised the contract
    # must not be blessed by a method name alone) AND the client method (a
    # constant alone would bless a mismatched partner whose client cannot send
    # the request). A raise is an unanswered question: closed.
    def cluster_owner_nodes_write_supported?
      list = Fog::Hyperv.const_defined?(:CAPABILITIES) ? Fog::Hyperv::CAPABILITIES : []
      list.include?(:cluster_role_owner_nodes_write) &&
        client.respond_to?(:set_cluster_virtual_machine_role_owner_nodes)
    rescue StandardError
      false
    end

    # bootdisk PR-2: the pull gate — constant AND request method, exactly the
    # cluster-role rule. :file_pull sits on the plugin's opt-in side and is
    # deliberately NOT an enablement entry: the enablement map pairs each word
    # with a supports_*? predicate, fog defines no predicate for the bootdisk
    # pair, and a predicate-less entry on the enablement side would answer
    # "missing" against the deployed fog and refuse every unlocked operation.
    def bootdisk_file_pull_supported?
      list = Fog::Hyperv.const_defined?(:CAPABILITIES) ? Fog::Hyperv::CAPABILITIES : []
      list.include?(:file_pull) && client.respond_to?(:fetch_url_to_path)
    rescue StandardError
      false
    end

    # bootdisk PR-2: the scoped-delete gate, same rule and same reasons.
    def bootdisk_contained_file_removal_supported?
      list = Fog::Hyperv.const_defined?(:CAPABILITIES) ? Fog::Hyperv::CAPABILITIES : []
      list.include?(:contained_file_removal) && client.respond_to?(:remove_file)
    rescue StandardError
      false
    end

    # bootdisk PR-2: the operations fog grew for the bootdisk ride requests
    # with no capability word of their own (the eject, the DVD reads/writes,
    # the boot-order pair); the constant cannot bless a partner whose client
    # cannot send them, so the methods are probed directly. A fog that cannot
    # answer the probe gets a refusal naming what it lacks.
    def require_fog_requests!(*requests)
      missing = requests.reject { |request| client.respond_to?(request) }
      return if missing.empty?

      raise ForemanHyperv::OperationRefused, format(BOOTDISK_REQUEST_REFUSAL, requests: missing.join(', '))
    end

    # bootdisk PR-2: the era gate plus the pull gate, in that order — the era
    # first because the pull rides the same hardened transport every unlocked
    # operation rides, and an era mismatch is the older, larger fact.
    def require_bootdisk_pull!
      refuse_without_enablement!
      return if bootdisk_file_pull_supported?

      raise ForemanHyperv::OperationRefused,
            format(BOOTDISK_CAPABILITY_REFUSAL, capability: :file_pull, request: 'fetch_url_to_path')
    end

    # The ride's machine gates, shared by iso_upload and iso_attach, reading
    # fog's OWN shapes (round 17, finding 4): server.state is the hypervenum
    # (:Off/:Running/...), server.generation is :BIOS/:UEFI, and
    # computer_name is the node whose Get-VM printed the row. The
    # endpoint-node rule is the fail-closed one every other cluster write
    # rides: on a clustered CR the ISO lands on the cluster shared volume, so
    # the ride may only run when the node that owns the machine is the node
    # this endpoint is. A stand-alone host answers no cluster and passes.
    def bootdisk_ride_check!(vm_id)
      server = find_vm_by_uuid(vm_id)
      raise ForemanHyperv::OperationRefused, format(BOOTDISK_NO_MACHINE_REFUSAL, vm_id: vm_id) unless server

      state = server.state
      raise ForemanHyperv::OperationRefused, format(BOOTDISK_POWER_REFUSAL, state: state.inspect) if state != :Off

      generation = server.generation
      unless generation == :UEFI
        raise ForemanHyperv::OperationRefused, format(BOOTDISK_GEN1_REFUSAL, generation: generation.inspect)
      end

      node = reading_node(server)
      if endpoint_cluster && node.present? && !endpoint_serves_node?(node)
        raise ForemanHyperv::OperationRefused, format(BOOTDISK_NODE_REFUSAL, node: node)
      end

      server
    end

    # The storage_id must be a root the HOST reported — the same fail-closed
    # rule as the provision path's storage_root guard — matched case- and
    # trailing-separator-insensitively, and the host's own spelling is what
    # downstream joins use. The caller reads storage_roots exactly once.
    def bootdisk_storage_root!(storage_id, step, phase, roots)
      asked = storage_id.to_s.strip.chomp('\\')
      match = roots.to_a.find { |root| root.to_s.chomp('\\').casecmp(asked).zero? }
      unless match
        raise ArgumentError, "#{step}: storage_id #{storage_id.inspect} is not a storage root the host " \
                             "reported (#{roots.to_a.inspect}). Nothing was #{phase}."
      end
      match.to_s.chomp('\\')
    end

    # The host-side path for a bootdisk file: the root the HOST reported
    # joined to a name validated bare by bootdisk_filename! (no separators,
    # no traversal), so the single backslash here is the whole join. The
    # plugin does not reach for Fog::Hyperv::PathJoin — the installed gem
    # loads it only with the request files, and re-implementing a guard whose
    # inputs are already validated is honest at four lines.
    def bootdisk_host_path(root, name)
      "#{root.to_s.chomp('\\')}\\#{name}"
    end

    # iso_attach and iso_delete receive a bare filename (core hands
    # iso_attach File.basename(isofile)). A path-shaped or traversing name
    # would die in PathJoin's separator guard anyway; refusing here names the
    # step that received it.
    def bootdisk_filename!(value, step)
      name = value.to_s.strip
      raise ArgumentError, "#{step} requires a filename" if name.blank?
      if name.include?('\\') || name.include?('/') || name == '.' || name == '..'
        raise ArgumentError, "#{step} received #{name.inspect}, which is not a bare filename"
      end

      name
    end

    # fog's drive reads answer in three shapes — nil when the VM has no DVD drive, ONE
    # bare Hash when it has one, an Array of Hashes when it has several (all three measured
    # on the lab host 2026-11-24). Array() turns the Hash into [key, value] pairs and
    # Hash#first is one pair, so both would lie; normalizing once here is the honest fix.
    def dvd_drive_list(answer)
      case answer
      when nil then []
      when Array then answer
      else [answer]
      end
    end

    # iso_attach's boot-order composition: the DVD first, named by drive id
    # (the one class fog's request contract lets a caller name), then every
    # requestable class the read showed in read order, deduplicated, DvdDrive
    # removed — a File boot entry has no requestable class (its Device is
    # null, the F5 measurement) and fog's write script keeps unrequested
    # entries' positions, so dropping it here preserves it rather than
    # deleting it.
    def boot_order_with_dvd_first(dvd_id, rows)
      classes = Array(rows).filter_map do |entry|
        case entry[:boot_type].to_s
        when 'Network' then 'VMNetworkAdapter'
        when 'Drive' then entry[:device_text].to_s[/\A\s*([A-Za-z]+(?:Drive|Adapter))/, 1]
        end
      end
      [{ 'DvdDrive' => dvd_id }, *classes.uniq.reject { |klass| klass == 'DvdDrive' }]
    end

    # iso_upload/iso_attach storage scope: the storage_id arrives from the
    # build form, and it is honoured ONLY where it names a path the host
    # itself reported (a reported CSV mount path, a reported config/disk
    # root) — case and separator spelling are folded for the comparison, and
    # the ANSWER is the host's own spelling, so what travels to fog is what
    # the host would print. Anything else is nil: a path nobody reported has
    # no business receiving the ISO.
    def reported_root(storage_id)
      wanted = normalize_windows_path(storage_id).downcase
      storage_roots.detect { |root| normalize_windows_path(root).downcase == wanted }
    end

    # PLG-36: the edit form's Preferred owners list, applied by save_vm.
    # The silences and the one early refusal:
    #   * a fog that cannot write owners refuses a key that did arrive (the
    #     PLG-30 rule beside the failback checkbox: never silently drop what
    #     the operator sent) — the form would not have offered the control,
    #     so an arriving key came from an API-shaped compute_attributes;
    #   * a machine the cluster carries no role for is left alone, not
    #     refused: the control renders only on a clustered machine, so a key
    #     with no role behind it is an attribute that outlived a role removed
    #     outside Foreman, and every later save must not brick on it;
    #   * a selection EQUAL to the cluster's answer spends no write — names
    #     compared case-insensitively because the cluster is measured (§76)
    #     not to preserve the case it was handed; a current state that is
    #     unknown (nil) or unreported cannot disprove change, so the write is
    #     attempted and fog's own read-back decides whether it landed.
    # The write itself carries every remaining decision (membership,
    # canonicalisation, the cluster's refusals) — see
    # set_cluster_vm_preferred_owners.
    def apply_preferred_owners(vm, submitted)
      unless cluster_owner_nodes_write_supported?
        raise ForemanHyperv::OperationRefused,
              'this fog build cannot write cluster preferred owners; the compute resource refuses ' \
              'the setting rather than dropping it'
      end

      ha = cluster_ha_settings(vm)
      return unless ha.found?

      names = Array(submitted).map { |node| node.to_s.strip }.reject(&:empty?)
      current = ha.preferred_node_names
      return if current.is_a?(Array) &&
                names.map(&:downcase).sort == current.map { |node| node.to_s.downcase }.sort

      set_cluster_vm_preferred_owners(vm, names)
    end

    # PLG-21a. Put the machine into the cluster and PROVE it: fog writes over
    # WinRM are indeterminate once the request has been sent — measured at the
    # pinned fog, a successful Add raises Fog::JSON::DecodeError on its empty
    # reply — so the write's silence is not success and its exception is not
    # failure. Only finding the role by the machine's id in a readback answers
    # yes. The read is a cluster read on the compute resource's own endpoint
    # (any node's cluster service answers for the whole cluster — measured), not
    # a per-node call, so it needs no node targeting. Anything else — fog's
    # exception, a raising readback, or absent/partial roles after
    # ROLE_READBACK_ATTEMPTS tries — is indeterminate: the strand record goes to
    # the log, and StrandIndeterminate stops the caller from tearing anything
    # down. The fog call being absent (fog too old to add roles) still raises
    # BEFORE anything is sent, which keeps its deterministic rollback.
    # PLG-27: the Add rides the client that built the machine (default: this
    # resource's own client), dialled at an identity THAT client's host set
    # registers (default: the model's name, which is honest when the model is
    # self-rung). The proof is unchanged either way — the role readback stays
    # a cluster read on the resource's own endpoint, which every node of the
    # cluster answers for.
    def add_cluster_role_proven(vm, service: client, target: vm.computer_name)
      unless service.respond_to?(:add_cluster_virtual_machine_role)
        raise Foreman::Exception, 'Placing a virtual machine in a cluster needs a fog-hyperv that can add cluster roles'
      end

      send_error = nil
      begin
        # Everything from here on is post-send: after this line every exception
        # class — including fog's decode error on a success — is indeterminate
        # and belongs to the readback, not to a rollback.
        service.add_cluster_virtual_machine_role(id: vm.id, computer_name: target)
      rescue StandardError => e
        send_error = e
      end

      ROLE_READBACK_ATTEMPTS.times do |attempt|
        if attempt.positive?
          # The per-attempt cap is the WinRM operation timeout; this is the gap
          # between attempts, so a slow-but-committing Add is still caught.
          sleep ROLE_READBACK_INTERVAL
        end

        found, readback_error = readback_finds_role?(vm)
        return true if found

        # Keep the first readback failure: with no send error it is the one the
        # strand record quotes; with a send error the send tells the story.
        send_error ||= readback_error
      end

      record_role_strand(vm, send_error)
      # The params go to the constructor (Foreman::Exception#initialize takes
      # message plus params); passing them as raise's third argument would make
      # Ruby read them as a backtrace.
      raise StrandIndeterminate.new(strand_message_template(send_error), strand_message_params(vm, send_error))
    end

    # One pass of the proof. A role counts as found when it carries the
    # machine's id (case-insensitively: fog's own collection filters -VMId
    # case-insensitively too), or when the id property is empty — the field is
    # reported on ClusterGroup but not documented, so it may be missing on real
    # hosts — and the role's documented name is this machine's. Anything that
    # matches neither is not this machine's role: an absent answer here is a
    # clean "no", which is still not a proof either way.
    def readback_finds_role?(vm)
      roles = Array(client.cluster_virtual_machine_roles.all(vm_id: vm.id)).flatten.compact
      wanted_role_name = "#{ROLE_NAME_PREFIX}#{vm.name}"
      found = roles.any? do |role|
        role_id = role.respond_to?(:virtual_machine_id) ? role.virtual_machine_id : nil
        if role_id.presence
          role_id.to_s.casecmp(vm.id.to_s).zero?
        else
          role.name.to_s.casecmp(wanted_role_name).zero?
        end
      end
      [found, nil]
    rescue StandardError => e
      # A readback that cannot answer is not an absent readback: the attempt
      # counts, but the strand record quotes this as its reason.
      [false, e]
    end

    # The strand record (B6): what was asked for, where it was left, and why the
    # plugin will not guess — in the log for the operator in front of the console,
    # and in the sightings ledger (kind strand, PLG-21b's migration) for every
    # later decision that must not forget this machine. The ledger write is
    # best-effort in one specific sense: if it fails, the touch-nothing contract
    # still holds, because the StrandIndeterminate raise that follows is the
    # refusal with or without the row — but the failed write is said out loud,
    # because an operator who later trusts the ledger needs to know this strand
    # only made it to the log.
    def record_role_strand(vm, error)
      logger.warn format(
        'Hyper-V cluster role strand: virtual machine %<uuid>s (name %<name>s) at %<path>s was asked ' \
        'to join the cluster and the outcome is unproven (%<reason>s). Left untouched: machine, disks, ' \
        'role. An operator must reconcile it by hand.',
        uuid: strand_param(vm&.id), name: strand_param(vm&.name), path: strand_param(vm&.path),
        reason: strand_reason(error)
      )
      persist_cluster_sighting(kind: 'strand', vm_uuid: vm&.id, vm_name: vm&.name, reason: strand_reason(error))
    rescue StandardError => e
      logger.error "The strand ledger record could not be written (the log record above is all there is): #{e.class}"
    end

    # Either the send's own first line, or the fact that no readback ever
    # answered. Both go through the sanitizer, so neither can carry a percent
    # sign or a control character into the log line.
    def strand_reason(error)
      return 'readback-empty' unless error

      "#{strand_param(error.class.name)}: #{sanitize_text(error.message.to_s.lines.first)}"
    end

    # The template and params are handed to Foreman::Exception, which sprintfs
    # them once at render time — the values never become part of the template,
    # so a percent sign in one of them cannot break the render.
    def strand_message_template(error)
      error ? ROLE_STRAND_FAILURE : ROLE_STRAND_EMPTY
    end

    def strand_message_params(vm, error)
      base = {
        uuid: strand_param(vm&.id),
        path: strand_param(vm&.path),
        name: strand_param(vm&.name)
      }
      if error
        base[:error_class] = strand_param(error.class.name)
        base[:first_line] = sanitize_text(error.message.to_s.lines.first)
      end
      base
    end

    # Identifiers the plugin itself holds (a GUID from fog, a fog-reported path,
    # a validated name) kept safe for a sprintf target: no percent sign, no
    # control characters, bounded length.
    def strand_param(value)
      value.to_s.gsub(/[^[:print:]]/, '').delete('%').truncate(200)
    end

    # fog's own text, made safe the same way. Kept to one line and 200
    # characters: this is a quotation for operators, not a transcript.
    def sanitize_text(text)
      text.to_s.gsub(/[^[:print:]]/, '').delete('%').truncate(200)
    end

    # Takes the clustered role off a machine, leaving the machine itself alone. A
    # role the cluster will not give up stops the teardown rather than continuing
    # under it: deleting a machine whose role still points at its files leaves the
    # cluster holding a claim on storage that no longer describes anything, which is
    # worse to clean up than a machine that refused to delete.
    #
    # F2 (due before this PR, and landed here): when the enablement stands, the
    # removal rides a two-element cmdlist whose FIRST element is the node-identity
    # guard — every connection shell is its own shell (measured), so a guard in a
    # separate read could answer for one machine and the mutation run on another.
    # The guard throws server-side when the machine dialled is not the node named,
    # and fog's own error detection carries that out as a refusal; the second
    # element is fog's own removal script, whose readback (the measured
    # ClusterObjectNotFound miss) is the proof the removal happened — the plugin
    # duplicates nothing of that contract, it only composes the guard in front.
    # An older fog without the script utility or the cmdlist API keeps the plain
    # request call, unguarded, exactly as before enablement.
    def remove_cluster_role(vm)
      node = ((vm.respond_to?(:owner_node) && vm.owner_node.presence) || vm.computer_name).to_s.strip
      service = vm.service || client

      # Validated before composing anything: an id that is not an id is the
      # user's bad input, not a cluster that refused.
      ForemanHyperv::InputValidation.validate_id!(vm.id)
      # Composed before any rescue can fold it: a name that cannot be quoted
      # into the guard is refused as itself, not as a cluster that "would not
      # release the role" — it never reached the cluster.
      guard = guarded_role_guard(node)

      begin
        if guard
          script = Fog::Hyperv::Utils::ClusterRole.build_removal_script(vm.id)
          out = service.run_cmdlist([[guard, {}], [script, {}]], target_computer: node, skip_json: true)
          # fog's own removal contract, kept at the call site that composes it:
          # the script prints nothing on any path, so a body is not an answer
          # this plugin knows.
          unless out.stdout.to_s.strip.empty?
            logger.warn 'The clustered role removal answered with a result body; it emits none'
            raise Foreman::Exception,
                  'Refusing to delete a clustered virtual machine while its role removal did not answer cleanly'
          end
        elsif client.respond_to?(:remove_cluster_virtual_machine_role)
          client.remove_cluster_virtual_machine_role(id: vm.id, computer_name: node)
        end
      rescue StandardError => e
        # A fog failure's own text can carry the remote command line, including
        # percent signs, and Foreman::Exception sprintfs its message again when
        # it renders: the class is quoted, the text is not.
        logger.warn "The Hyper-V cluster would not release the role: #{e.class}"
        raise Foreman::Exception,
              'Refusing to delete a clustered virtual machine while the cluster still holds its role'
      end
    end

    # The guard script, or nil when this build/era does not compose one (the
    # pre-enablement fog paths). The candidates are the node's own name and the
    # first label of the identity that reaches it — each with its 15-character
    # truncation, because $env:COMPUTERNAME answers the NETBIOS name, which is
    # uppercase and capped at 15 while cluster reads and operator overrides
    # carry the full DNS-flavoured name (memory of the lab, pre-registered as
    # the >15-character red test: the guard must not false-refuse a long name
    # that is honestly the machine's own). PowerShell's -notin is
    # case-insensitive; no case folding rides the wire beyond these terms.
    def guarded_role_guard(node)
      return nil unless enablement_supported?
      return nil unless client.respond_to?(:run_cmdlist) && cluster_role_script_available?

      identity = node_override(node).to_s.split(':', 2).first.to_s
      candidates = [node, identity.split('.').first].reject { |c| c.to_s.empty? }
      candidates.each do |candidate|
        unless candidate.match?(NODE_NAME_SHAPE)
          raise ForemanHyperv::OperationRefused,
                'Refusing to remove a cluster role while the target node name is not a name this ' \
                'plugin can put through its identity guard; nothing was asked of the host with that name'
        end
      end
      terms = candidates.flat_map { |c| [c, c[0, NETBIOS_MAX_LENGTH]] }.map(&:downcase).uniq
      quoted = terms.map { |term| "'#{term.gsub("'", "''")}'" }.join(', ')
      %(if ($env:COMPUTERNAME -notin @(#{quoted})) { throw "foreman_hyperv node identity mismatch: $env:COMPUTERNAME" })
    end

    # The utility ships with the fog the enablement names; an older fog raises
    # LoadError or simply lacks the builder, and both answer "no guard for you"
    # — the legacy request path runs instead, unguarded, as it did before.
    def cluster_role_script_available?
      require 'fog/hyperv/utils/cluster_role'
      Fog::Hyperv::Utils::ClusterRole.respond_to?(:build_removal_script)
    rescue LoadError, NameError
      false
    end

    # The machine as the node that owns it right now sees it, or nil when no cluster
    # role claims it — the whole point being the case where the endpoint no longer
    # answers for it. Every action on a machine starts with this lookup, so the
    # node this asks is addressed by an IDENTITY that resolves, never by the
    # role's unqualified name (N5, §45.3): the override host when the operator
    # supplied one (PLG-5a), the endpoint host when the owner is the endpoint's
    # own node, the address the cluster gives the node under the client-role
    # pick rule (PLG-5b), and nothing else — a node with no usable identity is
    # refused its reads by name, and no fog call carries its unqualified name.
    def vm_from_cluster_owner(uuid)
      # Checked before the StandardError rescue below can fold it into nil: a
      # hostile id must raise, not answer "no owner", and this read takes the
      # id to fog, so GUID-only here as well (find_vm_by_uuid already refuses
      # it; this is the same gate at the second door).
      ForemanHyperv::InputValidation.validate_id!(uuid)
      return nil unless client.respond_to?(:cluster_virtual_machine_roles) &&
                        client.respond_to?(:supports_clusters?) && client.supports_clusters?

      role = [client.cluster_virtual_machine_roles.all(vm_id: uuid)].flatten.compact.first
      return nil unless role&.owner_node

      owner = role.owner_node.to_s.strip
      override = node_override(owner)
      drop_hypervisor_list_unless_named(owner)
      if override
        identity_host = override.split(':', 2).first
        logger.info "Virtual machine #{uuid} is owned by cluster node #{owner}, reading it from its override endpoint"
        return client_for_node(owner).servers.get(uuid, computer_name: identity_host)
      end

      if endpoint_serves_node?(owner)
        logger.info "Virtual machine #{uuid} is owned by this endpoint's own node, reading it here"
        return client.servers.get(uuid, computer_name: endpoint_host_name)
      end

      # PLG-5b rung 3: the cluster itself names the node's address. A node
      # the read cannot answer for raises naming itself — fog would take the
      # unqualified name to its completion sink, the prefix-cache path that
      # can complete against the WRONG endpoint and fake a pass (R22), so the
      # name never leaves here without an address behind it.
      address = discover_node_address(owner)
      logger.info "Virtual machine #{uuid} is owned by cluster node #{owner}, reading it at the cluster's address"
      client_for_node(owner).servers.get(uuid, computer_name: address)
    rescue StandardError => e
      raise if e.is_a?(ForemanHyperv::UnsafeIdentifier)

      # A refusal to compose (R17) is a decision, not an unreadable wire: it
      # travels up as itself instead of being folded into the nil that says
      # "no owner answered" — the same rule cluster_membership_state applies
      # to the ledger's own refusal.
      raise if e.is_a?(ForemanHyperv::OperationRefused)

      logger.warn "Clustered lookup of virtual machine #{uuid} failed: #{e.message.lines.first}"
      nil
    end

    # --- PLG-5a: the operator node→endpoint override ---------------------------

    # The attribute parsed: downcased node names (the role carries NETBIOS
    # casing; the operator may type any), values exactly as written. A node
    # named twice means the last line wins — both were seen by the same shape
    # check, and refusing the save over which-of-two was meant would punish
    # the trailing comment-out with an error.
    def node_override_map
      @node_override_map ||= hyperv_node_overrides.to_s.each_line.filter_map do |line|
        next if line.strip.empty?

        node, value = line.split('=', 2)
        next if node.nil? || value.nil? || node.strip.empty? || value.strip.empty?

        [node.strip.downcase, value.strip]
      end.to_h
    end

    def node_override(node_name)
      node_override_map[node_name.to_s.strip.downcase]
    end

    # The composed per-node endpoint (N4): scheme and port come from the
    # compute resource; the identity is the override value (PLG-5a) or the
    # address the cluster gives the node (PLG-5b) — never the role's
    # unqualified name. The path is /wsman because WinRM always answers
    # there. The R17 check is on this composition, and an unparseable
    # endpoint has no measured scheme either, so it refuses too.
    def node_endpoint(node_name)
      override = node_override(node_name)
      identity_host, identity_port =
        if override
          override.split(':', 2)
        else
          [discover_node_address(node_name), nil]
        end
      base = begin
        URI.parse(url.to_s)
      rescue URI::Error
        nil
      end
      composed = format('%<scheme>s://%<host>s:%<port>s/wsman',
                        scheme: base&.scheme,
                        host: identity_host,
                        port: identity_port || base&.port)
      case base&.scheme
      when 'http'
        composed
      when 'https'
        # PLG-32: the operator's explicit opt-out composes https for ANY
        # identity, exactly as http does — hostname verification is the exact
        # thing switching verification off removes, so it can no longer be the
        # refusal's reason, and fog carries the opt-out on the wire. The
        # scheme-sanity refusal below is NOT relaxed: the opt-out is about
        # certificate trust, not about garbage URLs.
        unless hyperv_ssl_verify == false
          if NODE_IPV4.match?(identity_host)
            raise ForemanHyperv::OperationRefused, format(NODE_TLS_IP_REFUSAL, endpoint: composed)
          end

          if hyperv_ca_trust_path.blank?
            raise ForemanHyperv::OperationRefused, format(NODE_TLS_TRUST_REFUSAL, endpoint: composed)
          end
        end

        composed
      else
        raise ForemanHyperv::OperationRefused, format(NODE_ENDPOINT_REFUSAL, endpoint: composed)
      end
    end

    # A SEPARATE Fog::Compute per node (N4): hyperv_host is never passed, so
    # fog cannot compose an endpoint from it behind our back; the endpoint
    # arrives complete. An https composition arrives here only with a named CA
    # file or under the PLG-32 opt-out (node_endpoint), and fog's default trust
    # store does not see the system anchors on this platform (row (w)), so the
    # named file rides the option in every case and the opt-out rides when
    # taken. One instance per node per resource, so one connection cache per
    # node — R22's "exactly one connection" is about THIS instance.
    def client_for_node(node_name)
      @node_clients ||= {}
      @node_clients[node_name.to_s.strip.downcase] ||=
        Fog::Compute.new(fog_client_options(node_endpoint(node_name)))
    end

    # PLG-33b: an INDEPENDENT client for the same endpoint the resource's own
    # client dials. The WinRM layer underneath a fog client is per-connection
    # scratch (the codegen shell's script file, the operation's receive
    # state), so a second thread reading the endpoint while the first is
    # mid-read must NOT share the client — it gets its own. Trust, opt-out and
    # waits are identical by construction: both clients come from
    # fog_client_options. Never cached; the caller owns this one and every hop
    # on it is bounded by the PLG-16 waits, so a discarded speculative read
    # cannot outlive the request that started it.
    def fresh_endpoint_client
      Fog::Compute.new(fog_client_options(url))
    end

    # PLG-33b: the same independence for a node-routed dial (the pipeline's
    # speculative node-list read routes exactly like client_for_node but owns
    # its own connection). Uncached by the same rule.
    def fresh_node_client(node_name)
      Fog::Compute.new(fog_client_options(node_endpoint(node_name)))
    end

    # --- PLG-5b: the address the cluster gives its own nodes ---------------------

    # One shell, one JSON answer, per the measured cluster-read rules: the
    # answering cluster is witnessed FIRST (an empty interface list from a
    # cluster that answered is a contradiction the caller refuses, and it is
    # only visible next to the name); both legs are wrapped in @() because
    # PowerShell collapses an empty pipeline to $null and a one-element
    # ConvertTo-Json to a bare object; the network Role is joined
    # server-side because the raw MSCluster_NetworkInterface Roles came back
    # EMPTY on this build (the (w) MSI row), while the cmdlets answer the
    # full shape; Node and Network arrive as STRINGS, not objects — reading
    # .Node.Name read empty on the live cluster (the row that caught this)
    # and a silently empty label would drop every interface off the map;
    # and no early-terminating Select-Object anywhere (evidence §2: it kills
    # cluster cmdlet pipelines).
    def cluster_node_address_script
      <<~SCRIPT
        $WarningPreference = 'SilentlyContinue'
        $cluster = Get-Cluster
        $networkRoles = @{}
        @(Get-ClusterNetwork) | ForEach-Object { $networkRoles[[string]$_.Name] = $_.Role }
        $interfaces = @(@(Get-ClusterNetworkInterface) | ForEach-Object {
          [PSCustomObject]@{
            node = [string]$_.Node
            adapter = [string]$_.Name
            network = [string]$_.Network
            address = [string]$_.Address
            netRole = $networkRoles[[string]$_.Network]
          }
        })
        @{ clusterName = [string]$cluster.Name; interfaces = $interfaces } | ConvertTo-Json -Compress -Depth 4
      SCRIPT
    end

    # label → candidate addresses, and the envelope refusal. One read per
    # compute-resource instance: the whole cluster answers, so two lookups
    # are not two reads — and a refusal is cached too, because a cluster
    # that could not answer once has not learned anything between two
    # decisions in the same request.
    def cluster_node_addresses
      unless defined?(@cluster_node_addresses)
        @cluster_node_address_refusal = nil
        begin
          @cluster_node_addresses = read_cluster_node_addresses
        rescue ForemanHyperv::OperationRefused => e
          @cluster_node_addresses = {}
          @cluster_node_address_refusal = e.message
        end
      end
      @cluster_node_addresses
    end

    # The node's dialable address as the cluster itself states it, or a
    # refusal that names the node and the reason — never a guess. The pick
    # rule is the measured one: an interface counts for placement traffic
    # only when its cluster network carries Role = 3 (cluster AND client);
    # the internal-only net (Role 1) holds addresses no client can dial.
    # The node is named downcased: the cluster answers in NETBIOS casing,
    # the map's keyspace is downcased, and the operator must be able to
    # grep the refusal for the name they typed.
    def discover_node_address(node_name)
      node = node_name.to_s.strip.downcase
      if cluster_node_addresses && @cluster_node_address_refusal
        raise ForemanHyperv::OperationRefused,
              format(NODE_ADDRESS_REFUSAL, node: node, reason: @cluster_node_address_refusal)
      end

      seen = @cluster_node_addresses[node.split('.').first]
      if seen.nil?
        raise ForemanHyperv::OperationRefused,
              format(NODE_ADDRESS_REFUSAL, node: node, reason: NODE_ADDRESS_NO_ROWS)
      end

      candidates, client_role = seen
      unless client_role
        raise ForemanHyperv::OperationRefused,
              format(NODE_ADDRESS_REFUSAL, node: node, reason: NODE_ADDRESS_NO_CLIENT_ROLE)
      end

      if candidates.size > 1
        ambiguous = format(NODE_ADDRESS_AMBIGUOUS, candidates: candidates.join(', '))
        raise ForemanHyperv::OperationRefused, format(NODE_ADDRESS_REFUSAL, node: node, reason: ambiguous)
      end

      address = candidates.first
      unless NODE_IPV4.match?(address.to_s)
        not_ipv4 = format(NODE_ADDRESS_NOT_IPV4, address: address)
        raise ForemanHyperv::OperationRefused, format(NODE_ADDRESS_REFUSAL, node: node, reason: not_ipv4)
      end

      address
    end

    # The read and its envelope, refuse-don't-guess: silence, undecodable
    # JSON, a missing cluster witness, and an answering cluster with no
    # interfaces at all each refuse before any node is picked; a collapsed
    # one-element answer is normalised back to a list (measured on this
    # build). Returns label → [candidate addresses, saw-client-role?].
    def read_cluster_node_addresses
      raise ForemanHyperv::OperationRefused, NODE_ADDRESS_CLIENT_REFUSAL unless client.respond_to?(:run_cmd)

      reply = begin
        client.run_cmd(cluster_node_address_script, _skip_json: true).stdout.to_s.strip
      rescue StandardError => e
        raise ForemanHyperv::OperationRefused, "the cluster address read did not answer (#{e.class})."
      end
      parsed = begin
        Fog::JSON.decode(reply)
      rescue StandardError
        raise ForemanHyperv::OperationRefused, 'the cluster address read answered no decodable JSON.'
      end
      unless parsed.is_a?(Hash)
        raise ForemanHyperv::OperationRefused, 'the cluster address read answered no decodable JSON.'
      end

      if parsed['clusterName'].to_s.strip.empty?
        raise ForemanHyperv::OperationRefused,
              'the answer names no answering cluster, so its interface list proves nothing.'
      end

      rows = case parsed['interfaces']
             when Array then parsed['interfaces']
             when Hash then [parsed['interfaces']]
             else []
             end
      if rows.empty?
        raise ForemanHyperv::OperationRefused,
              "#{parsed['clusterName']} answered with no cluster network interfaces at all — a cluster " \
              'that answers and names no interface is a contradiction, not an empty directory.'
      end

      rows.each_with_object({}) do |row, map|
        next unless row.is_a?(Hash)

        label = row['node'].to_s.strip.split('.').first.to_s.downcase
        next if label.empty?

        candidates, client_role = map.fetch(label, [[], false])
        address = row['address'].to_s.strip
        if row['netRole'].to_i == 3
          candidates << address unless candidates.include?(address)
          client_role = true
        end
        map[label] = [candidates, client_role]
      end
    end

    # Whether the role's owner is the node this endpoint itself serves: the
    # endpoint host fully qualified, or as the bare first label the NETBIOS
    # name carries (case-insensitive). A first-label collision across two
    # domains reads from the endpoint, misses, and answers nil — a miss,
    # never a wrong machine, because GUIDs are unique and a node that does
    # not host the GUID answers NotFound.
    def endpoint_serves_node?(node_name)
      endpoint = endpoint_host_name
      return false if endpoint.nil? || node_name.blank?

      asked = node_name.to_s.strip.downcase
      asked == endpoint || asked == endpoint.split('.').first
    end

    # Each non-blank line must read NODE = host[:port]. The error names the
    # line's node verbatim, because the operator has to know WHICH line to
    # fix; the offending value rides in the message too.
    def hyperv_node_overrides_shape
      hyperv_node_overrides.to_s.each_line do |line|
        next if line.strip.empty?

        node, value = line.split('=', 2)
        if node.nil? || value.nil? || node.strip.empty? || value.strip.empty?
          errors.add(:hyperv_node_overrides, "line #{line.inspect} is not NODE = host[:port]")
          next
        end

        host, port = value.strip.split(':', 2)
        next if NODE_OVERRIDE_HOST.match?(node.strip) &&
                NODE_OVERRIDE_HOST.match?(host) &&
                (port.nil? || (NODE_OVERRIDE_PORT.match?(port) && port.to_i <= 65_535))

        errors.add(:hyperv_node_overrides,
                   "for node #{node.strip}: #{value.strip.inspect} is not a bare host or host:port " \
                   '(no scheme, no path, port 1-65535) — refused, not repaired')
      end
    end

    # PLG-5b: the CA file the hardened per-node compositions verify against,
    # read on the FOREMAN host where fog builds the trust store. Absolute,
    # plain-path characters only, no `..` normalization games — refused at
    # save naming the value verbatim, the same discipline as the override.
    def hyperv_ca_trust_path_shape
      value = hyperv_ca_trust_path
      return if value.blank?

      return if CA_TRUST_PATH_SHAPE.match?(value) && value.split('/').exclude?('..')

      errors.add(:hyperv_ca_trust_path,
                 "#{value.inspect} is not a plain absolute path (no spaces, no backticks, no " \
                 'subshell characters, no .. segments) — refused, not repaired')
    end

    def validate_vm(attr, new: false)
      # logger.debug "Validate VM #{attr.inspect}"
      raise Foreman::Exception, 'VM lacks generation' if new && attr[:generation].blank?
      raise Foreman::Exception, 'VM lacks memory' unless attr[:memory_startup].to_i.positive?
      raise Foreman::Exception, 'VM lacks CPUs' unless attr[:processor_count].to_i.positive?

      return unless Foreman::Cast.to_bool(attr[:dynamic_memory_enabled])
      raise Foreman::Exception, 'VM lacks memory minimum' unless attr[:memory_minimum].to_i.positive?
      raise Foreman::Exception, 'VM lacks memory maximum' unless attr[:memory_maximum].to_i.positive?
    end

    # Hyper-V has no firmware setting of its own: generation 1 VMs boot from BIOS,
    # generation 2 VMs from UEFI. Let Foreman resolve the firmware that was selected
    # for the host (including the PXE loader based 'automatic' firmware) and turn it
    # into the generation the VM has to be created with, along with the secure boot
    # settings that belong to the firmware.
    def apply_firmware_attributes(attr, set_generation: true)
      firmware_type = attr.delete(:firmware_type).to_s
      attr.merge!(process_firmware_attributes(attr[:foreman_firmware], firmware_type, attr[:provision_method]))

      # The generation is only set when a firmware was actually chosen, hosts that
      # carry no firmware at all keep the default generation.
      return attr if !set_generation || attr[:foreman_firmware].blank?

      firmware = resolve_automatic_firmware(attr[:firmware], firmware_type)
      attr[:generation] = firmware == 'bios' ? 1 : 2
      attr
    end

    def generate_secure_boot_settings(firmware)
      return {} unless firmware.to_s.include?('efi')

      {
        secure_boot_enabled: firmware.to_s.end_with?('secure_boot')
      }
    end

    def validate_interfaces(attr)
      interfaces = nested_attributes_for :interfaces, attr[:interfaces_attributes]
      interfaces.reject! { |iface| iface[:_destroy] == '1' }
      # logger.debug "Validate NIC #{interfaces.inspect}"
      interfaces.each do |iface|
        compute = iface[:compute_attributes] || iface
        case compute[:vlan_operation_mode].to_s
        when 'Untagged'
          # No VLAN settings to verify
        when 'Access'
          raise Foreman::Exception, 'Interface is missing access VLAN' unless compute[:access_vlan_id].to_i.positive?
        when 'Trunk'
          raise Foreman::Exception, 'Interface is missing native VLAN' unless compute[:native_vlan_id].to_i.positive?
          raise Foreman::Exception, 'Interface is missing allowed VLANs' if compute[:allowed_vlan_ids].blank?
        when 'Private'
          raise Foreman::Exception, 'Interface is missing primary VLAN' unless compute[:primary_vlan_id].to_i.positive?

          case compute[:vlan_private_mode].to_s
          when 'Promiscuous'
            if compute[:secondary_vlan_ids].blank?
              raise Foreman::Exception,
                    'Interface is missing secondary VLANs'
            end
          else
            unless compute[:secondary_vlan_id].to_i.positive?
              raise Foreman::Exception,
                    'Interface is missing secondary VLAN'
            end
          end
        else
          raise Foreman::Exception, 'Interface has unknown VLAN mode'
        end
      end
    end

    # PLG-26: a switch named by GUID is named for ONE node — the endpoint whose
    # list produced the id — while a virtual switch exists per node, the same
    # name being a different switch with a different GUID on every one of them
    # (measured twice, 28 and 33.3's E12b: a foreign GUID does not answer
    # empty, it RAISES "No Ethernet switch could be found matching the
    # specified criteria" on the node that lacks it). The name is what the
    # nodes share: this resource's network list offers only switches every
    # node answers by name, so the endpoint's GUID is translated back to that
    # name and the id dropped — fog then dials Get-VMSwitch -Name on the node
    # the machine actually lives on, which answers for that node's own switch
    # of that name. A GUID the endpoint's own list does not carry names a
    # switch missing even there: it rides on untouched, and the loud error it
    # earns is the honest answer, not a silent name miss.
    def resolve_nic_switch(iface)
      guid = iface[:switch_id].presence
      return iface unless guid

      shared = switches(nil).detect { |sw| sw.id.to_s.casecmp?(guid.to_s) }
      return iface unless shared

      iface.merge(switch_name: shared.name).except(:switch_id)
    end

    def create_interfaces(vm, attr)
      interfaces = nested_attributes_for :interfaces, attr[:interfaces_attributes]
      logger.debug "Creating interfaces with: #{interfaces}"

      first_provisioned = false
      interfaces.each do |iface|
        # The VM is pre-created with one NIC regardless of given creation options, so configure that one first
        nic = vm.network_adapters.first unless first_provisioned
        first_provisioned = true

        nic ||= vm.network_adapters.new
        resolve_nic_switch(iface.except(:identity, :ip, :ip6)).each do |k, v|
          nic.send(:"#{k}=", v.presence)
        end
        # nic.is_legacy = Foreman::Cast.to_bool(iface[:is_legacy]) if
        #   vm.generation == :BIOS && iface[:is_legacy].present?
        # logger.debug "Creating interface with #{iface.inspect} - #{nic.inspect}\n#{nic.vlan_setting.inspect}"
        nic.save
      end

      unless vm.network_adapters.all(_return_fields: %i[dynamic_mac_address_enabled])
               .any?(&:dynamic_mac_address_enabled)
        return
      end

      # Populate all non-populated MAC addresses
      vm.start
      vm.stop turn_off: true

      vm.network_adapters.reload.each do |nic|
        nic.dynamic_mac_address_enabled = false
        nic.save if nic.dirty?
      end
    end

    def update_interfaces(vm, attr)
      interfaces = nested_attributes_for :interfaces, attr[:interfaces_attributes]
      logger.debug "Updating interfaces with: #{interfaces}"

      interfaces.each do |interface|
        compute = resolve_nic_switch(interface[:compute_attributes])
        if compute[:identity].present?
          nic = vm.network_adapters.get compute[:identity]
          if interface[:_destroy] == '1'
            nic.destroy
          else
            compute.each do |k, v|
              nic.send(:"#{k}=", v.presence)
            end
            nic.mac ||= interface[:mac].presence
            nic.save
          end
        elsif interface[:_destroy] != '1'
          nic = vm.network_adapters.new
          compute.each do |k, v|
            nic.send(:"#{k}=", v.presence)
          end
          nic.mac ||= interface[:mac].presence
          nic.save
        end
      end
    end

    def validate_volumes(attr)
      volumes = nested_attributes_for :volumes, attr[:volumes_attributes]
      volumes.reject! { |vol| vol[:_delete] == '1' }
      # logger.debug "Validate Volume #{volumes.inspect}"
      volumes.each do |vol|
        raise Foreman::Exception, 'Volume lacks name' if vol[:basename].blank?
        raise Foreman::Exception, 'Volume name should not include a file extension' if vol[:basename] =~ /\.vhd[sx]?$/
        raise Foreman::Exception, 'Volume lacks size' unless vol[:size_bytes].to_i.positive?
      end
      return unless volumes.group_by { |vol| vol[:basename].downcase }.any? { |_k, v| v.many? }

      raise Foreman::Exception, 'Volume names need to be unique'
    end

    def create_volumes(vm, attr)
      volumes = nested_attributes_for :volumes, attr[:volumes_attributes]
      logger.debug "Creating volumes with: #{volumes}"
      volumes.each do |vol|
        # vm.vhds is fog-hyperv's own collection association: the collection
        # (and every machine built from it) is bound to THIS machine — the
        # trace measured the vhd's vm is the very model create_vm holds — so
        # fog's refused join (FOG-17) composes the disk folder from the
        # placement that model carries.
        vhd = vm.vhds.create basename: vol[:basename], size: vol[:size_bytes].to_i
        vm.hard_drives.create vhd: vhd
      end
    end

    def update_volumes(vm, attr)
      volumes = nested_attributes_for :volumes, attr[:volumes_attributes]
      logger.debug "Updating volumes with: #{volumes}"
      # PLG-22: every requested disk removal is DECIDED before any of them is
      # executed — an explicit removal that cannot prove its file safe refuses
      # the whole edit up front, rather than deleting two disks and refusing
      # on the third. A _delete reaching here already passed the capability
      # gate (refuse_disk_removal! runs on the submitted hash before anything
      # is fetched); the call-site rule below is the attribution half.
      deletions = volumes.filter_map do |volume|
        next unless volume[:id].present? && volume[:_delete] == '1'

        hd = vm.hard_drives.get volume[:id]
        raise ForemanHyperv::OperationRefused, DISK_UNATTRIBUTED_REFUSAL unless drive_deletion_allowed?(vm, hd)

        hd
      end
      deletions.each { |hd| hd.destroy(underlying: true) }

      volumes.each do |volume|
        if volume[:id].present?
          next if volume[:_delete] == '1'

          hd = vm.hard_drives.get volume[:id]
          vhd = hd.vhd
          vhd.size = volume[:size_bytes].to_i
          vhd.save if vhd.dirty?
        elsif volume[:_delete] != '1'
          vhd = vm.vhds.create basename: volume[:basename], size: volume[:size_bytes].to_i
          vm.hard_drives.create path: vhd.path
        end
      end
    end
  end
end
