# Runtime verification — the claims that can only be settled by running them

Built and run 2026-09-20. Every check in here **passed** on a real cluster; the
results are written up in `_blueprint/FACTCHECK-RESULTS.md` under "RUNTIME
verification".

## The host

`build-acd.sh` creates VM 130 (`acd-lab`, 192.168.126.245) on the Proxmox lab
server from the Ubuntu 24.04 cloud image: 8 vCPU, 16 GB, 80 GB, and k3s pinned
with `INSTALL_K3S_VERSION=v1.37.0+k3s1`. It destroys and recreates VM 130 if one
exists, and touches nothing else on the host — several other courses' VMs run
there.

```
scp acd-lab-user-data pve:/var/lib/vz/snippets/
ssh pve 'bash -s' < build-acd.sh
```

The cloud-init drive is the part that is easy to get wrong: without an `ide2`
cloud-init disk the VM boots with no IP and no key, and the sequence in
`build-acd.sh` is the corrected one.

## The checks

Run in order; each is independent and none exits early, so one failure never
hides the rest.

| Script | Covers |
|---|---|
| `verify.sh` | k3s baseline (S02 L01, S09 L02), Gateway API CRDs and provider state (S02 L06), **the 262144-byte wall (S02 L03)**, the empty notifications ConfigMap (S12 L03), all five metrics ports (S12 L01) |
| `verify2.sh` | the notification catalog's eight triggers, the silently-ignored unlabelled cluster Secret (S09 L03), chart appVersion (S02 L02), Argo Rollouts install |
| `verify3.sh` | **the three AnalysisRuns (S10 L05)** — Job passes, Job fails, and the Web provider short-circuits |
| `verify4.sh` | **the whole Gateway API TLS chain (S02 L06)** end to end, to a real HTTP 200 over TLS |
| `verify5.sh` | Helm 4.3.0, and the Multipass `--format json` schema capture (S09 L02) |

## What `verify3.sh` is actually for

It is the one to keep. It proves, rather than argues, that Argo Rollouts' **Web**
metric provider returns `Successful` on a `successCondition` that cannot be true,
when the endpoint serves anything that is not JSON — which is what `storefront`
serves. Run it before anyone is tempted to "simplify" S10 L05 back to the Web
provider. See L-128.

## Cleanup

The host is disposable. `ssh pve 'qm stop 130 && qm destroy 130 --purge'` when it
is no longer wanted; re-running `build-acd.sh` rebuilds it from nothing.
