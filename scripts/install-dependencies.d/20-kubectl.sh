#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../lib/install-deps-common.sh"

require_pkg_manager

if install_kubectl; then
  log "kubectl installation step finished"
else
  err "Failed to install kubectl"
  exit 1
fi

