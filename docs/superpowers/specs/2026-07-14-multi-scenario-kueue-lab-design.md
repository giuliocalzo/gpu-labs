# Multi-scenario Kueue demo lab — Design

## Goal

Turn the single TAS demo into a lab where several Kueue features can be shown on
**one shared kind cluster**, selected via a small CLI, with minimal duplication.

Scenarios: `tas`, `fair-sharing`, `workload-priority`, `preemption`, and a
documented `dra` stub.

## Architecture

- **One shared cluster** (`cluster/kind-cluster.yaml`): 1 control-plane + 8
  workers, block/rack topology labels, common `nvidia.com/*` labels. Each worker
  is patched to advertise `nvidia.com/gpu: 8` (64 total).
- **Base install** (idempotent): LWS + Kueue (with `fairSharing` enabled at the
  controller level) + shared `base/flavors.yaml` (Topology + `tas-gpu-flavor` +
  `gpu-flavor`).
- **Scenarios** are self-contained folders providing hook functions.

## CLI (`demo.sh`)

- `demo.sh <scenario>` — `install_base` then source the scenario and run
  `apply` + `inspect`.
- `demo.sh list` — enumerate scenarios via their `describe`.
- `demo.sh clean <scenario>` — run the scenario's `cleanup`.
- `demo.sh down` — delete the cluster.
- `FORCE_RECREATE=1` — rebuild the cluster first.

## Scenario contract

Each `scenarios/<name>/scenario.sh` sources `lib/common.sh` and defines:

- `describe` — one-line summary (used by `list`).
- `apply` — create the scenario's Kueue objects + workloads.
- `inspect` — print the interesting state.
- `cleanup` (optional) — remove the scenario's resources.

Scenario-specific YAML lives in `scenarios/<name>/manifests/`.

## Shared library (`lib/common.sh`)

- Context-pinned `kubectl_ctx` / `helm_ctx`.
- `ensure_cluster`, `patch_fake_gpus`, `install_lws`, `install_kueue`
  (+ `enable_fair_sharing`), `install_base`.
- `gpu_job` — render a suspended `batch/v1` Job (one pause pod) requesting N
  GPUs, optionally tagged with a `WorkloadPriorityClass`.
- Inspectors: `inspect_workloads`, `inspect_pod_topology`,
  `inspect_clusterqueue_usage`, `inspect_pending_pods`, `show_workload_reason`,
  `count_admitted`.
- Guarded so re-sourcing (by demo.sh then scenario.sh) is a no-op.

## Isolation model

- Each scenario uses its own namespace(s), ClusterQueue(s), LocalQueue(s) and
  (where needed) uniquely-named `WorkloadPriorityClass` objects (`wp-*`, `pe-*`).
- All scenarios draw from the same 64 fake GPUs, so `clean` one before running
  another for a clean slate.

## Quotas per scenario

- `tas`: one CQ, `nvidia.com/gpu` = 64.
- `fair-sharing`: cohort `teams`, two CQs of 32 each, `reclaimWithinCohort: Any`.
- `workload-priority`: one CQ = 32 (fits 4 of 8 jobs), no preemption.
- `preemption`: one CQ = 32, `withinClusterQueue: LowerPriority`.

## Decisions

- `fairSharing` enabled globally in the Kueue config (harmless to other
  scenarios; only active where CQs opt in via cohort + preemption settings).
- DRA left as a stub: it needs cluster-creation feature gates + an external
  driver, which would change the baseline for every other scenario.
