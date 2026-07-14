# kueue-rayjob scenario

Tests Kueue's **RayJob integration**: Kueue treats a whole RayJob (its head +
worker pods = one RayCluster) as a **single gang Workload**, admitted
all-or-nothing under quota.

Unlike the other scenarios, this one runs a **real workload**: KubeRay needs the
`rayproject/ray` image to form an actual Ray cluster, so pods are not `pause`
placeholders and the first image pull can take a few minutes. The KubeRay
operator is installed by the scenario's `pre_run` hook and removed by `post_run`
(it is not part of the base install).

## What it tests

1. **Gang admission of a multi-pod workload.** Each RayJob's Ray cluster (1 head
   + 1 GPU worker) is admitted by Kueue as one unit. KubeRay only creates the
   pods after Kueue unsuspends the RayJob (`spec.suspend` is controlled by Kueue).
2. **Quota gating on GPUs.** The worker claims a whole 8-GPU node. The
   ClusterQueue grants exactly `nvidia.com/gpu: 8`, so only one RayJob's cluster
   fits; the second RayJob's Workload stays **Pending** and gets **no pods** at
   all until the first finishes and frees the quota.

## How it works

- `pre_run` installs the KubeRay operator via Helm (pinned by `KUBERAY_VERSION`).
  Kueue's `ray.io/rayjob` integration is already enabled in
  `base/kueue-values.yaml`.
- `manifests/queues.yaml`: the `rayjob` namespace, `ClusterQueue rayjob-cq`
  (covers cpu + memory + `nvidia.com/gpu: 8` on the shared `gpu-flavor`), and
  `LocalQueue rayjob-queue`.
- `manifests/rayjob.yaml`: a RayJob template (`generateName`, `suspend: true`,
  `shutdownAfterJobFinishes: true`) whose worker requests `nvidia.com/gpu: 8`.
  The scenario creates it twice. The entrypoint just sleeps ~180s so the first
  cluster holds quota long enough to observe the second staying Pending.

## Run

```bash
./demo.sh kueue-rayjob
./demo.sh clean kueue-rayjob
```

## What to look for

- Exactly one RayJob Workload is `ADMITTED: True`; the other is Pending.
- `kubectl get rayclusters -n rayjob` shows one RayCluster (for the admitted
  RayJob); the pending RayJob has none.
- `rayjob-cq` shows `nvidia.com/gpu=8` reserved (fully used).
- The pending Workload's condition explains it is waiting for quota.
