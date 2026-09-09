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

After sealing an image:

```zsh
az vm run-command list -g <rg> --vm-name <vm> --query "[].name" -o tsv   # expect empty
./teardown.sh --deallocate
az vm get-instance-view -g <rg> -n <vm> \
  --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus|[0]" -o tsv
```

The last command should print `VM deallocated`. `VM stopped` is **not** the same
thing — a stopped-but-allocated VM still bills for compute. Use
`az vm deallocate`, which is what `teardown.sh --deallocate` calls, rather than
`az vm stop`.

Prefer stopping the VM from your image-management tool (Nerdio or equivalent)
where possible, so its own lifecycle state stays consistent.
