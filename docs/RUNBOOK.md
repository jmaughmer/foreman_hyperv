# Runbook

Refusals in this plugin are contracts, not bugs. Each names what the gate
asked and what the unknown costs, and each lifts by a merged PR, never by
configuration. This file covers the places where the contract still leaves a
manual path for an operator: reading and clearing the sightings ledger,
resolving a stranded cluster-role write, an endpoint whose reads can never
answer, per-node addressing, storage and disk-file refusals, a fog that
is not the plugin's partner, and the boot disk: its drop-in, its janitor,
and the opt-in and the ride that turn them on (§§8–11); and what changes
when the endpoint is far from Foreman, which transport is a posture rather
than a setting, and which Windows Server builds this plugin's behavior was
actually measured on (§4, §§12–13).

Everything here describes the era the enablement names: the installed
`fog-hyperv` answers all six behaviours listed in
`ForemanHyperv::Hyperv::ENABLEMENT_CAPABILITIES`. A fog answering fewer gets
the pre-enablement refusals verbatim ("This operation is refused: the
fog-hyperv this plugin runs against does not answer every behaviour the
enablement depends on (missing: ...)."); the refusal names what is missing,
the fix is the fog build the plugin declares, and §7 says what stays refused
until then.

The constants, scripts and commands quoted below live in
`app/models/foreman_hyperv/hyperv.rb` (and, on the fog side, in the
`fog-hyperv` build the enablement names). Nothing here is a knob — the one
exception is the two boot disk settings of §10, a designed opt-in whose off
state the contract answers for — every gate named makes its reads again on
every attempt, and classifier results are never cached.

## 1. The sightings ledger

The table is `foreman_hyperv_cluster_sightings`. A row says one of two
things about one moment: this compute resource's endpoint answered as a
cluster (kind `sighting` — the membership read answered a cluster row, a
cluster-service read answered joined, a configured-cluster marker answered
present, or fog reported a machine carrying a cluster role), or a cluster
role write left a machine stranded (kind `strand`, naming the machine's uuid
and name). To read it:

```sql
SELECT endpoint_host, kind, vm_uuid, vm_name, cluster_name, reason, created_at
  FROM foreman_hyperv_cluster_sightings
 ORDER BY created_at;
```

The ledger is insert-only — the model refuses updates and deletes ("cluster
sightings are an insert-only ledger: rows are never updated or deleted") —
because a node that has left a cluster looks exactly like a node that never
joined it on every reading that outlives the membership, and a later "not
clustered" reading must not be able to erase an earlier sighting.

What a row costs depends on the era. Before the enablement (a fog answering
fewer than the six behaviours), one `sighting` row is enough to keep destroys
on that endpoint refused — that is the sticky clause of the destroy refusal.
In the enabled era the ledger refuses nothing by itself: destroy treats a
clustered answer as a shape, not a stop — fog asserts a matching role before
the cluster will release it, and a machine that reports no role is destroyed
as an ordinary one. What the ledger always does, in either era, is make the
destroy gate's question "has this endpoint ever answered as a cluster?"
answerable instead of guessed.

To clear a row anyway — a test-time sighting, or a host that was truly
decommissioned and rebuilt — raw SQL is the only path:

```sql
DELETE FROM foreman_hyperv_cluster_sightings WHERE id = <id>;
```

Understand what that erases: if the endpoint ever did answer as a cluster,
clearing the row re-opens exactly the fail-open the ledger exists to close.

A create that hears "Refusing to act on this cluster reading because the
sightings record could not be written" has not hit the host at all: the
ledger is a precondition of the decision, so this is the database — the
plugin's migration has not run (`foreman-rake db:migrate`) or the database is
down.

## 2. The strand: a cluster-role write that cannot be proven

Symptom — a cluster create fails with:

> Placing the virtual machine <uuid> in the cluster did not provably succeed
> (the request reached the cluster, its outcome is unknown): ... The machine
> at <path> named <name> has been left exactly as it is: nothing was stopped,
> deleted or un-clustered, ...

Why it exists: a fog write over WinRM is indeterminate once the request has
left — measured on the pinned fog, a SUCCESSFUL
`Add-ClusterVirtualMachineRole` raises `Fog::JSON::DecodeError` on its empty
reply. So success is proven by reading the role back: up to three attempts,
thirty seconds apart, each attempt capped by the 90 s WinRM operation wait —
a create can sit near six minutes before it strands. Anything short of
finding the role strands the machine, and tearing down a machine the cluster
may already own destroys the wrong thing, so there is no rollback: machine,
disks, folder and any role are left exactly as they are. A `strand` row goes
into the ledger (with the machine's uuid and name, and `readback-empty` when
the write itself did not raise), the log carries the machine's path, and the
message above is what the form shows.

Decide on the host — any cluster node, with an administrator logon; the
cluster service answers role reads for the whole cluster:

```powershell
Get-ClusterGroup -VMId "<instance uuid>"
```

Address the group by the machine's instance UUID: `-VMId` is declared on
both supported builds, and it cannot be confused by Hyper-V's tolerance of
duplicate machine names. If you are naming instead, know the shape: measured
on both supported builds, the cluster GROUP carries the machine's BARE name,
and `Virtual Machine <machine name>` is the name of the Virtual Machine
RESOURCE inside that group — `Get-ClusterGroup -Name "Virtual Machine
<name>"` errors against the group. If a name read errors or comes back
empty, list `Get-ClusterGroup` and look for the machine's name before
concluding anything.

**The group is there.** The machine is healthy and cluster-owned; the create
only failed to prove it. If the Foreman host record survived, give it its
instance UUID back — the `<uuid>` from the message, same compute resource,
Build unchecked so Foreman manages the machine instead of rebuilding it. If
the record never landed, the machine is a healthy orphan: adopt it with a
matching record or remove it under "the group is not there" below.

**The group is not there, and you want the machine gone.** If a Foreman host
record with the right instance UUID exists, destroy from the UI: the enabled
destroy stops the machine, releases the role only if the machine reports
one, and deletes each disk file only when it is attributable and provably
unshared, the folder only on its own pre-flight verdict. By hand instead:

```powershell
Remove-ClusterGroup -VMId "<instance uuid>" -Force -RemoveResources
Remove-VM -Name "<machine name>" -Force
# the machine's folder on the volume the message named:
Remove-Item -LiteralPath 'C:\ClusterStorage\Volume1\<machine name>' -Recurse
```

`Remove-ClusterGroup` declares `-VMId` on both supported builds; naming it
takes the group's bare machine name, not the resource shape.
`Remove-ClusterGroup` with plain `-Force` REFUSES a non-empty group (measured:
"Please use -RemoveResources") — the refusal is the cmdlet protecting
resources, not a failure to retry. Before deleting a folder, look inside it:
the plugin holds itself to the rule that a recursing folder delete may never
take a file it did not decide on, and the same care is worth taking by hand.

Two things not to do: do not create a second machine under the same name
while the stranded one is there; and do not read the untouched machine as a
rollback that forgot something — touching nothing is the design.

## 3. An endpoint whose reads can never answer

Symptom: destroys of a *stand-alone* machine on one endpoint keep ending in
"the cluster classification reads did not answer" — on every attempt,
permanently — while machine lists and other plain reads work fine.

Why: the last read the destroy gate makes, the cluster-service state,
compiles a P/Invoke of `GetNodeClusterState` with `Add-Type` in the remote
PowerShell session. Constrained Language Mode, WDAC or AppLocker that blocks
`Add-Type` make that read unable ever to answer — indeterminate permanently —
and an unknown is never a decision this plugin spends. That is the accepted
availability trade: stand-alone destroy never unlocks on such an endpoint.

The reads around it are not blocked, and the shape of what stays refused
follows from that: a machine that reports a cluster role, or one on an
endpoint that has ever answered as a cluster, is decided through the
clustered path before the blocked read is reached and is still destroyable;
creates are unaffected, because the create gate rides the membership read
and the two configured markers, none of which needs `Add-Type`.

Diagnose on the host, over the same WinRM logon Foreman uses:

```powershell
$ExecutionContext.SessionState.LanguageMode
```

Anything but `FullLanguage` is the cause; `__PSLockdownPolicy`, AppLocker and
WDAC policies are where it comes from, and whether it can be lifted for the
service account specifically is a policy question.

Options: fix the policy for that account, or accept the endpoint as
non-decisional. There is deliberately no bypass to enable — an unreadable
endpoint is not a license to create and not a license to delete.

## 4. A target the endpoint cannot address

"Illegal" names never appear here; refusals appear at the addressing rung:

* *"the name the endpoint gives itself did not match, and no node→endpoint
  override and no cluster address read routed the target"* — the target is
  another node, and nothing carries its identity. Either name the node in the
  resource's `hyperv_node_overrides` (`NODE = host[:port]`, bare host, never a
  scheme or path — refused at save, not repaired; the only source of FQDN
  identity), or let the cluster's own address read route it (the address the
  cluster gives the node, client-role, plain IPv4). The refusal says which
  rung failed.
