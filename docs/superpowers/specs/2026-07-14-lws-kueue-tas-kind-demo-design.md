# LeaderWorkerSet + Kueue + Topology-Aware Scheduling on kind — Design

Date: 2026-07-14
Status: Approved (design), pending implementation plan

## Goal

A self-contained, reproducible **demo lab** that shows how **LeaderWorkerSet (LWS)**,
**Kueue**, and **Topology-Aware Scheduling (TAS)** fit together on a local **kind**
cluster. The emphasis is the **end-to-end integration wiring** — queues, quotas,
admission — with TAS as one feature among several.

There is **no real workload**: all pods are placeholder `registry.k8s.io/pause`
containers. The point is to stand up every resource correctly and make the
scheduling/admission behavior observable.

## Non-goals

- No real inference/training load, no GPUs required (a *fake* accelerator is used).
- No preemption scenario (happy-path admission + one quota-blocked group only).
- No cleanup script (documented `kind delete cluster` command instead).
- No multi-cluster / MultiKueue.

## Pinned versions

Declared as variables at the top of `run.sh` for reproducibility:

| Component        | Version               |
| ---------------- | --------------------- |
| Kueue            | `v0.18.3`             |
| LeaderWorkerSet  | `v0.9.0`              |
| kind node image  | `kindest/node:v1.33.1`|
| Cluster name     | `kueue-tas-demo`      |

Notes confirmed from upstream docs (2026-07):

- TAS is **beta and enabled by default since Kueue v0.14**.
- The `leaderworkerset.x-k8s.io/leaderworkerset` integration is **enabled by
  default** (no custom Kueue Configuration needed at v0.18.x). Since Kueue v0.15
  the `pod` integration no longer needs to be explicitly enabled for LWS.

## Cluster topology

1 control-plane + **8 worker nodes**, arranged in a 3-level hierarchy via node
labels:

```
block-1                         block-2
├─ rack-1                       ├─ rack-3
│   ├─ worker-1 (gpu:1)         │   ├─ worker-5 (gpu:1)
│   └─ worker-2 (gpu:1)         │   └─ worker-6 (gpu:1)
└─ rack-2                       └─ rack-4
    ├─ worker-3 (gpu:1)             ├─ worker-7 (gpu:1)
    └─ worker-4 (gpu:1)             └─ worker-8 (gpu:1)
```

Node labels (set in the kind config `labels:` per node):

- `cloud.provider.com/topology-block` — `block-1` / `block-2`
- `cloud.provider.com/topology-rack` — `rack-1` .. `rack-4`
- `kubernetes.io/hostname` — host level (built in)

Capacity: **8 fake GPUs total**, 2 per rack, 4 per block.

## Fake accelerator

kind nodes advertise the *host's* full CPU/memory, so real CPU/memory cannot
give reproducible per-node capacity. Instead, each worker node advertises a
custom extended resource `example.com/gpu: "1"` via a node-status patch:

```
kubectl patch node <node> --subresource=status --type=json \
  -p '[{"op":"add","path":"/status/capacity/example.com~1gpu","value":"1"}]'
```

This is host-independent and mirrors real 1-GPU-per-node scheduling. Each demo
pod requests exactly one `example.com/gpu`, so a group's GPU count equals its pod
count.

## Kueue resources (`manifests/kueue-tas.yaml`)

- **Namespace** `kueue-demo` — where the LWS objects and LocalQueue live.
- **Topology** `default` with ordered levels:
  1. `cloud.provider.com/topology-block`
  2. `cloud.provider.com/topology-rack`
  3. `kubernetes.io/hostname`
- **ResourceFlavor** `gpu-flavor` with `spec.topologyName: default`. Setting
  `topologyName` is what enables TAS for workloads using this flavor.
- **ClusterQueue** `tas-cluster-queue`:
  - `resourceGroups` covering `cpu` and `example.com/gpu`, both mapped to
    `gpu-flavor`.
  - `nominalQuota` for `example.com/gpu: 8` (and a generous `cpu` quota).
- **LocalQueue** `tas-local-queue` in namespace `kueue-demo`, pointing at
  `tas-cluster-queue`.

## Workloads

All containers are `registry.k8s.io/pause:3.10`. Each pod requests
`example.com/gpu: "1"` plus a tiny `cpu` request.

### Admitted groups (`manifests/lws-groups.yaml`)

One `LeaderWorkerSet` named `lws-groups`:

