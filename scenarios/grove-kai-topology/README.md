# grove-kai-topology

Grove describes a disaggregated LLM inference stack; the **NVIDIA KAI Scheduler**
turns that description into real, gang-scheduled, topology-aware placement.

## What this scenario tests

1. **Gang scheduling** — KAI admits the whole Grove `PodGang` all-or-nothing.
   Every pod (frontend + prefill leader/workers + decode) goes from `Pending` to
   `Running` together. This is the piece the `grove-podcliques` baseline is
   missing: with the default kube-scheduler the same `PodGang` never schedules.
2. **Topology-aware placement** — the prefill scaling group (leader + 2 workers =
   3 whole-node pods, 24 GPUs) carries a `topologyConstraint` that forces KAI to
   pack it into a **single block**.

## How it works

- **`manifests/topology.yaml`**
  - a KAI `Topology` (`kai.scheduler/v1alpha1`) describing the cluster hierarchy
    `block → rack → host` from the node labels in `cluster/kind-cluster.yaml`;
  - a Grove `ClusterTopologyBinding` mapping the domain names (`block`, `rack`,
    `host`) to those node-label keys and binding them to the KAI Topology;
  - a small KAI `Queue` hierarchy (`grove-root` → `grove-queue`) the pods run under.
  - The KAI Topology's name matches `topologyConstraint.topologyName`: Grove
    passes that name straight through to KAI as the topology reference.
- **`manifests/podcliqueset.yaml`** — the same disaggregated stack as
  `grove-podcliques`, but every clique pod sets `schedulerName: kai-scheduler`
  and carries the `kai.scheduler/queue: grove-queue` label, and the `prefill`
  scaling group adds:

  ```yaml
  topologyConstraint:
    topologyName: gpu-lab-topology
    pack:
      required: block     # the whole gang must fit in one block
      preferred: rack     # ...packed as tightly as possible toward one rack
  ```

- **`scenario.sh`**
  - `pre_run` installs the KAI Scheduler and the Grove operator (with
    Topology-Aware Scheduling enabled — required before any `topologyConstraint`
    is accepted);
  - `apply` creates the topology/queues, submits the `PodCliqueSet`, and waits
    for KAI to bring the gang up;
  - `inspect` shows the Grove `PodGang`, the KAI `PodGroup`, and each pod's
    block/rack so the prefill co-location is visible;
  - `cleanup` removes the workload and uninstalls both operators.

## Topology math (why the constraint is meaningful)

The kind cluster is 8 GPU nodes = 2 blocks × 2 racks × 2 hosts, 8 GPUs each:

| Domain | Nodes | GPUs |
| ------ | ----- | ---- |
| host   | 1     | 8    |
| rack   | 2     | 16   |
| block  | 4     | 32   |

The prefill gang needs 3 nodes (24 GPUs). That **fits in one block (32)** but
**not in one rack (16)**, so `required=block` is satisfiable while `preferred=rack`
can only be partially honored — a perfect, observable demonstration.

## What to look for

Run it:

```bash
./demo.sh grove-kai-topology
```

- All six pods reach `Running` (KAI admitted the gang all-or-nothing).
- In the placement table the three `prefill-*` pods share the **same block**;
  two share a rack and the third is in the other rack of that block.

> Note: in this Grove alpha the `PodGang.status.phase` field stays `Pending` when
> an external scheduler backend (KAI) does the scheduling — the phase field isn't
> advanced by the backend. The real success signals are the pods running as a
> gang and the KAI `PodGroup`, not the Grove phase string.

## Sample output

Captured from a fresh `./demo.sh grove-kai-topology` run (the inspection step):

```text
==> Inspection: grove-kai-topology
--- Grove PodGang (what Grove generates for the scheduler) ---
    NAME              PHASE     AGE
    llm-inference-0   Pending   25s

--- KAI PodGroup (the actual scheduler-facing gang KAI admits) ---
    NAME                                                      AGE
    pg-llm-inference-0-7dff2a9f-9b96-47b2-bc7e-bdbc62bdadda   25s

--- PodCliqueScalingGroup (the prefill gang) ---
    NAME                      MINAVAIL   REPLICAS   AVAILABLE   SCHEDULED   UPDATED   PCLQS-UPDATED   PCLQS-TOTAL   AGE
    llm-inference-0-prefill   1          1          1           1           1                                       25s

--- Pods (all Running = KAI admitted the whole gang all-or-nothing) ---
    POD                                              PHASE     NODE
    llm-inference-0-decode-48w7w                     Running   gpu-lab-worker
    llm-inference-0-decode-fxppf                     Running   gpu-lab-worker2
    llm-inference-0-frontend-mnszl                   Running   gpu-lab-worker5
    llm-inference-0-prefill-0-prefill-leader-6mvm5   Running   gpu-lab-worker7
    llm-inference-0-prefill-0-prefill-worker-hctmv   Running   gpu-lab-worker5
    llm-inference-0-prefill-0-prefill-worker-vcrqp   Running   gpu-lab-worker8

--- Placement (prefill-leader + prefill-worker land in ONE block) ---
    POD                                                  BLOCK    RACK     NODE
    llm-inference-0-decode-48w7w                         block-1  rack-1   gpu-lab-worker
    llm-inference-0-decode-fxppf                         block-1  rack-1   gpu-lab-worker2
    llm-inference-0-frontend-mnszl                       block-2  rack-3   gpu-lab-worker5
    llm-inference-0-prefill-0-prefill-worker-hctmv       block-2  rack-3   gpu-lab-worker5
    llm-inference-0-prefill-0-prefill-leader-6mvm5       block-2  rack-4   gpu-lab-worker7
    llm-inference-0-prefill-0-prefill-worker-vcrqp       block-2  rack-4   gpu-lab-worker8
```

**What it shows:** Unlike the `grove-podcliques` baseline, KAI turns Grove's
PodGang into a KAI `PodGroup` and gang-schedules all 6 pods to Running together.
The topology constraint on the prefill scaling group takes effect: the 3-pod
prefill gang (leader + 2 workers) is packed into a **single block** (`block-2`) —
`required=block` — and `preferred=rack` co-locates two of them on `rack-4`,
spilling the third to `rack-3` in the same block (a rack holds only 2 nodes). The
Grove `PodGang` phase still reads `Pending` because the external backend doesn't
advance it — the running pods and the KAI PodGroup are the real success signals.
