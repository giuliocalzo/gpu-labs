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