* *"a composed per-node endpoint uses a transport the (w) matrix did not
  validate"* — the matrix validated two families only: http + negotiate with
  any identity, and https with a certificate-verifiable hostname plus a
  `hyperv_ca_trust_path` on the resource (fog's default store does not see
  the system trust anchors on this platform, measured).
* *"an IPv4 identity gives the certificate no hostname to verify against"* —
  https to a discovered IPv4 address is refused outright, and the fix is a
  `hyperv_node_overrides` entry naming the node with its FQDN; forcing
  certificate verification off is not this plugin's choice.
* *"hyperv_ca_trust_path is not set"* — an https resource routes per-node
  work only with an explicit CA file to verify against.

Those bullets are about addressing; the TRANSPORT they validate is a posture,
and the two families the matrix validated are not equal postures. Over
HTTP + Negotiate the WinRM password/NTLM hash rides a plaintext channel, and
the listener is configured to accept unencrypted payloads (`AllowUnencrypted`
enabled — which is what lab prep configures); whether a given client seals
payloads on top of that is not recorded here, and the posture should be
designed as if it does not. And `hyperv_ssl_verify` has no certificate to
consult. That is a lab VLAN posture, not a production one. The production
posture is the https family — a certificate-verifiable hostname, an explicit
`hyperv_ca_trust_path`, verification left on. The verify-off checkbox is a
deliberate, per-resource MITM window (it exists so https can compose for any
endpoint identity); keep it loud in the UI and keep production resources out
of it.

