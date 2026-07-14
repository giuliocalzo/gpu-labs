#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
SCENARIOS_DIR="$SCRIPT_DIR/scenarios"

_scenario_names() {
  local d
  for d in "$SCENARIOS_DIR"/*/; do
    [ -f "${d}scenario.sh" ] && basename "$d"
  done
}

_list_scenarios() {
  local name
  for name in $(_scenario_names); do
    # source in a subshell so describe() from one scenario can't leak into another
    printf "  %-20s %s\n" "$name" \
      "$( ( source "$SCENARIOS_DIR/$name/scenario.sh"; describe 2>/dev/null || true ) )"
  done
}

usage() {
  cat <<EOF
Kueue demo lab - multiple scenarios on one shared kind cluster.

Usage:
  ./demo.sh <scenario>         Ensure cluster + base, then run & inspect a scenario
  ./demo.sh list               List available scenarios
  ./demo.sh clean <scenario>   Remove a scenario's resources (keep the cluster)
  ./demo.sh down               Delete the kind cluster
  ./demo.sh help               Show this help

Environment:
  FORCE_RECREATE=1             Delete & rebuild the cluster before running

Scenarios:
$(_list_scenarios)
EOF
}

run_scenario() {
  local name="$1" dir="$SCENARIOS_DIR/$1"
  [ -f "$dir/scenario.sh" ] || { echo "Unknown scenario: '$name'"; echo; usage; exit 1; }
  # Drop any hook definitions left over so an undefined hook in this scenario
  # doesn't accidentally run a previous scenario's function.
  unset -f pre_run post_run 2>/dev/null || true
  install_base
  # shellcheck disable=SC1090
  source "$dir/scenario.sh"
  # Optional pre_run hook: install prerequisites the scenario needs (e.g. a driver).
  if declare -F pre_run >/dev/null; then
    step "Pre-run setup: $name"
    pre_run
  fi
  step "Running scenario: $name"
  apply
  echo
  step "Inspection: $name"
  inspect
  # Optional post_run hook: tear down anything pre_run installed but the demo
  # doesn't need to leave behind.
  if declare -F post_run >/dev/null; then
    echo
    step "Post-run teardown: $name"
    post_run
  fi
  echo
  step "Scenario '$name' complete."
}

clean_scenario() {
  local name="$1" dir="$SCENARIOS_DIR/$1"
  [ -f "$dir/scenario.sh" ] || die "unknown scenario: '$name'"
  # shellcheck disable=SC1090
  source "$dir/scenario.sh"
  if declare -F cleanup >/dev/null; then
    step "Cleaning scenario: $name"
    cleanup
    info "done."
  else
    warn "scenario '$name' has no cleanup()"
  fi
}

cmd="${1:-help}"
case "$cmd" in
  help|-h|--help) usage ;;
  list)           _list_scenarios ;;
  down)           step "Deleting kind cluster '$CLUSTER_NAME'"; kind delete cluster --name "$CLUSTER_NAME" ;;
  clean)          shift; [ -n "${1:-}" ] || die "usage: ./demo.sh clean <scenario>"; clean_scenario "$1" ;;
  *)              run_scenario "$cmd" ;;
esac
