#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../lib/install-deps-common.sh"

require_pkg_manager

log "Updating package repositories"
update_repos

log "Installing base packages"
install_packages