## 5. Storage refusals

* Membership comes before anything: every placement string on the form
  (cluster, per-disk datastore, target computer) must be a member of what the
  hypervisor itself reports, after the character allowlist. A membership
  refusal is about the list, not the volume — usually a name the host does
  not answer with.
* *"Refusing to place a disk on the shared volume ... : <reason>"* — the
  cluster answered this volume and declined it. Only a volume the measured
  capacity projection answers as Online (cluster resource state 2) with a
  mount path is placement storage; Offline (state 3), an unmeasured state,
  silence about state, and a missing mount path are each excluded with the
  reason named. Fix it on the cluster (bring the volume online), not in the
  form.
* *"the volume answers no mount path"* — the create used to guess here and
  landed clustered machines' files on one node's local disk, off the
  cluster. Now it refuses: check that the volume really is a mounted cluster
  shared volume.
* fog's own *"Refusing to place '<name>' in the relative folder ...: a
  placement folder must be absolute"* — the plugin always composes the
  placed volume's mount path plus a machine folder, which is absolute; this
  refusal is the direct-fog-API shape, or a storage that answered no absolute
  mount path, and it is fog refusing to guess, by name.

## 6. A disk whose file cannot be proven safe

*"Removing that disk is refused: its file is not attributable to this
machine's folder or a storage root the hypervisor named, or its sharing state
is not proven absent"* — the two are different facts and both protect the
same thing: deleting a disk another running machine may be reading destroys
that machine's data. Fog refuses a drive whose persistent reservations read
true or unread, so "unread" costs the removal even when the disk looks idle:

```powershell
Get-VMHardDiskDrive -VMName <machine name> | Format-List Path, *Reservation*
```

Nothing was detached and no file was deleted; the disk stays exactly as it
is. Where a disk genuinely is shared, resolve it on the host where the other
reader is visible — the plugin will not guess.

The same rule rides destroys from the other side: a disk file a destroy
refused to delete keeps its machine folder too, because the folder delete
recurses. A destroy that succeeded on everything else can honestly leave one
folder and one file behind; the log names it.

## 7. The fog is not the partner

*"This operation is refused: the fog-hyperv this plugin runs against does not
answer every behaviour the enablement depends on (missing: ...). Nothing was
stopped, deleted or created."* The check is a local constant read plus one
predicate call per named behaviour — no wire traffic — and it runs before
any decision. The remedy is the `fog-hyperv` build the plugin declares (see
"Which `fog-hyperv` you get" in the README), followed by a restart of the
Foreman service; until the partner is installed, the enabled operations
refuse as they did before enablement, by design. The check asks the fog, and
a predicate that raises is an unanswered predicate — an fog that cannot
answer has not answered.

## 8. The pull refuses: the boot disk drop-in

*"The boot disk file cannot be staged for the host to pull: the Apache
configuration serving /bootdisk-pull is not installed (/etc/httpd/conf.d/
05-foreman.d/foreman-bootdisk-pull.conf). ... Nothing was staged."* The Hyper-V
host pulls the generated boot disk ISO over HTTP, and the URL the plugin hands
it only works while an Apache drop-in serves the configured pull root. Measured
(2026-11-24): `foreman-installer` PURGES the vhost drop-in directories — a
snippet answering HTTP 200 was gone after the next installer run — so this
refusal is expected to come back after every installer run, and `iso_upload`
answers it before staging a byte rather than letting the host discover a 404
minutes later. The remedy, in order:

1. Copy the snippet the gem ships (`config/apache/foreman-bootdisk-pull.conf`
   inside the installed `foreman_hyperv` gem) to the path the refusal names.
   If the `unattended_url` is https, also copy it to the `05-foreman-ssl.d`
   path a matching refusal names — each vhost includes only its own drop-in
   directory (measured).
