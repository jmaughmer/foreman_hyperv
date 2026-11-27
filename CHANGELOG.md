## Unreleased

- Say which switches a NODE actually has, early and in every place that
  answers the question (option C+A-lite+B). The VM form's switch dropdown
  answered three different questions depending on the path — the endpoint
  node's list with that node's GUIDs, the union of the cluster's node names
  with per-node membership computed and discarded, and fog's post-create
  `Get-VMSwitch -Name` raise naming neither switch nor node (measured, fog
  evidence E12b) — so a doomed node/switch combination cost the whole form.
  Now: the node fan-out tells silence from emptiness (a read that raised
  holds nil, never the `[]` that let one down node shrink the union's shared
  set and log every switch as missing there); `switch_hosts_map` keeps the
  per-node membership and the plugin's FIRST API route,
  `GET /api/v2/compute_resources/:id/switch_hosts`, serves it with the
  endpoint's `{id, name}` pairs alongside (GUIDs do not survive to fog,
  names do — PLG-26); the host-change hook finally does its TODO, dimming —
  fail-open on every silence — what the chosen node is proven to lack; and
  the create gate refuses, before the machine exists, an attach to a switch
  the named owner node's completed read lacks, naming switch, node, and
  what the node does answer
- Cast the submitted Secure-Boot flag in the writer that sends it to the
  host: a raw-API create carrying `secure_boot_enabled: '0'` met a
  truthiness test, and `'0'` is truthy Ruby, so `-EnableSecureBoot On` was
  written onto a machine that asked out of Secure Boot — while the bootdisk
  create seam cast the same string and answered off, leaving the seam's
  answer and the endpoint's verb disagreeing on one value until the ride
  gate later refused that machine (measured 2026-11-27 on build 20348). A
  raw-API edit naming Secure Boot without the form's firmware selector now
  writes too (it used to answer 200 and change nothing, measured twice),
  and the per-volume `datastore` key core documents for
  `volumes_attributes` survives `new_vm`'s volume assignment instead of
  dying `undefined method 'datastore='` — placement already read meaning
  from that key in the request hash (membership check, volume selection);
  the accessor rides it on the model, and fog never persists it (the
  `iso_upload_storage` pattern)
- Read a clustered resource's virtual switches CONCURRENTLY instead of one
  node after another: a cold node switch read costs ~4-5 RTT of its own, so
  the sequential per-node loop serialized a four-node cluster's cold host-form
  and /available_networks calls into ~15-20 s of pure wire time at the
  satellite budget this fork documents (whole-fork review 2026-11-26). Each
  read rides its own fog client — reachable nodes compose one per node up
  front, and a node read through the endpoint after failing WinRM is handed
  a fresh endpoint client for the fan-out — so the reads now run on the same
  bounded pool the cluster's instance listing uses; the union, the per-node
  cache, the missing-switch warnings and the fail-soft — a node that cannot
  answer costs its switches and nothing else — are unchanged, and the
  answer's order stays the order the cluster names its nodes no matter which
  node answers first
- Escape the config-folder pre-flight's path literal through fog's single
  `PsQuote` owner instead of a site-local doubling of the ASCII apostrophe:
  the PowerShell tokenizer ends a single-quoted literal at all five quote
  characters (ASCII and the four typographic single quotes), the folder-name
  rule allows them all, so a legal machine name like `lab’vm2` closed its own
  literal at the pre-flight — and a crafted name carrying a typographic quote
  followed by `;` `(` `)` ran the tail as code under the WinRM account
- Refuse virtual machine creates, destroys and disk removals on every Hyper-V
  compute resource until the reviewed cluster-safe enablement has merged, and
  check every identifier the forms and the URL carry before it reaches the
  hypervisor: virtual machine ids are GUIDs only, names and paths are held to
  the characters a real name has, placement is answered from listings the
  endpoint itself reported, and nothing the operator types is ever asked of
  the host as a filter

## v0.2.2 2026-11-16

- Fix rendering Hyper-V compute resources over the API, the provider specific
  rabl partial core renders for every provider was missing
- Implement available_networks, the API endpoint used to list virtual switches
  raised "Not implemented for Hyper-V"
- Implement available_clusters, the API endpoint used to list Hyper-V
  failover clusters raised "Not implemented for Hyper-V"
- Report an error when the compute resource can not be reached, broken
  connections were saved silently and "Test Connection" always succeeded
- Depend on the logging gem, fog-hyperv requires it without declaring it and
  winrm 2.4 stopped bringing it in, so connecting failed with a LoadError

## v0.2.1 2026-11-15

- Support Foreman 5.0
- Require Foreman 3.14 or newer
- Fix new VMs never being started, regardless of the "Power ON this machine" setting
- Select the VM generation from the chosen firmware
- Fix firmware selection offering UEFI for VMs that are BIOS based
- Fix VMs without network adapters raising an error
- Add a translation template for the strings the plugin adds

## v0.2.0 2026-06-11

- Replace firmware selection with common methods
- Fix lost VM association functionality
- Fix broken interface list
- Fix compute profile creation
- Fix host cloning
- Clean up VM config files on removal
- Increased fog-hyperv version requirement

## v0.1.1 2026-05-22

- Add support for Ruby 3.0

## v0.1.0 2026-05-21

- Lowercase the MAC addresses on NIC- as well as host level
- Fix license inconsistency
- Retarget onto newly rewritten fog-hyperv 0.1
- Support interface modification

## v0.0.4 2018-04-06

- Allow setting a VM-wide VLAN value
- Default to using the first available cluster if one exists
  - This allows the use of clustered machines, as long as all machines are set up with identical switch configurations
- Support the creation of legacy NICs for BIOS
  - Requires fog-hyperv 0.0.8 / d4bf0fcdef691573c25744c3f3930961d5f767d6

## v0.0.3 2018-01-15

- Fix association of VMs by MAC address (case issue)
- Fix over-eager secure boot setting access on unpersisted VMs
- Fix over-eager cluster iteration, ensure the hypervisor supports clusters first (Requires fog-hyperv v0.0.6)

## v0.0.2 2017-08-30

- Add Dynamic memory settings
- Add JS for disabling unavailable settings to improve UX
- Fix secure boot setting to actually apply
- Skip several unnecessary Hyper-V calls to improve performance
- Improve VM properties view to look a little better and house another few nuggets of information

## v0.0.1 2017-08-28

- Initial release