- `metadata.labels.kueue.x-k8s.io/queue-name: tas-local-queue`
- `spec.replicas: 2`
- `spec.leaderWorkerTemplate.size: 4` (1 leader + 3 workers)
- On **both** `leaderTemplate` and `workerTemplate` `metadata.annotations`:
  - `kueue.x-k8s.io/podset-preferred-topology: cloud.provider.com/topology-rack`
  - `kueue.x-k8s.io/podset-group-name: lws-group`

Behavior: each group needs 4 GPUs. A rack holds only 2, so TAS cannot fit a group
in a single rack; it **falls back one level up to the block** (4 GPUs) and
co-locates the whole group within one block. Group 1 → `block-1`, group 2 →
`block-2`. Two groups consume all 8 GPUs.

### Overflow group (`manifests/lws-overflow.yaml`)

A second `LeaderWorkerSet` named `lws-overflow`, `replicas: 1`, `size: 4`, same
queue and annotations. Submitted after the first two groups are admitted, it
needs 4 more GPUs but none are free and the ClusterQueue quota (8) is exhausted,
so its Workload stays **Pending / not admitted** — demonstrating quota +
admission gating.

## Delivery: `run.sh`

A single script; pinned versions in variables at the top; every step prints a
clear banner describing what it is doing. Steps:

1. **Preflight** — verify `docker`, `kind`, `kubectl` exist and docker is running.
2. **Create cluster** — `kind create cluster` with `kind/kind-cluster.yaml`
   (1 control-plane + 8 labeled workers, pinned node image).
3. **Advertise fake GPUs** — patch `example.com/gpu: 1` onto each worker's status.
4. **Install LWS** — apply the pinned LWS release manifest; wait for its
   controller Deployment to be ready.
5. **Install Kueue** — apply the pinned Kueue release manifest; wait for the
   `kueue-controller-manager` Deployment to be ready.
6. **Apply Kueue TAS resources** — `manifests/kueue-tas.yaml`.
7. **Apply admitted groups** — `manifests/lws-groups.yaml`; wait until both
   Workloads are Admitted and pods are Running.
8. **Apply overflow group** — `manifests/lws-overflow.yaml`; show its Workload is
   not admitted.
9. **Rich inspection** (inline) — print:
   - Workloads with admission status (Admitted vs Pending).
   - Every pod with its node and the node's `block`/`rack` labels, grouped so
     co-location per block is visible.
   - ClusterQueue quota usage for `example.com/gpu`.

Idempotency: creating a cluster that already exists should be detected and the
script should proceed (or instruct re-run after delete). Waits use
`kubectl wait` with sensible timeouts.

## File layout

```
run.sh
README.md                     # walkthrough + cleanup note (kind delete cluster --name kueue-tas-demo)
kind/kind-cluster.yaml
manifests/kueue-tas.yaml      # Namespace, Topology, ResourceFlavor, ClusterQueue, LocalQueue
manifests/lws-groups.yaml     # 2 admitted groups
manifests/lws-overflow.yaml   # 1 quota-blocked group
docs/superpowers/specs/2026-07-14-lws-kueue-tas-kind-demo-design.md
```

## Success criteria

- `./run.sh` on a clean machine (docker + kind + kubectl installed) brings up the
  cluster and installs everything without manual steps.
- Both `lws-groups` Workloads become **Admitted**; all 8 pods are **Running**.
- Each group's 4 pods are confined to a **single block** (spanning the two racks
  within that block), and the two groups occupy **different blocks**.
- The `lws-overflow` Workload is **not admitted** (Pending) due to exhausted
  `example.com/gpu` quota/capacity.
- The inspection output makes all of the above visible at a glance.
- Cleanup is a single documented command.

## Risks / open considerations

- **Node count**: 9 kind node containers is moderately heavy but fine on a typical
  dev laptop. If too heavy, the topology could shrink (fewer nodes) at the cost of
  the tidy 2-block symmetry.
- **kind node image tag**: `v1.33.1` must be compatible with the installed kind
  version; README notes how to override `KIND_NODE_IMAGE`.
- **Extended-resource patch** requires `kubectl` ≥ 1.24 (`--subresource=status`).
- **Preferred vs required topology**: `preferred` is used so the rack→block
  fallback is demonstrated. Switching to `required` at rack level would leave
  groups Pending (rack too small) — intentionally avoided.
