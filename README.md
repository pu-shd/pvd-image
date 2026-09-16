# pvd-image

Scripted, verifiable customisation of **Azure Virtual Desktop image VMs** from
macOS or Linux — no VPN, no RDP session, and no network route to the image host
required.

Ships two ready-made image steps:

- **Visual Studio Community** with the C++ desktop workload, pinned to a version
  and build you choose
- **All-users desktop shortcuts** (e.g. an Excel icon for every user)

Everything runs through **Azure `run-command`**, which reaches the VM over the
Azure control plane and the guest agent. Nothing here needs the image host to be
reachable on the network, which is what makes it usable against AVD session
hosts on private addresses inside vnets you may not administer.

> **Status:** used in anger against a Nerdio-managed AVD image, but the two
> image steps are the only ones implemented so far. The framework around them
> (dispatch → poll → verify → report) is the reusable part; adding a third step
> means a guest script plus a driver, both modelled on the existing pair.

## Why run-command rather than a tunnel

Every other route into a typical AVD session host tends to be closed:

| Route | Why it usually fails |
|---|---|
| SSH port-forward to 3389 | The gateway you can reach has no route into the vnet's private range, so the forward has nowhere to land |
| SOCKS proxy | The Windows App / Remote Desktop client has no SOCKS support |
| Direct RDP to a public IP | AVD subscriptions commonly have **zero** public IPs by policy |
| Azure Bastion | Must be deployed *into* the vnet (`AzureBastionSubnet`), which needs write access to the network resource group — often held by a different team |
| Corporate VPN | Works, but is exactly what you were trying to avoid automating around |

`run-command` sidesteps all of it. It also runs as **SYSTEM**, so no local
administrator credentials are needed for the install itself. See
[docs/access.md](docs/access.md) for how to prove which of the above apply in
your own environment rather than assuming.

What it *cannot* do is show you a desktop. Final visual confirmation still wants
one interactive session — see [Finishing the image](#finishing-the-image).

## Requirements

- macOS or Linux, `zsh`
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli), logged in
  (`az login`)
- Docker, only to run the test suite
- On Azure: rights to read the VM and create run-commands on it
  (`Microsoft.Compute/virtualMachines/runCommands/*`). Owner or Contributor on
  the VM's **resource group** is enough — you do **not** need any access to the
  vnet or its resource group.
- On the image VM: the Azure guest agent running, and outbound HTTPS to
  Microsoft's download endpoints (the installer verifies this and says so
  clearly if egress is blocked)

## Quick start

```zsh
git clone https://github.com/pu-shd/pvd-image.git
cd pvd-image

cp config.env.example config.env
$EDITOR config.env          # subscription, resource group, VM name

az login
./deploy.sh --start         # install Visual Studio, verify it
./shortcuts.sh              # place the all-users desktop shortcuts
```

