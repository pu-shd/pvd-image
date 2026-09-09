# Access: what you need, and proving what you have

The premise of this tooling is that you can reach the image VM through the Azure
control plane but **not** over the network. This document shows how to establish
that for your own environment rather than assuming it, and what permissions are
actually required.

## Permissions you need

Enough to read the VM and create run-commands on it:

- `Microsoft.Compute/virtualMachines/read`
- `Microsoft.Compute/virtualMachines/runCommands/*`
- `Microsoft.Compute/virtualMachines/start` and `.../deallocate` if you want the
  drivers to manage power state

Owner or Contributor on the **VM's resource group** covers all of it. Notably you
need **no access to the vnet** or the network resource group — which is the whole
point, since in a managed AVD estate those are frequently owned by a different
team.

Check your effective permissions on the resource group:

```zsh
az rest --method get --url \
  "https://management.azure.com/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Authorization/permissions?api-version=2022-04-01" \
  --query "value[].{actions:actions, notActions:notActions}" -o json
```

`[{"actions": ["*"], "notActions": []}]` means full control of that group. An
empty `[]` means no access at all.

Note that `az role assignment list --assignee <you>` shows only **direct**
assignments. Access inherited through a group will not appear there, so use the
`permissions` endpoint above to see what you can really do. It is entirely normal
to have `*` on one resource group and nothing on its neighbour.

## Locating the VM from an IP address

If all you have been given is a private IP, Azure Resource Graph finds the rest
(needs `az extension add --name resource-graph`):

```zsh
az graph query -q "resources
  | where type =~ 'microsoft.network/networkinterfaces'
  | mv-expand ipconfig=properties.ipConfigurations
  | where ipconfig.properties.privateIPAddress == '<YOUR.VM.IP>'
  | project name, resourceGroup, subscriptionId,
            vm=tostring(properties.virtualMachine.id),
            subnet=tostring(ipconfig.properties.subnet.id)"
```

Resource Graph only returns what you have RBAC read on, so a result here also
tells you something about your access.

## Proving the network routes are closed

Worth doing once, so you know the constraint is real rather than assumed.

**Can a jump host reach RDP?** From any host you can already log into:

```sh
timeout 5 bash -c "cat </dev/null >/dev/tcp/<VM_PRIVATE_IP>/3389" \
  && echo REACHABLE || echo no-route
```

Compare against a port you know is open (`files.example.edu:445`, say) from the
same host. If the known-good port answers and the VM does not, forwarding works
and the destination genuinely is not routable — an SSH `LocalForward` cannot
help. The routing table usually confirms it:

```sh
ip route get <VM_PRIVATE_IP>
```

A result that goes `via` your default gateway, rather than a specific interface
for the private range, means the host has no path into that vnet and is handing
the packets to a router that will drop them.

**Is there any public entry point?**

```zsh
az graph query -q "resources
  | where type =~ 'microsoft.network/publicipaddresses'
  | where subscriptionId == '<sub>'
  | project name, resourceGroup, ip=tostring(properties.ipAddress)" -o table
```

Zero rows across an AVD subscription is common and usually deliberate policy.
Do not respond by attaching a public IP to the image VM: it would put RDP on the
open internet, and a policy denying public IPs will most likely block it anyway.

**Is there an Azure Bastion?**

```zsh
az graph query -q "resources
  | where type =~ 'microsoft.network/bastionHosts'
  | project name, resourceGroup, subscriptionId, sku=tostring(sku.name)" -o table
```

If one exists in the VM's vnet, you have a good option for interactive work —
`az network bastion tunnel` gives you a local port forwarded to 3389 over the
control plane, needing no route of your own:

```zsh
az network bastion tunnel --name <bastion> --resource-group <network-rg> \
  --target-resource-id <vm-resource-id> --resource-port 3389 --port 13389
# then point your RDP client at localhost:13389
```

Native-client tunnelling requires the **Standard** SKU; Basic does not support
it.

If no Bastion exists, deploying one requires an `AzureBastionSubnet` (a `/26` or
larger) **inside the target vnet**, which means write access to the network
resource group. Putting the Bastion resource in your own resource group does not
avoid this — the subnet reference is what gets authorised. Nor does peering a
vnet of your own, since peering is a write on both sides. If the vnet is not
yours, this is a request to another team, not a task.

## What run-command can and cannot do

Can:

- Run arbitrary PowerShell as **SYSTEM**, with no network path and no local
  credentials
- Return stdout/stderr, an exit code, and an execution state
- Run asynchronously for up to 90 minutes

Cannot:

- Show you a GUI, or prove an application is usable interactively
- Survive a reboot mid-script
- Exceed the 90-minute ceiling, or run more than 25 managed commands per VM

So it is excellent for installs, file and registry work, and verification — and
insufficient as the *only* check before you ship an image to users. Budget one
interactive session at the end.

## A note on the local administrator account

You do not need it for any of this. Run-command executes as SYSTEM, which is
strictly more privileged than a local admin for these purposes. Keep those
credentials for the one interactive verification session, and out of any script
or config file here.