2. Set both roots (`Hyper-V boot disk pull root`, `Hyper-V boot disk staging
   root`); blank keeps the whole transfer dormant and nothing ever stages.
3. `systemctl reload httpd`.

The other message — *"...is installed (...) but does not Alias that path at
the configured pull root (...)"* — is the same drop-in copied without editing
its `Alias` (and `<Directory>`) to match `hyperv_bootdisk_pull_root`. Edit the
file to the root the refusal names and reload. Re-apply step 1 after every
`foreman-installer` run until a kafo post-hook exists (not yet shipped).

A third message exists for the state an SELinux enforcing host is most likely
to hit: *"...is installed (...) but Foreman cannot read it (permission
denied)"*. Measured (2026-11-26, enforcing production host): the shipped
foreman-selinux policy denies the Foreman application domain the search of
`/etc/httpd/conf.d` and the read of the drop-in itself, and a permission
denied reads to the gate like absence — an earlier build of this plugin
answered the FIRST message above for an installed, serving file. It now
answers this one instead, and the first two messages mean what they say
(`is not installed` is true absence only). This refusal is not a drop-in
fault: the file is correct, the policy is not — the remedy is §10's local
policy module, and no amount of copying or editing the drop-in changes it.

One posture note rides this endpoint. The shipped drop-in is
`Require all granted`: what authenticates a pull is the 128-bit random nonce
in the URL, and that nonce is the whole secret — the endpoint has no login.
The host verifies status, size and sha256 before it moves the staged file
into place, so INTEGRITY is enforced by the transfer itself; CONFIDENTIALITY
is whatever the wire provides. Over plain http the ISO crosses in clear
text, and a Hyper-V boot disk embeds the host's provisioning payload — the
build token among it. The design already treats the nonce as the short-lived
capability it is (§9's janitor caps strays), and step 1's https copy exists
for exactly this: on any network an operator would not read bytes off, serve
the pull over the TLS vhost and set `unattended_url` to match — then the
plugin's own gate requires the ssl-side drop-in, and the check enforces the
posture rather than merely permitting it.

## 9. The janitor: what the hourly cron line means

The plugin registers `foreman_hyperv:bootdisk_janitor` through Foreman's own
scheduling hook (`Foreman::Cron.register(:hourly, ...)` in the plugin's rake
file), so it runs with the platform's hourly work — the RPM's
`/etc/cron.d/foreman` fires `foreman-rake cron:hourly` at :30 every hour. It
removes age-exceeded files from the two transfer roots and NOTHING ELSE: only
names matching `<32-hex>.iso` in the pull root and
`staging-<32-hex>.json` / `staging-<32-hex>.iso.part` in the staging root, and
age is file mtime (never the sidecar). Patience is 24 h
(`BootdiskTransfer::JANITOR_MAX_AGE`) — healthy files live minutes, so what it
catches is the debris of a crashed ride.

You will see one line per hour in `/var/log/foreman/cron.log` while bootdisk is
dormant: *"hyperv_bootdisk_pull_root/staging_root are not configured — bootdisk
is dormant, nothing to sweep."* That is the off switch announcing itself:
configure the two settings and the line becomes a removal count. Actual
removals (and any unlink failures, e.g. a root chowned away from `foreman`) go
to the Foreman application log, not cron.log. The registration carries no
existence guard on `Foreman::Cron` deliberately: if a future Foreman removes
that hook, every `foreman-rake` run failing loudly beats a janitor nobody knows
about.

## 10. Enabling the pull: the opt-in and the SELinux read

The boot disk transfer is opt-in, and the two settings are the opt-in
(`Hyper-V boot disk pull root`, `Hyper-V boot disk staging root`). They are
the only knob in this file, and off is a real state: with either blank
nothing stages — a build that asks for the boot disk reaches the answer
*"hyperv_bootdisk_pull_root is not configured"* (or the staging twin) once
the ride's gates let it through — and §9's janitor line reads dormant.
Enabling is §8's remedy in order — copy the shipped drop-in to the path it
names, set both roots, `systemctl reload httpd` — and §8's purge warning
applies to the whole arrangement: re-apply the drop-in after every
`foreman-installer` run.

Before the first enable, one prerequisite §8's remedy does not include: the
*Grub2 directory* (foreman_bootdisk's `bootdisk_grub2_dir` setting, default
`/var/lib/foreman/bootdisk`) must hold the EFI binaries the ISO is assembled
from. Measured (2026-11-24: `generate_full_host` failed exactly there three
times on the stock host before the files were installed; gem source re-read
2026-11-26): every full provisioning-ISO generate copies exactly
`grubx64.efi`, `shimx64.efi` and `mmx64.efi` from that directory into the
6 MB ESP image — and the gem ships no EFI binaries, so on a fresh host the
first rebuild dies at the generate step with `ERF42-8203 ... Ensure
/var/lib/foreman/bootdisk/grubx64.efi is readable (or update "Grub2
directory" setting)` no matter how correctly §8
and the SELinux half below are done. What works here, sha256-verified
byte-identical to the boot ESP's own files and `rpm -qf`-attributed (other
distros keep the same three under their own `/boot/efi/EFI/<distro>/`):

    mkdir -p /var/lib/foreman/bootdisk
    install -o foreman -g foreman -m 0644 \
      /boot/efi/EFI/almalinux/{grubx64,shimx64,mmx64}.efi \
      /var/lib/foreman/bootdisk/

