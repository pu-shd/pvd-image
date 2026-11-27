# Host pools: start from a template

`pvd-image` customises an image. The host pool that runs it is created in
Nerdio, and most host pool problems come from settings chosen there, not
from the image. Lessons from building pools this way:

## Keep an empty template pool, and clone it

Nerdio writes a pool's settings when it creates the pool, and options chosen
at creation are not always editable afterwards with a Nerdio role. Two pools
created by hand with "the same" settings can still differ. In one case, the
second pool asked for a username and password because it lacked the RDP
properties for Entra ID single sign-on. Its hosts also got FSLogix, which the
working pool's hosts did not.

The reliable way to get a working pool is to **clone a known-good one**. Keep
an **empty template pool**, with no hosts and no users, cloned from a pool
whose sign-in and settings you have verified, and clone every new pool from
it. Name it so nobody mistakes it for a real pool, such as `<DEPT>-TEMPLATE`,
and record its name in your private config repos, not here.

After cloning, the clone has the template's settings, which is the point.
Change these, because they are per-course:

| Setting | Why |
|---|---|
| Name | |
| Desktop image (pool and auto-scale template) | A clone keeps the source's image |
| VM size, auto-scale values | per course |
| User or group assignments | not cloned; the new app group starts empty |

## Single sign-on needs two RDP properties

For Entra ID joined hosts, connecting without a password prompt needs:

```
targetisaadjoined:i:1;enablerdsaadauth:i:1;
```

(`redirectwebauthn:i:1` also lets passkeys and security keys work inside the
session.) If they are missing, the client falls back to a Windows username
and password prompt even though the hosts are Entra-joined. Compare a pool's
properties with the template's:

```zsh
az desktopvirtualization hostpool list -g <resource-group> --subscription <subscription> \
  --query "[].{name:name, rdp:customRdpProperty}" -o json
```

## Start VM on Connect, or keep one host running

A pool whose auto-scale minimum is 0 stops every host when idle. Users can
then only connect if the pool has **Start VM on Connect** on, so that a
connection starts a host. Check before relying on it, because a clone
inherits the setting:

```zsh
az desktopvirtualization hostpool show -g <resource-group> -n <pool> \
  --subscription <subscription> --query startVMOnConnect
```

If it is off and cannot be changed, set the minimum active hosts to 1. You
can keep it running only during class hours with Nerdio's pre-stage hosts or
scale-in schedule.

## Check from Azure, without a desktop session

Once a host is running, prove the image works on it the way a user would,
with Run Command (the command depends on what the image installs; for the
PyKX step, `<prefix>-test`):

```zsh
az vm run-command invoke -g <resource-group> -n <host> --subscription <subscription> \
  --command-id RunPowerShellScript --query "value[0].message" -o tsv \
  --scripts '$env:Path = [Environment]::GetEnvironmentVariable("Path","Machine"); cmd /c pykx-test'
```

To list a pool's session hosts, use the REST API. Version 1.0.0 of the
`desktopvirtualization` CLI extension has no `sessionhost` command:

```zsh
az rest --method get --url "https://management.azure.com/subscriptions/<subscription>/resourceGroups/<resource-group>/providers/Microsoft.DesktopVirtualization/hostPools/<pool>/sessionHosts?api-version=2024-04-03" \
  --query "value[].{name:name, status:properties.status}" -o table
```

Sign-in itself, including the absence of a password prompt, can only be
checked by connecting.
