#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../lib/install-deps-common.sh"

require_pkg_manager

if install_argocd_cli; then
  log "Argo CD CLI installation step finished"
else
  warn "Skipping Argo CD CLI installation"
fi

