# Cost and cleanup

Short version: **run-command resources are free; a running VM is not.**
`teardown.sh --deallocate` does two things, and only the deallocate half saves
money.

```zsh
./teardown.sh                 # delete the run-command resource only
./teardown.sh --deallocate    # also deallocate the VM  <- this is the one that matters
./teardown.sh --deallocate -y # skip the confirmation prompt
```

`teardown.sh` never deletes the VM, its disks, or the image. Deallocated is the
normal resting state for an image VM between sessions.

The two halves are independent on purpose:

| Command | Run-command resource | Power state |
|---|---|---|
| `./teardown.sh` | deleted | **untouched** |
| `./teardown.sh --deallocate` | deleted, **then** deallocated | deallocated |

So you can clear the resource while leaving the VM up for more work, which is
the usual case mid-build.

> **Order matters, and it is not obvious.** Deleting a managed run command is an
> *extension* operation, and Azure refuses those on a stopped VM:
>
> ```
> (OperationNotAllowed) Cannot modify extensions in the VM when the VM is not running.
> ```
>
> So the resource must be removed **while the VM is still running**.
> `./teardown.sh --deallocate` does them in that order deliberately. If you shut
> the VM down first — including via a "set as image" capture — the run command is
> stranded until the VM runs again or is deleted. `teardown.sh` detects this and
> explains rather than failing on the raw Azure error.

## What a leftover run-command costs

Nothing. There is no billing meter for
`Microsoft.Compute/virtualMachines/runCommands`. Leaving one behind has two
non-monetary consequences:

- It counts against the **limit of 25 managed run commands per VM**
- It keeps the previous run's script and output visible in the resource, which
  may be more than you want retained

So clean them up for hygiene and quota, not for cost.

## What a running VM costs

