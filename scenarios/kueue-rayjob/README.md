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

## Sample output

Captured from a fresh `./demo.sh kueue-rayjob` run (the inspection step):

```text
==> Inspection: kueue-rayjob
--- Workloads (one RayJob = one gang Workload) ---
--- Workloads in 'rayjob' (priority / reserved / admitted) ---
NAME                        QUEUE          PRIORITY   RESERVED   ADMITTED
rayjob-rayjob-b2mvb-aa02a   rayjob-queue   0          True       True
rayjob-rayjob-dfchc-6905d   rayjob-queue   0          False      <none>

--- ClusterQueue 'rayjob-cq' ---
NAME        PENDING   ADMITTED   RESERVING
rayjob-cq   1         1          1
    reserved gpu-flavor: cpu=2500m memory=3272Mi nvidia.com/gpu=8

--- RayJobs (deployment / job status) ---
    NAME           DEPLOYMENT     JOB      SUSPEND
    rayjob-b2mvb   Initializing   <none>   <none>
    rayjob-dfchc   Suspended      <none>   true

--- RayClusters (only the admitted RayJob has one) ---
    NAME                 DESIRED WORKERS   AVAILABLE WORKERS   CPUS   MEMORY   GPUS   STATUS   AGE
    rayjob-b2mvb-vhnkf   1                                     2      3Gi      8               41s

--- Pods (head + worker of the admitted Ray cluster) ---
    POD                                           PHASE     NODE
    rayjob-b2mvb-vhnkf-gpu-workers-worker-r9bb9   Pending   gpu-lab-worker4
    rayjob-b2mvb-vhnkf-head-tghwp                 Pending   gpu-lab-worker

--- Why is the second RayJob pending? ---
    QuotaReserved: Pending - couldn't assign flavors to pod set gpu-workers: insufficient unused quota for nvidia.com/gpu in flavor gpu-flavor, 8 more needed
    PodsReady: WaitForStart - Not all pods are ready or succeeded
```

**What it shows:** Two RayJobs were submitted; the quota (`nvidia.com/gpu=8`) fits
exactly one Ray cluster (head + one GPU worker). The first RayJob is
`ADMITTED: True` and KubeRay materialised its RayCluster (`rayjob-b2mvb-vhnkf`,
8 GPUs) with head+worker pods. The second RayJob is held `SUSPEND: true` by Kueue,
its Workload `Pending` ("8 more needed"), and **no RayCluster or pods exist for
it** — gang gating happens before any Ray resources are created. (Head/worker
pods read `Pending` at capture time as they were still starting.)
