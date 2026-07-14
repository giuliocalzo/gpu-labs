# AGENTS.md

Conventions for working in this repo. Keep changes consistent with these rules.

## What this is

A local **Kubernetes demo lab**: one shared `kind` cluster hosts several
independent scenarios that each showcase a cloud-native feature. Kueue is the
first focus (queueing, quotas, fair sharing, preemption, TAS, DRA), but the lab
is meant to grow to other components (LeaderWorkerSet, DRA drivers, and more) on
the same cluster. No real workloads (pods are `pause`/`agnhost` placeholders) and
no real GPUs (nodes advertise fake `nvidia.com/gpu`). A single `demo.sh` CLI
drives everything.

## Layout

```
demo.sh                   # CLI: run <scenario> | list | clean <scenario> | down
lib/common.sh             # shared helpers: install, job builder, inspectors
cluster/kind-cluster.yaml # 1 control-plane + 8 labelled workers (cluster name: gpu-lab)
base/
  flavors.yaml            # shared Topology + ResourceFlavors
  kueue-values.yaml       # Kueue Helm values (fairSharing + DRA integration)
scenarios/<name>/
  scenario.sh             # hook functions (see contract below)
  manifests/*.yaml        # scenario-specific Kueue objects & workloads
  README.md               # what THIS scenario tests, how, what to look for
```

## Scenario contract

Each `scenarios/<name>/scenario.sh` sources `lib/common.sh` and defines hook
functions. `demo.sh` calls them in this order:

1. `describe` — one line, used by `demo.sh list`. **Required.**
2. `pre_run` — install prerequisites (e.g. a driver). **Optional.**
3. `apply` — create the scenario's Kueue objects + workloads. **Required.**
4. `inspect` — print the interesting state. **Required.**
5. `post_run` — tear down what `pre_run` installed. **Optional.**
6. `cleanup` — remove the scenario's resources (used by `demo.sh clean`).
   **Optional but expected.**

`install_base` (cluster + LWS + Kueue + `base/flavors.yaml`) runs before every
scenario, so hooks can assume the base is present.

## Hard rules

- **Always go through the context wrappers**: `kubectl_ctx` / `helm_ctx` (defined
  in `lib/common.sh`). Never call bare `kubectl`/`helm` — they must target the
  pinned `kind-${CLUSTER_NAME}` context.
- **Install via Helm**, not raw manifests: LWS and Kueue are Helm charts
  (`install_lws` / `install_kueue`). Kueue config (fair sharing, DRA gate,
  integrations) lives in `base/kueue-values.yaml`.
- **Pinned versions** live at the top of `lib/common.sh` (`KUEUE_VERSION`,
  `LWS_VERSION`, `CLUSTER_NAME`) and are **stored without a leading `v`** (the
  Helm `--version` flags use them directly).
- **Fake GPUs**: use the extended resource `nvidia.com/gpu`; nodes are patched to
  `8` each (64 total). Reuse the shared `gpu_job` builder in `lib/common.sh` for
  pause-pod jobs.
- **Scenario isolation**: each scenario uses its own namespace(s), ClusterQueue,
  LocalQueue, and (where needed) uniquely-named `WorkloadPriorityClass` objects.
  All scenarios draw from the same 64 GPUs, so `clean` one before running another.
- **Never hardcode the cluster name/context** inside a scenario; derive from the
  `lib/common.sh` variables.

## scenario.sh style

- Put **named config constants** at the top (namespaces, queue/CQ names, job
  counts, per-job GPU count). No magic numbers in the middle of the logic.
- Reuse the shared helpers in `lib/common.sh` (e.g. `submit_gpu_jobs`, `gpu_job`,
  the `inspect_*` family) instead of re-implementing them per scenario.
- Extract remaining scenario-specific logic into small, clearly named helpers
  (e.g. `_wait_for_admitted`). Prefix internal, single-scenario helpers with `_`.
- Derive log messages from the constants so counts stay in sync.
- Add a short comment only where the *why* is non-obvious (async waits, holds,
  preemption timing). Don't narrate obvious code.
- Keep it POSIX-ish bash under `set -euo pipefail` (inherited from
  `lib/common.sh`); syntax-check with `bash -n scenarios/<name>/scenario.sh`.

## Running & verifying

```bash
./demo.sh list
./demo.sh <scenario>                 # ensure cluster + base, run & inspect
FORCE_RECREATE=1 ./demo.sh <scenario> # rebuild the cluster first
CLUSTER_NAME=<other> ./demo.sh ...    # target a different kind cluster
./demo.sh clean <scenario>
./demo.sh down
```

Changes to `cluster/kind-cluster.yaml` or `base/kueue-values.yaml` only take
effect on a fresh install, so verify those with `FORCE_RECREATE=1`.

## Docs

- Every scenario has a `README.md` (What it tests → How it works → Run → What to
  look for). Update it when you change a scenario.
- `docs/superpowers/` is gitignored (local working notes); don't rely on it.

## Commits

- **Every commit must be DCO signed off**: `git commit -s`.
- Only commit when explicitly asked.
- **Use Conventional Commits** (e.g. `feat:`, `fix:`, `docs:`, `refactor:`,
  `chore:`), optionally scoped (e.g. `feat(kueue-dra): ...`).
- **Only commit a feature once it is complete and validated** - never commit
  something that has not been run and verified to work.
