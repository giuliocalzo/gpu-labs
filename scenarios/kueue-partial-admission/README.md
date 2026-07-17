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

## Sample output

Captured from a fresh `./demo.sh kueue-partial-admission` run (the inspection step):

```text
==> Inspection: kueue-partial-admission
--- Workload (admitted at reduced size) ---
--- Workloads in 'partial-admission' (priority / reserved / admitted) ---
NAME                QUEUE           PRIORITY   RESERVED   ADMITTED
job-partial-8e3cd   partial-queue   0          True       True

--- ClusterQueue 'partial-cq' ---
NAME         PENDING   ADMITTED   RESERVING
partial-cq   0         1          1
    reserved gpu-flavor: cpu=250m nvidia.com/gpu=40

--- Job parallelism: requested vs admitted ---
    requested parallelism: 8 (64 GPU)
    min parallelism:       2
    current parallelism:   5 (Kueue shrank it to fit 40 GPU)

--- Pods (one per admitted parallel slot) ---
    POD             PHASE     NODE
    partial-5lmvc   Running   gpu-lab-worker5
    partial-66jm5   Running   gpu-lab-worker6
    partial-bv8b6   Running   gpu-lab-worker7
    partial-ldtvv   Running   gpu-lab-worker2
    partial-pspfb   Running   gpu-lab-worker3
```

**What it shows:** The Job asked for `parallelism: 8` (8 × 8 = 64 GPUs) but the
quota is only 40 GPUs. Instead of leaving the whole Job `Pending`, Kueue used the
`job-min-parallelism: 2` annotation to **shrink** it to the largest size that fits
— `parallelism: 5` (5 × 8 = 40 GPUs). The Workload is `ADMITTED: True`, exactly 5
pods are Running, and `partial-cq` shows all `nvidia.com/gpu=40` reserved. The Job
runs partially now rather than not at all.
