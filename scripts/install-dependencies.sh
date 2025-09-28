#!/usr/bin/env bash
set -euo pipefail

log() {
  echo "[INFO] $*"
}

err() {
  echo "[ERROR] $*" >&2
}

ensure_root() {
  if [[ $EUID -ne 0 ]]; then
    exec sudo -E bash "$0" "$@"
  fi
}

PKG_MANAGER=""

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
  elif command -v zypper >/dev/null 2>&1; then
    PKG_MANAGER="zypper"
  else
    err "Unsupported package manager. Install dependencies manually."
    exit 1
  fi
}

update_repos() {
  case "$PKG_MANAGER" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      ;;
    dnf)
      dnf makecache --refresh -y
      ;;
    yum)
      yum makecache -y
      ;;
    zypper)
      zypper refresh
      ;;
  esac
}

install_packages() {
  local packages=(curl openssl ca-certificates gnupg tar gzip git jq)
  case "$PKG_MANAGER" in
    apt)
      packages+=(lsb-release apt-transport-https software-properties-common gettext-base)
      ;;
    dnf|yum)
      packages+=(gettext)
      ;;
    zypper)
      packages+=(gettext-tools)
      ;;
  esac

  case "$PKG_MANAGER" in
    apt)
      apt-get install -y "${packages[@]}"
      ;;
    dnf)
      dnf install -y "${packages[@]}"
      ;;
    yum)
      yum install -y "${packages[@]}"
      ;;
    zypper)
      zypper --non-interactive install -y "${packages[@]}"
      ;;
  esac
}

install_kubectl() {
  if command -v kubectl >/dev/null 2>&1; then
    return
  fi

  log "Installing kubectl"

  local version="v1.29"
  case "$PKG_MANAGER" in
    apt)
      install_kubectl_apt "$version"
      ;;
    dnf|yum)
      install_kubectl_yum "$version"
      ;;
    zypper)
      install_kubectl_zypper "$version"
      ;;
  esac
}

install_kubectl_apt() {
  local version="$1"
  curl -fsSLo /usr/share/keyrings/kubernetes-archive-keyring.gpg \
    "https://pkgs.k8s.io/core:/stable:/${version}/deb/Release.key"
  cat <<EOF_LIST >/etc/apt/sources.list.d/kubernetes.list
deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/${version}/deb/ /
EOF_LIST
  apt-get update
  apt-get install -y kubectl
}

install_kubectl_yum() {
  local version="$1"
  cat <<EOF_REPO >/etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/${version}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/${version}/rpm/repodata/repomd.xml.key
EOF_REPO
  if [[ "$PKG_MANAGER" == "dnf" ]]; then
    dnf install -y kubectl
  else
    yum install -y kubectl
  fi
}

install_kubectl_zypper() {
  local version="$1"
  zypper addrepo --refresh \
    "https://pkgs.k8s.io/core:/stable:/${version}/rpm/" kubernetes
  rpm --import "https://pkgs.k8s.io/core:/stable:/${version}/rpm/repodata/repomd.xml.key"
  zypper --non-interactive install -y kubectl
}

install_helm() {
  if command -v helm >/dev/null 2>&1; then
    return
  fi
  log "Installing Helm"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
}

install_argocd_cli() {
  if command -v argocd >/dev/null 2>&1; then
    return
  fi

  local arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64)
      arch="amd64"
      ;;
    arm64|aarch64)
      arch="arm64"
      ;;
    *)
      err "Unsupported architecture for Argo CD CLI: $arch"
      return
      ;;
  esac

  log "Installing Argo CD CLI"

  (
    set -euo pipefail
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' EXIT
    version="$(curl -fsSL https://api.github.com/repos/argoproj/argo-cd/releases/latest | jq -r '.tag_name')"
    curl -fsSL -o "$tmp_dir/argocd" \
      "https://github.com/argoproj/argo-cd/releases/download/${version}/argocd-linux-${arch}"
    install -m 0755 "$tmp_dir/argocd" /usr/local/bin/argocd
  )
}

main() {
  ensure_root "$@"
  detect_pkg_manager
  log "Using package manager: $PKG_MANAGER"
  update_repos
  install_packages
  install_kubectl
  install_helm
  install_argocd_cli || true
  log "All dependencies installed."
}

main "$@"
