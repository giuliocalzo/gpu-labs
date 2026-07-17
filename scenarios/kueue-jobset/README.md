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

## Sample output

Captured from a fresh `./demo.sh kueue-jobset` run (the inspection step):

```text
==> Inspection: kueue-jobset
--- Workloads (one JobSet = one gang Workload) ---
--- Workloads in 'jobset' (priority / reserved / admitted) ---
NAME                          QUEUE          PRIORITY   RESERVED   ADMITTED
jobset-training-j6ch5-28068   jobset-queue   0          False      <none>
jobset-training-l4wjd-e3d8d   jobset-queue   0          True       True

--- ClusterQueue 'jobset-cq' ---
NAME        PENDING   ADMITTED   RESERVING
jobset-cq   1         1          1
    reserved gpu-flavor: cpu=100m nvidia.com/gpu=16

--- JobSets ---
    NAME             SUSPEND   RESTARTS
    training-j6ch5   true      0
    training-l4wjd   false     0

--- Child Jobs (only the admitted JobSet has them) ---
    NAME                       COMPLETIONS   SUSPEND
    training-j6ch5-workers-0   0             true
    training-j6ch5-workers-1   0             true
    training-l4wjd-workers-0   1             false
    training-l4wjd-workers-1   1             false

--- Pods (workers of the admitted JobSet) ---
    POD                                PHASE     NODE
    training-l4wjd-workers-0-0-dkbzs   Running   gpu-lab-worker6
    training-l4wjd-workers-1-0-4wv7d   Running   gpu-lab-worker2
```

**What it shows:** Each JobSet's two child Jobs (2 × 8 = 16 GPUs) are treated as
one gang Workload. The quota (`nvidia.com/gpu=16`) fits one JobSet, so
`training-l4wjd` is `ADMITTED: True` — `SUSPEND: false`, both child Jobs created,
and their worker pods Running. `training-j6ch5` stays `SUSPEND: true` with a
`Pending` Workload ("16 more needed") and **its child Jobs, while listed, remain
suspended (COMPLETIONS 0)** — Kueue admits or gates the whole JobSet as a unit,
never a partial set of child Jobs.
