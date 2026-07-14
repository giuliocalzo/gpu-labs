# kueue-training-operator scenario

Tests Kueue's **Kubeflow Trainer integration**: Kueue treats a whole
[TrainJob](https://www.kubeflow.org/docs/components/trainer/) (all of its
training nodes) as a **single gang Workload**, admitted all-or-nothing under
quota.

Kubeflow **Trainer V2** is the successor to the v1 Training Operator. A
`TrainJob` references a `ClusterTrainingRuntime` (the reusable template) and the
trainer controller materialises it as a JobSet of N training nodes. Kueue
manages the TrainJob's `spec.suspend`, so the whole job is gang-admitted.

Kubeflow Trainer is installed by the scenario's `pre_run` hook (it is not part of
the base install). To keep the lab free of real compute, the TrainJob uses a
custom `pause`-based runtime instead of the official multi-GB `torch-distributed`
one - just the GPU reservations needed to observe gang admission and quota gating.

## What it tests

1. **Gang admission of a multi-node workload.** Each TrainJob runs 2 training
   nodes (2 pods, 8 GPUs each = 16 GPUs). Kueue admits the whole TrainJob as one
   unit; the pods are only created after Kueue unsuspends it (`spec.suspend` is
   controlled by Kueue).
2. **Quota gating on GPUs.** The ClusterQueue grants exactly
   `nvidia.com/gpu: 16`, so only one TrainJob fits. The second TrainJob's
   Workload stays **Pending** and gets **no pods** until the first frees the quota.

## How it works

- `pre_run` installs Kubeflow Trainer via Helm (pinned by
  `KUBEFLOW_TRAINER_VERSION`, into the `kubeflow-system` namespace; the chart
  bundles a `jobset-controller` subchart since a TrainJob runs as a JobSet, and
  self-manages its webhook TLS - no cert-manager needed), then restarts the Kueue
  controller so it activates the `trainer.kubeflow.org/trainjob` integration
  (already enabled in `base/kueue-values.yaml`) for the newly-installed CRD.
- `manifests/runtime.yaml`: a `ClusterTrainingRuntime gpu-lab-pause` with a plain
  `numNodes` mlPolicy (no framework command injection) and a `pause` container
  requesting `nvidia.com/gpu: 8`.
- `manifests/queues.yaml`: the `training` namespace, `ClusterQueue training-cq`
  (covers cpu + `nvidia.com/gpu: 16` on the shared `gpu-flavor`), and
  `LocalQueue training-queue`.
- `manifests/trainjob.yaml`: a TrainJob template (`generateName`, `suspend: true`)
  with `numNodes: 2` and `resourcesPerNode` of `nvidia.com/gpu: 8`, referencing
  the runtime. The scenario creates it twice.

> Because Kubeflow Trainer bundles its own JobSet controller in `kubeflow-system`,
> avoid running this alongside `kueue-jobset` (which installs JobSet separately)
> on the shared cluster - `clean` one before running the other.

## Run

```bash
./demo.sh kueue-training-operator
./demo.sh clean kueue-training-operator
```

## What to look for

- Exactly one TrainJob Workload is `ADMITTED: True`; the other is Pending.
- `kubectl get trainjobs -n training` shows both TrainJobs, but only the admitted
  one has pods (`kubectl get pods -n training`: 2 training nodes).
- `training-cq` shows `nvidia.com/gpu=16` reserved (fully used).
- The pending Workload's condition explains it is waiting for quota.