`grubx64.efi` comes from the `grub2-efi-x64` package, `shimx64.efi` and
`mmx64.efi` from `shim-x64`. No grub module tree is involved — the prebuilt
`grubx64.efi` is what is copied, so `grub2-efi-x64-modules` is not needed.
They are copies, not symlinks: they do not follow RPM upgrades, so re-copy
them after every `grub2-efi-x64` or `shim-x64` update — until you do, the
generated disks boot with the copied generation's signed binaries and SBAT.

The opt-in has a second half §8 does not mention. Measured (2026-11-26, a
production host under Enforcing): the shipped SELinux policy makes the
opt-in NOT complete under Enforcing. The snippet gate reads the installed drop-in as
`foreman_rails_t`, and the policy denies that domain `search` on
`/etc/httpd/conf.d` (`httpd_config_t`) and the read of the snippet itself;
to the gate an EACCES looks like absence, so §8's *"is not installed"*
refusal answers for a drop-in that IS installed and serving. The proven
interim fix is a local policy module granting exactly the measured denial
set and nothing else:

    module foreman_hyperv_bootdisk 1.0;

    require {
            type foreman_rails_t;
            type httpd_config_t;
            class dir search;
            class file { getattr open read ioctl };
    };

    allow foreman_rails_t httpd_config_t:dir search;
    allow foreman_rails_t httpd_config_t:file { getattr open read ioctl };

(`checkmodule -M -m -o bootdisk.mod foreman_hyperv_bootdisk.te`,
`semodule_package -o bootdisk.pp -m bootdisk.mod`, `semodule -i bootdisk.pp`.)
With it loaded, three full build chains ran end to end under Enforcing on a
real cluster, AVC-denial-free for the whole ride window — the transfer
itself asks for no grant: staged files are written by puma (`system_u`),
inherit the pull root's
`foreman_lib_t`, and Apache serves them Enforcing-quiet at dir 0711 / file
0644. Of the two upstream tracks, one has since landed in this plugin: the
gate now splits the answers, and a blocked read arrives as §8's *"Foreman
cannot read it"* refusal pointing to this module instead of *"is not
installed"*.
The foreman-selinux feature request for the read itself stays open, so the
module remains required on an enforcing host until that one ships.

## 11. Riding it: entry, power, and the media boot

Measured (2026-11-26, production host, create and rebuild alike — the
rebuild is the one an operator drives day to day):

