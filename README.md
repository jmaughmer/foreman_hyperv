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

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/ananace/foreman_hyperv.

## License

The gem is available as open source under the terms of the [MIT License](http://opensource.org/licenses/MIT).