`config.env` is git-ignored; it holds your identifiers. The scripts refuse to run
while it still contains the template placeholders — including
`VS_EXPECTED_VERSION`, which the template deliberately leaves unset. This
repository ships no opinion about which Visual Studio version your image should
have: look up the current release in the
[release history](https://learn.microsoft.com/en-us/visualstudio/releases/2026/release-history)
and pin it yourself. Versions mentioned in the docs below are worked examples,
not defaults.

Expect **30–45 minutes** for a Visual Studio install on 8 vCPUs, and seconds for
shortcuts. Every run saves the raw run-command instance view under `logs/`.

## More than one image, or config in its own repo

`config.env` next to the scripts is the simple case. Any driver will instead use
whatever `AVD_CONFIG` points at:

```zsh
AVD_CONFIG=~/images/lab-a.env ./deploy.sh --start
AVD_CONFIG=~/images/lab-b.env ./deploy.sh --start
```

That makes a two-repo split practical, and it is how this is used in practice:
this repository stays public and generic, while each image's identifiers and
version pins live in their own **private** repo — one per image, named for it.
A three-line wrapper beside the config is usually enough:

```zsh
#!/usr/bin/env zsh
# ./pvd deploy --start
SCRIPT_DIR="${0:A:h}"
AVD_CONFIG="$SCRIPT_DIR/config.env" exec "${SCRIPT_DIR:h}/pvd-image/$1.sh" "${@:2}"
```

Benefits worth the small indirection:

- Subscription IDs and host names never enter this repository, so it can stay
  public and `tools/scrub-check.sh` can enforce that mechanically
- Each image gets its own history: the version pin that was in effect for a given
  capture is a commit in that image's repo, not a local edit nobody recorded
- Fixes to the tooling reach every image with one `git pull` here

Whatever wrapper you use, pass arguments through unchanged so the documentation
below still applies, and map commands explicitly rather than interpolating
`"$1.sh"` if the wrapper might ever take untrusted input.

## What's included

| Path | Purpose |
|---|---|
| `config.env.example` | Template for your identifiers and version pins |
| `deploy.sh` | Visual Studio: start → dispatch → poll → verify the guest's report |
| `update.sh` | Move the pin to a newer Stable release (`--to 18.11.0`) and re-run |
| `repair.sh` | Uninstall a Visual Studio instance by path (recovery) |
| `shortcuts.sh` | All-users desktop shortcuts (`--remove` to undo) |
| `teardown.sh` | Delete the run-command resource, optionally deallocate the VM |
| `common.sh` | Shared config loading, Azure preflight, power/agent helpers |
| `scripts/Install-VisualStudio.ps1` | Guest side: idempotent, self-verifying install |
| `scripts/Uninstall-VisualStudio.ps1` | Guest side: uninstall by path, verified |
| `scripts/Set-PublicDesktopShortcuts.ps1` | Guest side: shortcut placement, verified |
| `tools/scrub-check.sh` | Fails if any environment identifier is committed |
| `tests/` | Pester suites (guest logic) and zsh suites (drivers, mocked `az`) |
| `Dockerfile`, `docker-compose.yml` | Containerised test run |

All drivers support `--dry-run`, which prints what would be dispatched and
changes nothing. Use it first.

## Documentation

| Document | Contents |
|---|---|
| [docs/visual-studio.md](docs/visual-studio.md) | Version pinning (and why Community cannot truly be pinned), workload selection, repair |
| [docs/shortcuts.md](docs/shortcuts.md) | All-users desktop shortcuts, why Public Desktop, adding more apps |
| [docs/cost-and-cleanup.md](docs/cost-and-cleanup.md) | Run-command reuse and limits, what actually costs money, measured figures |
| [docs/access.md](docs/access.md) | Proving which access routes exist in your environment; required permissions |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Every failure mode hit in practice, with diagnosis and fix |

## Silence is not success

The design rule throughout: **absence of evidence is never treated as a pass.**
This matters more than usual here, because a broken image looks fine until
someone tries to use it.

- **Guest scripts** never exit 0 on an installer's exit code alone. After a
  Visual Studio install the script re-queries `vswhere` and requires an actual
  `Hostx64\x64\cl.exe` on disk, at the requested install path, at the expected
  version *and* build. A shortcut only counts once it resolves to a file that
  exists. Every exit path prints machine-readable markers.
- **Drivers** require `executionState=Succeeded` **and** an `AVD_STATUS=success`
  marker **and** the expected version/count. A run-command that reports success
  while producing no output is a failure. Markers are read from
  `instanceView.output` only — never from the whole resource JSON, which echoes
  back the uploaded script and would match the driver's own greps.

## Tests

```zsh
docker-compose build
docker-compose run --rm tests
```

**191 tests** across five suites, requiring no Azure subscription and no Windows
host: 102 Pester tests over the guest decision logic (external edges mocked),
plus 89 zsh tests driving each shell entry point against a mock `az` in
`tests/mocks/az`.
The runner fails if any suite fails, and also if a suite reports zero tests or no
summary line — an empty run must not look green.

The mock is deliberately adversarial: its resource JSON embeds decoy marker
strings in `source.script`, exactly as the real API does, so a driver that greps
the wrong field fails its tests.

Note what mocked-CLI tests **cannot** prove: how PowerShell actually parses a
script, streams its output, or quotes process arguments. Those need either
parser-level assertions (included) or a real run. Several real bugs got past a
fully green suite for exactly this reason —
[docs/troubleshooting.md](docs/troubleshooting.md) lists them, and each now has a
regression test.

The container installs PowerShell from Microsoft's release tarball rather than
using `mcr.microsoft.com/powershell`, which publishes no `linux/arm64` variant
and OOMs under emulation on Apple silicon.

## Finishing the image

1. **Look at it.** Connect interactively once and confirm the IDE launches and a
   C++ project compiles. `run-command` can verify files and exit codes, not that
   a GUI is usable.
2. **Reboot** if a run reported `AVD_REBOOT_REQUIRED=true`, before sealing.
3. **`./teardown.sh`** — *while the VM is still running.* Deleting a run command
   is an extension operation, and Azure refuses those on a stopped VM
   (`Cannot modify extensions in the VM when the VM is not running`). Once you
   seal or shut down, the resource is stranded until the VM runs again or is
   deleted. Use `./teardown.sh --deallocate` to remove it and stop compute
   billing in one go, in that order.
4. **Seal and capture in your image-management tool** (Nerdio, or whatever owns
   the image lifecycle) rather than with raw `az`, so its state stays consistent.
   For the same reason, prefer starting and stopping the VM there;
   `deploy.sh --start` exists for when that is inconvenient.

Run-command resources are child resources of the VM, not disk content: they
survive stopping and deallocating, and are **not** carried into a captured image.
A stranded one is harmless — there is no meter for them — but it counts against
the limit of 25 per VM, and it is not worth starting a generalised VM to tidy up.
What *is* baked into the image is anything the guest script wrote to disk,
including the staged script itself, so never pass a secret via `--parameters`.
See [docs/cost-and-cleanup.md](docs/cost-and-cleanup.md).

## Identifiers and secrets

This repository contains no subscription IDs, tenant IDs, host names, IP
addresses or credentials. Everything environment-specific lives in `config.env`,
which is git-ignored. Authentication is your own `az login`; the tooling never
handles credentials and never needs the image VM's local administrator password.

If you add scripts, keep identifiers out of them and read from config instead.
`tools/scrub-check.sh` enforces this — it fails on anything GUID-shaped, any
RFC1918 address, any email address, any Azure resource ID, or any
credential-shaped assignment in tracked files:

```zsh
./tools/scrub-check.sh
```

It runs in CI on every push. The check is pattern-based rather than a list of
known-bad values, because a public repo must not contain the identifiers it is
trying to keep out. Genuine false positives (a vendor product GUID, say) go in
`tools/scrub-allow.txt` with a comment.

## Not yet done

- Only Visual Studio and desktop shortcuts are implemented. Other image steps
  (runtimes, agents, registry policy) would follow the same guest-script +
  driver + tests pattern.
- Visual Studio's own auto-update is left at its default. Freezing it on a golden
  image is a reasonable follow-up, deliberately not guessed at here.

## License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 Princeton University.
