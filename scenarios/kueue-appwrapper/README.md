# kueue-appwrapper scenario

Tests Kueue's **AppWrapper integration**: Kueue treats a whole
[CodeFlare AppWrapper](https://project-codeflare.github.io/appwrapper/) (all of
the resources it wraps) as a **single gang Workload**, admitted all-or-nothing
under quota.

An `AppWrapper` is a workload-agnostic envelope: it bundles one or more arbitrary
Kubernetes resources so Kueue can queue and admit them as one logical unit -
without the wrapped controllers needing any Kueue awareness. This scenario wraps
a plain batch/v1 Job, but the same mechanism works for Deployments, PyTorchJobs,
RayJobs, or several resources at once. AppWrapper is a **built-in Kueue
integration** (since Kueue 0.11); the operator is installed by the scenario's
`pre_run` hook. Pods use the `pause` placeholder, so there is no real compute -
just the GPU reservations needed to observe gang admission and quota gating.

## What it tests

1. **Gang admission of wrapped resources.** Each AppWrapper wraps a Job of 2 pods
   x 8 GPUs = 16 GPUs, declared via `spec.components[].podSets`. Kueue admits the
   whole AppWrapper as one unit; the wrapped Job is only created after Kueue
   unsuspends the AppWrapper (`spec.suspend` is controlled by Kueue).
2. **Quota gating on GPUs.** The ClusterQueue grants exactly
   `nvidia.com/gpu: 16`, so only one AppWrapper fits. The second AppWrapper's
   Workload stays **Pending** and its wrapped Job is **never created** until the
   first frees the quota.

## How it works

- `pre_run` installs the AppWrapper operator from its release manifest (pinned by
  `APPWRAPPER_VERSION`, into the `appwrapper-system` namespace; it self-manages
  its webhook TLS - no cert-manager needed), then restarts the Kueue controller
  so it activates the `workload.codeflare.dev/appwrapper` integration (already
  enabled in `base/kueue-values.yaml`) for the newly-installed CRD.
- `manifests/queues.yaml`: the `appwrapper` namespace, `ClusterQueue
  appwrapper-cq` (covers cpu + `nvidia.com/gpu: 16` on the shared `gpu-flavor`),
  and `LocalQueue appwrapper-queue`.
- `manifests/appwrapper.yaml`: an AppWrapper (`generateName`) whose single
  component wraps a batch/v1 Job (`parallelism: 2`, each pod `nvidia.com/gpu: 8`),
  with `podSets` pointing Kueue at the pod template. The scenario creates it twice.

## Run

```bash
./demo.sh kueue-appwrapper
./demo.sh clean kueue-appwrapper
```

## What to look for

- Exactly one AppWrapper Workload is `ADMITTED: True`; the other is Pending.
- `kubectl get appwrappers -n appwrapper` shows both, but only the admitted one
  has a wrapped Job (`kubectl get jobs -n appwrapper`) and pods.
- `appwrapper-cq` shows `nvidia.com/gpu=16` reserved (fully used).
- The pending Workload's condition explains it is waiting for quota.

## Sample output

Captured from a fresh `./demo.sh kueue-appwrapper` run (the inspection step):

```text
==> Inspection: kueue-appwrapper
--- Workloads (one AppWrapper = one gang Workload) ---
--- Workloads in 'appwrapper' (priority / reserved / admitted) ---
NAME                        QUEUE              PRIORITY   RESERVED   ADMITTED
appwrapper-aw-6znwg-5401a   appwrapper-queue   0          False      <none>
appwrapper-aw-kcbzz-8be04   appwrapper-queue   0          True       True

--- ClusterQueue 'appwrapper-cq' ---
NAME            PENDING   ADMITTED   RESERVING
appwrapper-cq   1         1          1
    reserved gpu-flavor: cpu=100m nvidia.com/gpu=16

--- AppWrappers ---
    NAME       SUSPEND   STATUS
    aw-6znwg   true      Suspended
    aw-kcbzz   <none>    Running

--- Wrapped Jobs (only the admitted AppWrapper has one) ---
    NAME           COMPLETIONS   SUSPEND
    aw-job-xcswj   2             false

--- Pods (of the admitted AppWrapper's wrapped Job) ---
    POD                  PHASE     NODE
    aw-job-xcswj-ct4p5   Running   gpu-lab-worker3
    aw-job-xcswj-l9mrs   Running   gpu-lab-worker2
```

**What it shows:** Each AppWrapper wraps a Job of 2 pods × 8 GPUs = 16 GPUs, and
the quota (`nvidia.com/gpu=16`) fits one. `aw-kcbzz` is `ADMITTED: True` /
`Running`: the AppWrapper controller created its wrapped Job (`aw-job-xcswj`,
`SUSPEND: false`) and both pods are Running. `aw-6znwg` stays `SUSPEND: true` /
`Suspended` with a `Pending` Workload ("16 more needed") and **no wrapped Job at
all** — Kueue gates the whole AppWrapper before its contents are ever created.
