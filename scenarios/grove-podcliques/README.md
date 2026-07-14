# grove-podcliques scenario

Tests **NVIDIA Grove** and its **PodClique** family: how a single high-level
`PodCliqueSet` is expanded by the Grove operator into a full set of Kubernetes
objects for a disaggregated inference stack, with role-based grouping and
explicit startup ordering.

This scenario is **not** a Kueue scenario - it showcases a different component
running on the same shared lab cluster. Grove is installed by the scenario's
`pre_run` hook and removed by `post_run` (it is not part of the base install).

## What it tests

1. **One spec, many objects.** We submit a single `PodCliqueSet`. Grove's
   operator expands it into:
   - 4 **PodCliques** (one per role: `frontend`, `prefill-leader`,
     `prefill-worker`, `decode`),
   - 1 **PodCliqueScalingGroup** (`prefill` = leader + workers, the tightly
     coupled gang that scales together),
   - 1 **PodGang** (the scheduler-facing gang object Grove generates),
   - 6 **Pods** (1 + 1 + 2 + 2 replicas).
2. **Role-based structure.** Each clique has its own role, replica count, and
   resource shape - the GPU roles each claim a whole 8-GPU node, the frontend is
   CPU-only.
3. **Explicit startup ordering.** With `cliqueStartupType: Explicit` and
   `startsAfter`, pods come up in waves: `frontend` → `prefill` → `decode`.

## How it works

- `pre_run` installs the Grove operator via Helm
  (`oci://ghcr.io/ai-dynamo/grove/grove-charts`, pinned by `GROVE_VERSION`).
- `manifests/podcliqueset.yaml` defines the `grove` namespace and the
  `llm-inference` PodCliqueSet.
- Pods are `pause` placeholders (no real load); the 5 GPU pods each request
  `nvidia.com/gpu: 8`, so they spread one-per-node across the fake-GPU workers.
- Scheduling uses the default kube-scheduler. Grove still creates the PodGang,
  but true all-or-nothing gang scheduling would require a gang-aware scheduler
  (e.g. NVIDIA KAI-Scheduler), which this scenario intentionally does not install.

## Run

```bash
./demo.sh grove-podcliques
./demo.sh clean grove-podcliques
```

## What to look for

- `kubectl get podcliquesets,podcliques,podcliquescalinggroups,podgangs -n grove`
  shows the one submitted object fanning out into the whole hierarchy.
- The pod table shows 6 pods; the 5 GPU pods land on 5 different nodes.
- Pod `Ready` timestamps reflect the startup order: frontend first, then the
  prefill cliques, then decode.
