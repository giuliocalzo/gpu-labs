# kueue-jobset scenario

Tests Kueue's **JobSet integration**: Kueue treats a whole
[JobSet](https://github.com/kubernetes-sigs/jobset) (all of its child Jobs) as a
**single gang Workload**, admitted all-or-nothing under quota.

A JobSet groups several Jobs that must run together - the canonical shape for
distributed training (multiple identical "worker" Jobs, one per node). The
JobSet operator is installed by the scenario's `pre_run` hook and removed by
`post_run` (it is not part of the base install). Pods use the `pause`
placeholder, so there is no real compute - just the GPU reservations needed to
observe gang admission and quota gating.

## What it tests

1. **Gang admission of a multi-Job workload.** Each JobSet fans out to 2 worker
   Jobs (2 pods, 8 GPUs each = 16 GPUs). Kueue admits the whole JobSet as one
   unit; the child Jobs/pods are only created after Kueue unsuspends the JobSet
   (`spec.suspend` is controlled by Kueue).
2. **Quota gating on GPUs.** The ClusterQueue grants exactly
   `nvidia.com/gpu: 16`, so only one JobSet fits. The second JobSet's Workload
   stays **Pending** and gets **no child Jobs** until the first frees the quota.

## How it works

- `pre_run` installs the JobSet operator via Helm (pinned by `JOBSET_VERSION`,
  `certManager.enable=true` reuses the base cert-manager), then restarts the
  Kueue controller so it activates the `jobset.x-k8s.io/jobset` integration
  (already enabled in `base/kueue-values.yaml`) for the newly-installed CRD.
- `manifests/queues.yaml`: the `jobset` namespace, `ClusterQueue jobset-cq`
  (covers cpu + `nvidia.com/gpu: 16` on the shared `gpu-flavor`), and
  `LocalQueue jobset-queue`.
- `manifests/jobset.yaml`: a JobSet template (`generateName`, `suspend: true`)
  with one `workers` replicatedJob of `replicas: 2`, each pod requesting
  `nvidia.com/gpu: 8`. The scenario creates it twice.

## Run

```bash
./demo.sh kueue-jobset
./demo.sh clean kueue-jobset
```

## What to look for

- Exactly one JobSet Workload is `ADMITTED: True`; the other is Pending.
- `kubectl get jobsets -n jobset` shows both JobSets, but only the admitted one
  has child Jobs (`kubectl get jobs -n jobset`) and pods.
- `jobset-cq` shows `nvidia.com/gpu=16` reserved (fully used).
- The pending Workload's condition explains it is waiting for quota.
