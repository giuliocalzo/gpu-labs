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

## Sample output

Captured from a fresh `./demo.sh grove-podcliques` run (the inspection step):

```text
==> Inspection: grove-podcliques
--- PodCliqueSet (the single object we submitted) ---
    NAME            REPLICAS   AVAILABLE   UPDATED   PCLQS-UPDATED   PCLQS-TOTAL   PCSGS-UPDATED   PCSGS-TOTAL   AGE
    llm-inference   1          1           1                                                                     36s

--- PodCliques (one group of pods per role) ---
    NAME                                       MINAVAIL   REPLICAS   READY   SCHEDULED   UPDATED   AGE
    llm-inference-0-decode                     2          2          2       2           2         25s
    llm-inference-0-frontend                   1          1          1       1           1         25s
    llm-inference-0-prefill-0-prefill-leader   1          1          1       1           1         24s
    llm-inference-0-prefill-0-prefill-worker   2          2          2       2           2         24s

--- PodCliqueScalingGroup (prefill leader + workers, one gang) ---
    NAME                      MINAVAIL   REPLICAS   AVAILABLE   SCHEDULED   UPDATED   PCLQS-UPDATED   PCLQS-TOTAL   AGE
    llm-inference-0-prefill   1          1          1           1           1                                       24s

--- PodGang (scheduler-facing gang Grove generated) ---
    NAME              PHASE     AGE
    llm-inference-0   Pending   25s
    (PodGang stays Pending here: the default scheduler placed the pods but
     doesn't advance PodGang phase - that needs a gang-aware scheduler like KAI.)

--- Pods (placement across the fake-GPU nodes) ---
    POD                                              PHASE     NODE
    llm-inference-0-decode-2r47m                     Running   gpu-lab-worker7
    llm-inference-0-decode-bzm9t                     Running   gpu-lab-worker
    llm-inference-0-frontend-zdbz8                   Running   gpu-lab-worker2
    llm-inference-0-prefill-0-prefill-leader-7zd9m   Running   gpu-lab-worker6
    llm-inference-0-prefill-0-prefill-worker-gmskn   Running   gpu-lab-worker3
    llm-inference-0-prefill-0-prefill-worker-jfvbh   Running   gpu-lab-worker4
```

**What it shows:** The single `llm-inference` PodCliqueSet expanded into the whole
object hierarchy — 4 PodCliques (`frontend`, `prefill-leader`, `prefill-worker`,
`decode`), 1 PodCliqueScalingGroup (`prefill`), 1 PodGang, and 6 pods — all from
one submitted manifest. All 6 pods are Running (5 GPU pods on 5 distinct nodes,
plus the CPU-only frontend), started in dependency order frontend → prefill →
decode. The `PodGang` stays `Pending` because this baseline uses the **default**
scheduler, which places pods but doesn't advance the gang phase; the
`grove-kai-topology` scenario adds KAI to gang-schedule and topology-pack it.
