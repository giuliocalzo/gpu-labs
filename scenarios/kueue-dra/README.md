# kueue-dra scenario

Shows Kueue putting **Dynamic Resource Allocation (DRA)** devices under quota.
Instead of requesting the classic extended resource (`nvidia.com/gpu`), pods
request devices through the `resource.k8s.io` API (a `ResourceClaimTemplate`
referencing a `DeviceClass`), and Kueue accounts for them in a ClusterQueue.

## Why this one works on the shared cluster

The cluster runs Kubernetes v1.35, where **core DRA is GA and enabled by
default** (`resource.k8s.io/v1` is served) - so no cluster-creation feature
gates or rebuild are needed. We only add:

1. **A DRA driver** - the upstream
   [dra-example-driver](https://github.com/kubernetes-sigs/dra-example-driver)
   deployed from its published image (`manifests/driver.yaml`). It advertises 8
   *simulated* GPUs per worker via `ResourceSlice`s (no real hardware). We wrap
   them in a `gpu.nvidia.com` `DeviceClass` whose selector still matches the
   example driver's real (hardcoded) driver name, `gpu.example.com`.
2. **Kueue DRA integration** - the `KueueDRAIntegration` feature gate plus a
   `deviceClassMappings` entry mapping `gpu.nvidia.com` → the logical quota
   resource `nvidia.com/gpu`. Both live in `base/kueue-values.yaml`, so they're
   part of the normal Kueue install (inert for the other scenarios).

## What it demonstrates

- A `ClusterQueue` grants `nvidia.com/gpu: 4`, while the driver advertises 64
  mock devices. Six 1-GPU jobs are submitted: Kueue admits 4 and leaves 2
  **Pending on quota** - proving Kueue's quota, not the physical device count,
  gates admission.
- Admitted pods get real `ResourceClaim`s allocated by the kube-scheduler and
  run; you can see the claims and the published `ResourceSlice`s.

## Run

```bash
./demo.sh kueue-dra
./demo.sh clean kueue-dra
```

## Quota accounting path

This uses Kueue's **ResourceClaimTemplate** path (beta since Kueue v0.18), which
needs `deviceClassMappings`. The alternative **extended-resource** path (request
`nvidia.com/gpu` directly, backed by a `DeviceClass.spec.extendedResourceName`)
is alpha and additionally needs the Kubernetes `DRAExtendedResource` gate (beta
in 1.36), so it isn't used here.

## Sample output

Captured from a fresh `./demo.sh kueue-dra` run (the inspection step):

```text
==> Inspection: kueue-dra
--- Workloads in 'dra' (priority / reserved / admitted) ---
NAME              QUEUE             PRIORITY   RESERVED   ADMITTED
job-dra-1-ca73b   dra-local-queue   0          False      <none>
job-dra-2-168cf   dra-local-queue   0          <none>     <none>
job-dra-3-885b2   dra-local-queue   0          True       True
job-dra-4-d2e94   dra-local-queue   0          True       True
job-dra-5-a9383   dra-local-queue   0          True       True
job-dra-6-7b06c   dra-local-queue   0          True       True

--- ClusterQueue 'dra-cluster-queue' ---
NAME                PENDING   ADMITTED   RESERVING
dra-cluster-queue   2         4          4
    reserved gpu-flavor: cpu=200m nvidia.com/gpu=4

--- Mock GPU inventory ---
    ResourceSlices: 8 | total mock devices: 64

--- ResourceClaims (DRA allocations for admitted pods) ---
    NAME                    STATE                AGE
    dra-3-tjz6j-gpu-wmwsq   allocated,reserved   21s
    dra-4-mpbr9-gpu-wk4wk   allocated,reserved   21s
    dra-5-vgkcw-gpu-qgnw4   allocated,reserved   21s
    dra-6-pmr47-gpu-v49dg   allocated,reserved   21s

--- Job pods (only admitted jobs have pods; pending jobs stay suspended) ---
    POD           PHASE     NODE
    dra-3-tjz6j   Pending   gpu-lab-worker2
    dra-4-mpbr9   Pending   gpu-lab-worker6
    dra-5-vgkcw   Pending   gpu-lab-worker5
    dra-6-pmr47   Pending   gpu-lab-worker8

--- Why are the extra jobs pending? ---
    PodsReady: WaitForStart - Not all pods are ready or succeeded
    QuotaReserved: Pending - couldn't assign flavors to pod set main: insufficient unused quota for nvidia.com/gpu in flavor gpu-flavor, 1 more needed
```

**What it shows:** The mock DRA driver advertises plenty of hardware (8
ResourceSlices / 64 devices), but the ClusterQueue caps `nvidia.com/gpu` at **4**.
So of the 6 jobs, Kueue admits exactly 4 (`ADMITTED: True`), and each admitted pod
gets a real DRA `ResourceClaim` in state `allocated,reserved`. The remaining 2
stay `PENDING` with "insufficient unused quota ... 1 more needed" — quota, not the
driver's inventory, is the limit. (The admitted pods show `Pending` at capture
time only because the pause containers hadn't started yet; their claims are
already allocated.)
