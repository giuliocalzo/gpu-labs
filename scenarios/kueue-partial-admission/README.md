# kueue-partial-admission scenario

Tests Kueue's **partial admission**: a Job that asks for more than the available
quota is admitted at a **reduced parallelism** (down to a declared minimum)
instead of staying fully Pending.

By default Kueue admits a workload all-or-nothing. When a Job opts in with the
`kueue.x-k8s.io/job-min-parallelism` annotation, Kueue may instead shrink the
Job's `spec.parallelism` to the largest value that fits the quota (as long as it
stays `>=` the minimum), admit it at that size, and patch `spec.parallelism`
down. Pods use the `pause` placeholder, so there is no real compute - just the
GPU reservations needed to observe the reduced-size admission.

## What it tests

1. **Reduced-size admission.** The Job requests `parallelism: 8` with each pod
   claiming `nvidia.com/gpu: 8` (64 GPUs), and declares
   `job-min-parallelism: 2`. The ClusterQueue only grants `nvidia.com/gpu: 40`.
2. **Shrink-to-fit.** Kueue admits the Job at `parallelism: 5` (5 x 8 = 40 GPUs,
   the largest count that fits and is `>=` the minimum of 2). Without partial
   admission the whole Job would stay Pending.

## How it works

- `manifests/queues.yaml`: the `partial-admission` namespace, `ClusterQueue
  partial-cq` (covers cpu + `nvidia.com/gpu: 40` on the shared `gpu-flavor`), and
  `LocalQueue partial-queue`.
- `manifests/job.yaml`: a suspended batch/v1 Job with `parallelism: 8`,
  `completions: 8`, the `kueue.x-k8s.io/job-min-parallelism: "2"` annotation, and
  a `pause` container requesting `nvidia.com/gpu: 8`.
- Partial admission is a Beta Kueue feature (on by default), so no extra config
  is needed.

## Run

```bash
./demo.sh kueue-partial-admission
./demo.sh clean kueue-partial-admission
```

## What to look for

- The Job's Workload is `ADMITTED: True` even though the full request (64 GPUs)
  exceeds the 40-GPU quota.
- `kubectl get job partial -n partial-admission -o jsonpath='{.spec.parallelism}'`
  reports **5**, not the original 8 - Kueue shrank it to fit.
- 5 pods are Running (one per admitted slot); `partial-cq` shows
  `nvidia.com/gpu=40` fully reserved.