1. *Enter the build with the machine Off.* Core answers *"The host must be
   powered off to build."* for a host whose build asks for the boot disk,
   and `iso_attach` repeats the demand with its own refusal for any machine
   not Off (fog's `Set-VMDvdDrive` refuses a running machine). There is no
   `PUT /api/hosts/:id/build` member route — rebuild is the update route,
   `PUT /api/hosts/:id`.
2. *A rebuild must re-pass the storage root.* Send
   `{"build":true,"compute_attributes":{"iso_upload_storage":"<root>"}}`.
   `compute_attributes` is request-scoped and the stored attributes are not
   what the boot disk reads, so a rebuild that only flips `build` wastes the
   ISO generate and then answers *"iso_upload requires a storage id"*. The
   root must be one the host reports: a wrong one is refused by name, the
   refusal lists the reported roots, and *"Nothing was transferred."* On a
   clustered resource the CSV volumes are among the reported roots and the
   transfer rides them like any other root.
3. *Nothing boots the media by itself.* On create, core queues the power-on
   BEFORE the attach lands, so the machine's first boot happens without the
   media; on rebuild nothing starts anything and the machine stays Off.
   The attach writes DVD-first into the boot order — that write is the
   F12, nothing waits on a keyboard — so the operator's move is one reboot
   after a create, one start after a rebuild. (A reset against an Off VM
   boots nothing: measured, no template fetch in ten minutes.)
4. *The guest then rides its own media.* Anaconda fetches its template from
   the unattended URL (measured: a media boot without F12), and the media's
   built hook POSTs built (both measured rides drove that step by hand
   through the HTTP vhost). The built side closes the ride: detach EJECTS
   the media even from a running guest, delete sweeps the host-reported
   roots for the host-named ISO, and nothing restores the boot order — DVD
   stays first, harmless with an empty drive. Debris from a crashed ride
   ages out under §9's janitor.

## 12. When the endpoint is far from Foreman

Everything measured in this file so far rode lab-VLAN endpoints, where a
round trip is invisible. When the Hyper-V endpoint sits behind a WAN or satellite
link — hundreds of milliseconds per round trip — two facts about this
plugin's behavior decide the cost, and one setting is the operator's lever.

*Keepalive.* A keepalive tick replays one page load of endpoint reads so the
next human load is warm; the interval comes from
`hyperv_keepalive_interval_seconds`, defaults to 60 and is clamped to
60–3600 — there is no faster-than-a-minute beat to configure, anything typed
below a minute clamps up to one. One beat per interval runs
across ALL Foreman processes — a Postgres advisory-lock election — so the
cost is per beat, not per process. On a high-RTT link each beat pays that
RTT for a full listing replay, and 60 s is a lab rhythm: satellite installs
should set the interval to 300 or more unless a specific cold-window
requirement says otherwise. A page load itself rides the cluster listing
pipeline, whose endpoint hops run overlapped — a slow link pays for its
slowest single hop, not for the sum of them.

*The boot disk ride.* The ISO transfer is a host-side pull (§8): the
Hyper-V host fetches the staged file from the pull endpoint, so Foreman's
wire carries the WinRM command and its answer, not the 245 MB of ISO bytes.
RTT adds command round trips, not volume; what a slow link does stretch is
the transfer's wall-clock time inside the one long-running command the host
runs for it. That command rides its OWN WinRM operation window, computed by
fog-hyperv builds from the pull-window change onward from the size the pull
already carries (the README's "Which `fog-hyperv` you get" says which gem
you get, not which of these two builds — both answer 0.2.2 with the same
capability list; the tell is whether the installed gem's
fetch_url_to_path.rb defines pull_operation_timeout): one MiB per second — a
budget set below every pull rate this fork has measured, the lab's 234 MiB
in 1.6 s included — so the lab's 245 MB (234 MiB) ISO rides a 234 s window,
clamped at 90 s below and 3600 s above (the floor is exactly the 90 s this
plugin pins its clients to — §2 counts the same wait — so small pulls keep
the window they have always had; the ceiling bounds the computation at
3600 MiB, just over 3.5 GiB of ISO). The fog keeps a longer configured
`hyperv_operation_timeout` when a client brings one — the window is the
larger of the computed number and the configured one, so the computation
only ever widens an explicit wait, never narrows it — and through this
plugin there is nothing to widen: every fog client it composes is pinned to
90 s (§2), so the computed number IS the pull's window. The widened window
rides its own WinRM connection inside the fog — cached per endpoint and
window, kept out of the ordinary connection pool — so everything else on the
resource keeps the pinned 90 s wait, and the plugin layers no transfer
deadline of its own. The transfer math is therefore the link's, not a fixed
window's: what still aborts a pull is exceeding the computed window — in
practice a link sustaining well under 1 MiB/s across the download AND its
host-side size check and hash (below 90 MiB the 90 s floor is the window,
far more generous than the budget) — and an abort mid-download (the window
expiring, not a script refusal, which deletes its own `.part`) leaves the
`.part` file behind on the host, out of §9's janitor's reach — it sweeps
only the two Foreman-side roots — until the next pull to that name writes
over it. On an older fog build the pull shares the pinned 90 s like every
other command, which caps a 245 MB ISO at roughly 2.7 MB/s (2.6 MiB/s)
however good the link is; the measured LAN pull cleared even that with room
to spare (234 MiB in 1.6 s). This computed-window build rode the production
host on 2026-11-27: the rebuild answered 200 in 44.6 s (generate through
attach — the host's pull of the 245 MB boot disk included), well inside the
234 s the disk's own size computes; the guest's own template fetch proved
the media boot, and the verifier closed the ride with the eject from the
running guest and the staged file's removal.

## 13. Which Windows Server builds this plugin's behavior was measured on

A support matrix is only honest with the measured row and the expected row
drawn differently, so here they are separately. As of 2026-11-27 both build
rows carry lab measurements — the cluster paths and the boot disk round
trip included on each lineage — and the section ends with the last row
that closed.

*Measured: Windows Server 2025 Standard, build 26100.* Standalone and
failover-cluster paths were both exercised there, and the documented
quirks are responses to what that build actually answered: the
`Get-ClusterGroup -VMId` all-zero-GUID binder behavior, the two
`FullyQualifiedErrorId` miss prefixes, `VmID` NULL on real cluster groups
resolved through `Get-ClusterParameter`, `Remove-ClusterVirtualMachineRole`
being absent on 26100, nested objects serializing as bare type-name strings
(guarded on every capacity row), and the PowerShell 5.1 `if`-paren parse
trap. The version-gated stream rendering was exercised on PS 5.1.26100.7462
specifically. The boot disk rides of §11 ran against the same build.

*Measured: Windows Server 2022 Standard, build 20348 (PS 5.1.20348.2849,
Server Core 21H2).* Upgraded from *expected* by a lab pass on
2026-11-27 on three domain-joined 2022 nodes (rebuilt lab cluster HV-CL02:
domain join, Hyper-V and Failover-Clustering roles, persistent iSCSI to
SAN LUNs visible to no other initiators, cluster creation with all three
nodes `Up` and three CSVs claimed). The same day's rebuild of the 2025
trio supplied the counterpart: HV-CL01 through the same node-prep and
build scripts, 3 of 3 nodes `Up`, 3 CSVs, quorum Majority. The cmdlet
answers the plugin keys on, the capacity read and the PS-gate probe each
ran on a 2022 node and on a 2025 node in the same lab the same day — the
cmdlet probes byte-identical scripts, the capacity read the same probe
against each lineage's peer node — and every answer that could match
across builds did, build numbers excepted:

* all-zero-GUID `Get-ClusterGroup -VMId` answers without error on 20348
  exactly as on 26100;
* both miss prefixes the role classifiers key on are byte-identical
  between the builds: a well-formed GUID matching no machine raises
  `ClusterCmdletException` carrying FullyQualifiedErrorId
  `PSArgument,Microsoft.FailoverClusters.PowerShell.GetClusterGroupCommand`,
  and a name miss raises `ClusterCmdletException` carrying
  `ClusterObjectNotFound,Microsoft.FailoverClusters.PowerShell.GetClusterGroupCommand`;
* a malformed GUID is a bind failure rather than a miss — it raises
  `ParameterBindingException` carrying
  `CannotConvertArgumentNoMessage,Microsoft.FailoverClusters.PowerShell.GetClusterGroupCommand`,
  which the classifiers do not treat as a miss — and a `Get-VM -Id` miss
  raises `VirtualizationException` carrying
  `ObjectNotFound,Microsoft.HyperV.PowerShell.Commands.GetVM`; both
  answers likewise byte-identical between the builds;
* `Remove-ClusterVirtualMachineRole` is absent on 20348 too — the cmdlet
  that would be the alternative exists on neither build — so the
  `Remove-ClusterGroup`-based role removal this fork ships is the chosen
  path on both builds, not a fallback for either;
* a remote capacity read on 20348 comes back with the same shape as on
  26100: type name `Deserialized.Microsoft.HyperV.PowerShell.VMHost`
  with scalar members (`Name`, `MemoryCapacity`) surviving
  deserialization while derived members (`ProcessorCount`,
  `VersionString`) arrive empty — the deserialized shape the capacity
  rows guard for before trusting a number, measured on both builds the
  same day;
* `$PSVersionTable.PSVersion` measures 5.1.20348.2849 against
  5.1.26100.7462 — the same PowerShell 5.1 line, so the version gate's
  *input* is measured identical on both builds; the gated stream
  rendering itself was exercised on 26100 only, so its 2022 path is by
  measurement of the gate input plus construction from it, not a
  rendering ride;

The Foreman-side rides closed this section's last expected row on
2026-11-27: §11's boot disk round trip ran against a Server-2022
(build 20348) machine, and against a clustered one — a virtual machine
with a role group, its disk on a cluster shared volume, installed while
the cluster owned it. The rebuild staging the ISO onto the volume, the
build chain completing 5 of 5, the media boot (the guest's own fetch of
/unattended/provision), and the built close — the eject, the DVD-first
boot order left standing, the build flag cleared, the token rows gone,
the staged file swept from the volume — were each measured there with the
same answers the 2025 rides recorded. The ride also measured the
raw-API shapes the forms never submit — a string `secure_boot_enabled`
and a per-volume `datastore`, both now pinned suite-side by PLG-58 —
and the bare-named role group, which §2's recipe records. No row of
this matrix is expected-only.

## 14. The switch dropdown and the machine disagree

*Sighting.* A machine form offers a virtual switch; the machine is placed on
the cluster node the dropdown never mentioned lacking it; the create fails —
historically after the machine already existed, with fog's
`Get-VMSwitch -Name` answer "No Ethernet switch could be found matching the
specified criteria", naming neither switch nor node (measured on two builds).
Or its sibling: a switch built on one node seems to "vanish" from the API's
network list for minutes at a time.

*What was actually answering.* Before PLG-59 the question "what switches are
there?" had three different answers depending on the path. The VM form's
NIC dropdown rode `switches(nil)` — the ENDPOINT node's list, with that
node's GUIDs. `available_networks` rode a concurrent read of every cluster
node and answered the UNION of names — a truthful choice list for a machine
that connects by NAME (a switch exists per node; the same name is a
different switch with a different GUID on every node, which is why names,
not the offered GUIDs, are what survives to fog — §2's PLG-26 truth) — but
it computed which node had which name and discarded the answer, logging only
a `Rails.logger.warn` line. And fog answered from the owner node, too late
and too quietly. Worse, a node whose read RAISED was folded into "this node
has no switches", so one down node shrank the union's shared set and made
every switch log as missing there — an outage rewriting the cluster's facts.

*What answers now.* Three things, one per moment of the decision.
The form asks `GET /api/v2/compute_resources/:id/switch_hosts` — this
plugin's first API route — whenever the Computer Name select changes, and
dims (without removing) every switch option that node's COMPLETED read
proves absent; the response carries the map plus the endpoint's own
`{id, name}` pairs, because the dropdown holds GUIDs and only names are
comparable across nodes. The create gate runs inside the placement
membership checks, before anything is asked of the host: a named owner node
whose completed read lacks the requested switch earns a refusal naming the
switch, the node, and what that node DOES answer. And a silent node — one
whose read raised — now holds nil, "could not be confirmed", never an empty
list: the dropdown keeps every option standing beside a one-line note, the
gate passes the create, and fog keeps the last word. Fail-open is one rule
everywhere; absence of an answer is never read as an answer of absence.

*What it does not do.* The dropdown is still the union, not a
per-node filter of what EXISTS: an option dimmed for one node is fully
selectable for another, and a doomed selection that bypasses the form (a
raw API create with `computer_name` and a `switch_id` GUID) is caught by
the gate before the machine exists, not after. A create that names no
owner node cannot be gated — fog's placement wins, and fog's error stays
as measured. An API UPDATE naming both owner and cluster is gated by the
same rule; the web edit page cannot reach the gate, because its disabled
Computer Name select submits no owner. The JS path has no harness in this fork: the dimming is
verified by reading, the gate and the map by the model suite
(`test/models/hyperv_switch_hosts_test.rb`), and the route by live read-backs
against the lab: the stand-alone endpoint's own map, the clustered three-node
map plus endpoint pairs, a 404 for an unknown resource id, and the core
sibling routes answering unregressed beside them (§13's builds).

## 15. Proving what no unit test and no page can: the runner harness

Two surfaces of this plugin were only ever proven by driving the installed
code directly on the lab VM, and both recipes are worth keeping.

**The runner is this fork's view-render proxy.** A partial calling a private
method on the compute resource NoMethodErrors at render — and no unit test
sees it (the suite reaches private reads through `send`; there is no view
harness), while a `respond_to?` pin now guards the whole read-set
(`VIEW_READS`, `test/models/hyperv_available_storage_domains_test.rb`,
PLG-61). The reproduction is `rails runner` calling what the partial calls.
Three measured traps: `ComputeResource.find` is taxonomy-scoped in the
anonymous runner context (`WHERE (1=0)`) — use `.unscoped`; `cr.client` is
protected — the created fog model reloads itself instead; and the UI-session
curl (`/users/extlogin` + cookie jar, even against the FQDN) does not
authenticate here — stop paying for it. The command shape:
`cd /usr/share/foreman && sudo -u foreman HOME=/usr/share/foreman
RAILS_ENV=production bundle exec rails runner /tmp/script.rb`.

**The placement e2e: the datastore key rides to the CSV.** 2026-11-28,
HV-CL01 via CR 5, asking for `Cluster Volume2` — deliberately NOT the first
offered volume, so placement cannot satisfy it by accident. `create_vm` with
`cluster_name`, one NIC (`switch_id` GUID **and** `vlan_operation_mode:
'Untagged'` — the validator refuses a mode-less NIC; keys per
`InputValidation`'s NIC allowlist: `switch_id`, not `switch`, no `type`) and
one disk (`basename` WITHOUT extension — `.vhdx` is refused; `size_bytes`;
`datastore`) — read-back of the created machine answered
`path=C:\ClusterStorage\Volume2\e2e-plg61` (fog's Server `#path`, the `Path`
property Get-VM itself answers), and
`destroy` left nothing behind. The refused twin in the same run: `datastore:
'Cluster Volume9'` heard the membership refusal (`Refusing to place a disk on
a shared volume this compute resource has not read from its cluster...`) and
nothing was asked of the host. What this run did NOT read back: the VHD file
path itself (fog's reload answers `volumes=nil` for a re-fetched model) —
the config root is the measured marker; the disk folder composes from the
same placement by the §5/PLG-14 rules, not by this read. `vm.destroy` in an
`ensure` is the whole cleanup contract — it came back clean
(`MARK-destroy=OK`); folder removal itself rides §2's destroy semantics, not
a check this script made. Two earlier iterations of the same
script died between create and the final read-back (private `client`, then a
guessed attribute name) and each still cleaned up after itself. The script
lives with the sandbox tools (`e2e_plg61_placement.rb`).