Retail (pay-as-you-go) prices from the
[Azure retail price API](https://prices.azure.com/api/retail/prices), for the
size used during development — an 8 vCPU `Standard_D8as_v5` in `eastus` with a
128 GiB StandardSSD (E10) OS disk:

| State | Rate | Per month (730 h) |
|---|---|---|
| Running, Windows licence supplied via AVD/M365 entitlement | $0.344/h | **~$251** |
| Running at the full Windows rate (no Hybrid Benefit) | $0.712/h | ~$520 |
| **Deallocated** — OS disk only | — | **~$9.60** |

Roughly **$8/day** for an image VM left running by accident, against about
**32 cents/day** deallocated.

Check which licensing row applies to you:

```zsh
az vm show -g <rg> -n <vm> --query licenseType -o tsv
```

`Windows_Client` (or `Windows_Server`) means Azure Hybrid Benefit is in effect
and you are billed the lower, licence-excluded compute rate — the first row. An
empty result means you are paying the full Windows rate.

Get current numbers for your own size and region rather than trusting the table:

```zsh
# Compute
curl -s "https://prices.azure.com/api/retail/prices?\$filter=serviceName%20eq%20'Virtual%20Machines'%20and%20armRegionName%20eq%20'eastus'%20and%20armSkuName%20eq%20'Standard_D8as_v5'%20and%20priceType%20eq%20'Consumption'" \
  | python3 -m json.tool | grep -E '"(meterName|unitPrice|productName)"'

# Managed disk (E10 = 128 GiB StandardSSD; E-tier number varies with size)
curl -s "https://prices.azure.com/api/retail/prices?\$filter=serviceName%20eq%20'Storage'%20and%20armRegionName%20eq%20'eastus'%20and%20contains(meterName,'E10')" \
  | python3 -m json.tool | grep -E '"(meterName|unitPrice)"'
```

Storage is billed on **provisioned** capacity, not used, and continues while the
VM is deallocated. That ~$9.60/month is the floor for keeping the image VM in
existence at all.

These are list prices. Any EA, CSP or academic agreement will differ, so treat
them as an order of magnitude for "did I leave it on?" rather than a budget.

## What survives a stop, a deallocate, and an image capture

Run commands are **child resources of the VM**
(`Microsoft.Compute/virtualMachines/runCommands/<name>`), not disk content. That
has a few consequences worth knowing before you seal an image:

- They **survive** stopping and deallocating the VM. A deallocated VM still lists
  its run commands, and they run again when it is next started.
- They are **not carried into a captured image.** An image is made from the OS
  disk; ARM child resources of the source VM are not part of it. A VM created
  from the image starts with no run commands.
- They are deleted only when you delete them, or when the VM itself is deleted —
  and **deleting one requires the VM to be running**, because it is an extension
  operation. A stranded run command on a stopped VM is harmless but cannot be
  removed until the VM starts or is deleted.

**But two things the run command touched *are* baked into the image**, because
they live on the OS disk:

1. **Anything your guest script wrote.** The scripts here log to
   `C:\ProgramData\avd-image-setup\*.log`, so those logs ship inside the image.
   They contain paths, versions and exit codes — no credentials — but they are
   there, and they are worth knowing about if you are handing the image to
   someone else.
2. **The staged script itself.** The run-command handler writes the script to
   `C:\Packages\Plugins\Microsoft.CPlat.Core.RunCommandHandlerWindows\<version>\Downloads\Script_<name>_0.ps1`
   before executing it. Whether the handler removes it after a successful run has
   not been verified here, so assume it may persist.

The practical rule: **never pass a secret in `--parameters`.** Those values are
substituted into the staged script on the guest's disk and echoed back in the
resource's `source` property. Azure provides `--protected-parameters` for exactly
this — those values are encrypted and are not logged:

```zsh
az vm run-command create ... \
  --parameters "ExpectedVersion=18.10.0" \
  --protected-parameters "SomeSecret=..."
```

None of the tooling here passes a secret by either route; it relies on `az login`
and on run-command executing as SYSTEM.

## After "set as image" / sysprep

Capturing an image generalises the source VM. Check with:

```zsh
az image show -g <rg> -n <image-name> --query "storageProfile.osDisk.osState" -o tsv
# Generalized
```

A generalised VM is **spent**. Do not start it again and dispatch more run
commands at it — it has been sysprepped and will go through OOBE rather than
coming back as the machine you customised. To make further changes, create a new
VM from the captured image (which is what Nerdio's image-editing workflow does
for you), customise that, and re-capture.

Note also that capturing creates a **second** billable artefact: the image itself,
alongside the source VM's OS disk if you keep the VM. A 128 GiB image is single
digits of dollars per month, but it accumulates if every rebuild leaves one
behind. Old images are worth pruning once a host pool is running on a newer one.

## Reusing a run-command resource

You can, and `az vm run-command update` re-executes the new script against the
same resource. But **it replaces the previous output.** Confirmed by test: a
resource that had printed `RUN_A` reported only `RUN_B` after an update — the
earlier run's transcript is gone.

Since the whole verification approach here depends on reading
`instanceView.output`, reusing one resource for multiple tasks destroys the
evidence of each previous step. Each driver therefore owns its own name:

| Driver | Run-command name |
|---|---|
| `deploy.sh` | `install-vs-cpp` (from `AVD_RUNCMD_NAME`) |
| `repair.sh` | `uninstall-vs` |
| `shortcuts.sh` | `set-desktop-shortcuts` |

Each driver deletes its own stale resource before dispatching, so repeated runs
do not accumulate. Ad-hoc diagnostics are worth giving throwaway names and
deleting afterwards:

```zsh
az vm run-command list -g <rg> --vm-name <vm> --query "[].name" -o tsv
az vm run-command delete -g <rg> --vm-name <vm> --name <name> --yes
```

There are two flavours of run command, and the difference matters here:

- **Managed** (`az vm run-command create/update/show/delete`) — a persistent
  child resource, supports `--async-execution` and a timeout up to 90 minutes.
  Used by all the drivers, because a Visual Studio install outlives the
  synchronous option.
- **Action** (`az vm run-command invoke`) — no resource is created, nothing to
  clean up, but it blocks and is capped at 90 minutes. Convenient for read-only
  probes, which is what the diagnostics in
  [troubleshooting.md](troubleshooting.md) use.

## A cleanup checklist

Do this **before** sealing, while the VM is still running — afterwards the run
command cannot be deleted:

```zsh
./teardown.sh --deallocate                                              # delete, then deallocate
az vm run-command list -g <rg> --vm-name <vm> --query "[].name" -o tsv   # expect empty
az vm get-instance-view -g <rg> -n <vm> \
  --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus|[0]" -o tsv
```

If you have already captured and stopped the VM, the stranded run command is not
worth starting a generalised VM to remove. Leave it: it costs nothing, and it
goes away with the VM.

The last command should print `VM deallocated`. `VM stopped` is **not** the same
thing — a stopped-but-allocated VM still bills for compute. Use
`az vm deallocate`, which is what `teardown.sh --deallocate` calls, rather than
`az vm stop`.

Prefer stopping the VM from your image-management tool (Nerdio or equivalent)
where possible, so its own lifecycle state stays consistent.
