# Foreman Hyper-V

[![Gem Version](https://badge.fury.io/rb/foreman_hyperv.svg)](https://badge.fury.io/rb/foreman_hyperv)

Microsoft Hyper-V compute resource for Foreman

Uses the in-development `fog-hyperv` gem found [here](https://github.com/ananace/fog-hyperv).

## Nota Bene

Currently the plugin only supports Hyper-V hosts where the names are well defined in DNS and in connection strings, avoid using IP addresses for now.

If you're using SELinux, Foreman needs to open the WinRM port. 5985 falls
inside the `vnc_port_t` range (5900-5999), so `foreman_rails_t` is not allowed
to connect to it and compute resources fail with a `Permission denied` connect
error while `ausearch -m avc` reports
`denied { name_connect } ... tcontext=vnc_port_t`. The broad solution is the
connect_all boolean: for Foreman 2.0 and earlier run
`setsebool -P passenger_can_connect_all 1`, for Foreman 2.1 and later
`setsebool -P foreman_rails_can_connect_all 1`. To stay narrow, allow just the
WinRM ports through a local policy module instead:

```console
ausearch -m avc -ts recent | audit2allow -m foreman_winrm > foreman_winrm.te
checkmodule -M -m -o foreman_winrm.mod foreman_winrm.te
semodule_package -o foreman_winrm.pp -m foreman_winrm.mod
semodule -i foreman_winrm.pp
```

## Hyper-V host prerequisites

The compute resource authenticates over WinRM, so on every host that should be
managed:

* `winrm quickconfig`, and over plain HTTP also
  `winrm set winrm/config/service '@{AllowUnencrypted="true"}'`
* an inbound firewall rule for TCP 5985 (5986 for HTTPS), ideally scoped to the
  Foreman server's address
* a service account in the local *Administrators* group. *Hyper-V
  Administrators* plus *Remote Management Users* is not enough: a WinRM logon
  is a network logon and Hyper-V rejects its un-elevated token with an
  "authorization policy" error on every cmdlet. Local (non-domain) accounts
  also need `LocalAccountTokenFilterPolicy=1`. Both are covered in the
  [`fog-hyperv` documentation](https://github.com/ananace/fog-hyperv#troubleshooting)

## Testing/Installing

Follow the Foreman manual for [advanced installation from gems](https://theforeman.org/plugins/#2.3AdvancedInstallationfromGems) for `fog-hyperv` and `foreman_hyperv`.

There are RPMs packaged for the `fog-hyperv` dependencies under [Release v0.0.1](https://github.com/ace13/foreman_hyperv/releases/tag/v0.0.1), or they too can be installed from gems.

Do bear in mind that this is still very early in development, so plenty of issues may exist.

### Which `fog-hyperv` you get

The plugin asks for `fog-hyperv ~> 0.2`, and the released 0.2.0 covers
standalone hosts: connecting, listing virtual switches and VMs, and creating,
editing and destroying VMs all work with it. Failover clusters are the
exception. `Compute#supports_clusters?` in 0.2.0 reads a field that the query
result no longer carries, so it answers false for every host and
`available_clusters` comes back empty even when the host belongs to a cluster.
That is fixed on `fog-hyperv`'s development branch, which has not been released,
so clustered hosts need the gem from source:

```console
gem 'fog-hyperv', github: 'ananace/fog-hyperv'
```

The enabled cluster paths additionally require a build that answers all six
capability predicates the plugin asks (`Fog::Hyperv::CAPABILITIES`); older
builds — the released 0.2.x included — are answered the pre-enablement
refusals verbatim, with the missing behaviours named.

### Verifying a compute resource

Listing the virtual switches exercises the whole path, so the API endpoint for
them is the quickest check that credentials, host permissions and SELinux are
all in order:

```console
curl -k -u admin 'https://foreman.example.com/api/compute_resources/1/available_networks'
```

Note that Foreman 5.0 has no `compute_resources/:id/test` endpoint and
`hammer compute-resource create --provider` does not list Hyper-V, so create and
check Hyper-V resources over the API.

A clustered resource answers one more question at
`/api/v2/compute_resources/:id/switch_hosts`: the virtual-switch NAMES each
node reports, per node — the fact the machine form dims its switch dropdown
with and the create gate refuses on (`null` for a node means its read did not
answer, which is not "no switches"; RUNBOOK §14).

### Cluster nodes and `hyperv_node_overrides`

A clustered compute resource reaches the node it is pointed at and, from
cluster reads, learns the *unqualified* names of the other nodes. Those names
are not addresses: unless the Foreman host resolves them itself, fog takes
them to its name-completion path, which can complete against the wrong
endpoint. The `hyperv_node_overrides` attribute tells Foreman the address of
a node its endpoint does not serve — one `NODE = host[:port]` line per node:

```
HV-NODE2 = 192.168.1.67
HV-NODE3 = hv-node3.lab.maughmer.net:5985
```

The value is a bare host or `host:port` only — never a scheme, never a path
(anything else is refused on save, not repaired). The compute resource's own
URL supplies the scheme and port; the override supplies the identity spliced
into it, and the per-node client is built from that composed endpoint. Prefer
IP addresses unless the Foreman host really resolves the FQDNs.

The composed per-node endpoint rides one of the two transport families the
measured matrix validated (PLG-5b): http + negotiate with any identity, or
https with a certificate-verifiable hostname and a `hyperv_ca_trust_path` on
the resource — while verification is on, https to an IPv4 identity is refused
outright, because the node certificate gives it no hostname to verify
against. A node with no override and no address the cluster itself gives it
is refused its per-node reads — no fog call carries its name — which is the
fail-closed default, not a bug.

### `hyperv_ssl_verify`: the deliberate opt-out (PLG-32)

`hyperv_ssl_verify` defaults to **on**: an https endpoint is dialed only when
its certificate verifies, which on the measured platform means against an
explicit `hyperv_ca_trust_path` (fog's default store does not see system
anchors — row (w)). Switching it off is the operator's deliberate choice,
never the plugin's: with the opt-out taken, certificate verification is off
for that compute resource's every client — the resource's own (including
Test Connection) and each routed per-node client — and https composes for
any endpoint identity, IPv4 included, exactly as http does. Garbage schemes
stay refused with or without it. When verification is on, a refusal that the
missing verification caused names the opt-out next to the reason.

The compute-resource form carries all three transport controls — the
verification checkbox, the CA trust file path, and the node override lines —
beside the endpoint, user and password.

Clustered creates, disk removals and VM destroys run when the installed
`fog-hyperv` answers all six behaviours the enablement stands on; a fog
answering fewer gets the pre-enablement refusals verbatim, with the missing
behaviours named. Enablement is a code PR, not a configuration — and neither
is any other lift a refusal promises.

## Runbook

What a refusal means, and the paths this plugin leaves to an operator by
hand — resolving a stranded cluster-role write, reading and clearing the
sightings ledger, an endpoint whose cluster reads can never answer, a disk
whose file cannot be proven safe to delete, and enabling and riding the
boot disk pull — are in [docs/RUNBOOK.md](docs/RUNBOOK.md). It also draws
the transport postures apart, says what to change when the endpoint is far
from Foreman, and records which Windows Server builds this plugin's
behavior was actually measured on.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/ananace/foreman_hyperv.

## License

The gem is available as open source under the terms of the [MIT License](http://opensource.org/licenses/MIT).

