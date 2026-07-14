# DRA scenario (stub)

Dynamic Resource Allocation (DRA) lets workloads request devices through the
`resource.k8s.io` API (DeviceClasses / ResourceClaims) instead of the classic
extended-resource counter (`nvidia.com/gpu`). Kueue can quota and admit these
claims, but the plumbing is heavier than the other scenarios, so this folder is
a documented stub rather than a live demo.

## Why it can't just run on the shared cluster

The other scenarios only need Kueue objects + jobs, which we can apply on the
fly. DRA instead needs changes baked into the cluster at creation time plus an
external driver.

## What a real DRA demo requires

1. **Cluster feature gates (recreate the cluster).** Add to
   `cluster/kind-cluster.yaml`:

   ```yaml
   featureGates:
     DynamicResourceAllocation: true
   runtimeConfig:
     "resource.k8s.io/v1beta1": "true"
   kubeadmConfigPatches:
     - |
       kind: ClusterConfiguration
       apiServer:
         extraArgs:
           runtime-config: "resource.k8s.io/v1beta1=true"
       scheduler:
         extraArgs:
           feature-gates: "DynamicResourceAllocation=true"
   ```

   Then rebuild with `FORCE_RECREATE=1 ./demo.sh dra`.

2. **A DRA driver.** Install a driver that publishes `ResourceSlice`s and a
   `DeviceClass`, e.g. the upstream
   [dra-example-driver](https://github.com/kubernetes-sigs/dra-example-driver)
   or the NVIDIA GPU DRA driver.

3. **Kueue DRA support.** Enable the relevant Kueue feature gate and map the
   `DeviceClass` into a ClusterQueue's covered resources so claims consume quota.

4. **Workloads that use a claim.** A Job referencing a `ResourceClaimTemplate`
   instead of requesting `nvidia.com/gpu`.

## Status

Left as a stub on purpose: it needs real (or emulated) DRA drivers to be
meaningful, and mixing DRA feature gates into the shared cluster would change
the baseline for every other scenario.
