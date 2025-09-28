#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIB_DIR="$SCRIPT_DIR/lib"
STEPS_DIR="$SCRIPT_DIR/install-dependencies.d"

source "$LIB_DIR/install-deps-common.sh"

run_step() {
  local step_path="$1" state_dir="$2"
  local step_name
  step_name="$(basename "$step_path")"
  local marker="$state_dir/${step_name}.ok"

  if [[ -f "$marker" ]]; then
    log "Skipping step ${step_name} (already completed)"
    return 0
  fi

  log "Running step ${step_name}"
  if bash "$step_path"; then
    touch "$marker"
    log "Step ${step_name} completed"
  else
    err "Step ${step_name} failed"
    return 1
  fi
}

main() {
  ensure_root "$@"
  detect_pkg_manager
  export PKG_MANAGER
  log "Using package manager: $PKG_MANAGER"

  local state_dir
  state_dir="$(init_state_dir)"

  if [[ ! -d "$STEPS_DIR" ]]; then
    err "Steps directory '$STEPS_DIR' not found"
    exit 1
  fi

  shopt -s nullglob
  local steps=("$STEPS_DIR"/*.sh)
  shopt -u nullglob

  if [[ ${#steps[@]} -eq 0 ]]; then
    err "No dependency installation steps found in '$STEPS_DIR'"
    exit 1
  fi

  for step in "${steps[@]}"; do
    run_step "$step" "$state_dir"
  done

  log "All dependencies installed."
}

main "$@"

