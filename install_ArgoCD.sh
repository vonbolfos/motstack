#!/usr/bin/env bash
#
# workstation/install.sh
#
# Installs and configures the workstation VM described in
# workstation/README.md: talosctl/kubectl/helm/git, a local single-node
# kubeadm cluster, and ArgoCD on top of it. Optionally also registers
# the Talos cluster as ArgoCD's remote deployment target and applies
# this repo's AppProject + root Application, if you point it at an
# already-bootstrapped Talos cluster's kubeconfig.
#
# Run as a regular user with sudo access, NOT as root directly — it
# calls `sudo` itself for the specific commands that need it.
#
# Safe to re-run: every step checks whether it's already done before
# doing it again.
#
# -----------------------------------------------------------------------------
# Configuration — override any of these as environment variables, e.g.:
#   K8S_VERSION=v1.32 ./install.sh
# -----------------------------------------------------------------------------
K8S_VERSION="v1.37"                 # https://kubernetes.io/releases/
POD_NETWORK_CIDR="${POD_NETWORK_CIDR:-10.244.0.0/16}"
ARGOCD_CLUSTER_NAME="${ARGOCD_CLUSTER_NAME:-mot}"

# Optional: set these to also register the Talos cluster and bring up
# the GitOps apps. Leave unset to stop after ArgoCD is installed and
# get printed instructions for the remaining manual steps instead.
TALOS_KUBECONFIG="${TALOS_KUBECONFIG:-}"            # path to Talos's kubeconfig, e.g. /home/user/talos/kubeconfig
TALOS_CONTEXT_NAME="${TALOS_CONTEXT_NAME:-}"        # context name inside that kubeconfig
GIT_REPO_URL="https://github.com/vonbolfos/motstack.git"                    # e.g. https://github.com/you/observability-gitops.git
GIT_USERNAME="vonbolfos"                    # only needed if the repo is private
GIT_PAT="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"                              # fine-grained PAT, read-only on this repo

set -euo pipefail

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
log()  { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

[[ "$EUID" -eq 0 ]] && die "Run this as a regular user with sudo access, not as root."
command -v sudo >/dev/null || die "sudo is required."
command -v apt-get >/dev/null || die "This script assumes an apt-based OS (Ubuntu/Debian)."

# -----------------------------------------------------------------------------
# 1. CLI tools: talosctl, kubectl, helm, git
# -----------------------------------------------------------------------------
log "Installing CLI tools"

if ! command -v talosctl >/dev/null; then
  curl -sL https://talos.dev/install | sh
else
  echo "talosctl already installed, skipping"
fi

if ! command -v kubectl >/dev/null; then
  KUBECTL_VERSION="$(curl -L -s https://dl.k8s.io/release/stable.txt)"
  curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
  sudo install -m 755 kubectl /usr/local/bin/kubectl
  rm -f kubectl
else
  echo "kubectl already installed, skipping"
fi

if ! command -v helm >/dev/null; then
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
else
  echo "helm already installed, skipping"
fi

sudo apt-get update -qq
sudo apt-get install -y -qq git apt-transport-https ca-certificates curl gpg >/dev/null

# -----------------------------------------------------------------------------
# 2. containerd
# -----------------------------------------------------------------------------
log "Installing and configuring containerd"

if ! command -v containerd >/dev/null; then
  sudo apt-get install -y -qq containerd >/dev/null
fi

sudo mkdir -p /etc/containerd
if ! grep -q 'SystemdCgroup = true' /etc/containerd/config.toml 2>/dev/null; then
  containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
  sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  sudo systemctl restart containerd
fi
sudo systemctl enable --now containerd >/dev/null

# -----------------------------------------------------------------------------
# 3. Kernel prerequisites
# -----------------------------------------------------------------------------
log "Applying kernel prerequisites (swap off, kernel modules, sysctls)"

sudo swapoff -a
if ! grep -q '^#.*swap' /etc/fstab; then
  sudo sed -i '/ swap / s/^/#/' /etc/fstab
fi

cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf >/dev/null
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf >/dev/null
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system >/dev/null

# -----------------------------------------------------------------------------
# 4. kubeadm + kubelet
# -----------------------------------------------------------------------------
log "Installing kubeadm and kubelet ($K8S_VERSION)"

if ! command -v kubeadm >/dev/null; then
  sudo mkdir -p /etc/apt/keyrings
  sudo rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg   # in case a prior attempt got partway through
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key" \
    | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /" \
    | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

  sudo apt-get update -qq
  sudo apt-get install -y -qq kubelet kubeadm >/dev/null
  sudo apt-mark hold kubelet kubeadm >/dev/null
else
  echo "kubeadm already installed, skipping"
fi

# -----------------------------------------------------------------------------
# 5. Bootstrap the local cluster
# -----------------------------------------------------------------------------
if [[ -f /etc/kubernetes/admin.conf ]]; then
  log "kubeadm cluster already initialized, skipping kubeadm init"
else
  log "Running kubeadm init"
  sudo kubeadm init --pod-network-cidr="$POD_NETWORK_CIDR"
fi

mkdir -p "$HOME/.kube"
if [[ ! -f "$HOME/.kube/config" ]]; then
  sudo cp -f /etc/kubernetes/admin.conf "$HOME/.kube/config"
  sudo chown "$(id -u)":"$(id -g)" "$HOME/.kube/config"
else
  echo "$HOME/.kube/config already exists — leaving it as-is rather than" \
       "overwriting (it may already have the Talos context merged in from a" \
       "previous run of this script)."
fi
export KUBECONFIG="$HOME/.kube/config"

log "Installing Flannel CNI"
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

log "Removing the control-plane taint (single-node cluster — ArgoCD needs somewhere to schedule)"
kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true

log "Waiting for the node to be Ready"
kubectl wait --for=condition=Ready node --all --timeout=180s

# -----------------------------------------------------------------------------
# 6. ArgoCD
# -----------------------------------------------------------------------------
log "Installing ArgoCD"

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

log "Waiting for argocd-server to be ready (can take a few minutes on first install)"
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s

if ! command -v argocd >/dev/null; then
  log "Installing the argocd CLI"
  curl -sSL -o /tmp/argocd-linux-amd64 \
    https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
  sudo install -m 555 /tmp/argocd-linux-amd64 /usr/local/bin/argocd
  rm -f /tmp/argocd-linux-amd64
else
  echo "argocd CLI already installed, skipping"
fi

ADMIN_PW="$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"

# -----------------------------------------------------------------------------
# 7. Log in to ArgoCD via a temporary port-forward
# -----------------------------------------------------------------------------
log "Logging in to ArgoCD"

kubectl -n argocd port-forward svc/argocd-server 8080:443 >/tmp/argocd-port-forward.log 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT

# Poll instead of a blind sleep — port-forward setup time varies.
for i in $(seq 1 30); do
  if curl -sk --max-time 1 https://localhost:8080 >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if [[ -n "$ADMIN_PW" ]]; then
  argocd login localhost:8080 --username admin --password "$ADMIN_PW" --insecure \
    || warn "argocd login failed — the initial admin secret may already be deleted if this is a re-run. Log in manually if needed."
else
  warn "Could not read the initial admin secret (already deleted from a previous run?). Skipping automatic login."
fi

# -----------------------------------------------------------------------------
# 8. Optional: register Talos and bring up the GitOps apps
# -----------------------------------------------------------------------------
if [[ -n "$TALOS_KUBECONFIG" && -n "$TALOS_CONTEXT_NAME" ]]; then
  [[ -f "$TALOS_KUBECONFIG" ]] || die "TALOS_KUBECONFIG=$TALOS_KUBECONFIG not found"

  log "Merging in the Talos kubeconfig and registering it with ArgoCD as '$ARGOCD_CLUSTER_NAME'"
  KUBECONFIG="$TALOS_KUBECONFIG:$HOME/.kube/config" kubectl config view --flatten > /tmp/merged-kubeconfig
  mv /tmp/merged-kubeconfig "$HOME/.kube/config"

  argocd cluster add "$TALOS_CONTEXT_NAME" --name "$ARGOCD_CLUSTER_NAME" --yes

  if [[ -n "$GIT_REPO_URL" && -n "$GIT_USERNAME" && -n "$GIT_PAT" ]]; then
    log "Registering the GitHub repo with ArgoCD"
    argocd repo add "$GIT_REPO_URL" --username "$GIT_USERNAME" --password "$GIT_PAT"
  fi

  PROJECT_FILE="$REPO_ROOT/argocd/project-observability.yaml"
  ROOT_APP_FILE="$REPO_ROOT/argocd/root-app.yaml"
  if grep -q '<your-github-org-or-user>' "$PROJECT_FILE" "$ROOT_APP_FILE" 2>/dev/null; then
    warn "argocd/project-observability.yaml and/or argocd/root-app.yaml still contain the" \
         "<your-github-org-or-user> placeholder — edit those first, then apply them yourself:"
    echo "    kubectl apply -f $PROJECT_FILE"
    echo "    kubectl apply -f $ROOT_APP_FILE"
  else
    log "Applying the AppProject and root Application"
    kubectl config use-context kubernetes-admin@kubernetes
    kubectl apply -f "$PROJECT_FILE"
    kubectl apply -f "$ROOT_APP_FILE"
    echo "Watch it land with: kubectl -n argocd get applications -w"
  fi
else
  echo
  log "Workstation setup done. ArgoCD is installed but not yet pointed at Talos."
  cat <<EOF
EOF
fi

echo
log "ArgoCD initial admin password (change it — this is a one-time bootstrap credential):"
echo "  ${ADMIN_PW:-<already rotated/deleted — see kubectl -n argocd get secret argocd-initial-admin-secret>}"

# -----------------------------------------------------------------------------
# 7b. Persistent external access: systemd port-forward on port 88
# -----------------------------------------------------------------------------
ARGOCD_EXTERNAL_PORT="${ARGOCD_EXTERNAL_PORT:-88}"
SERVICE_USER="$(id -un)"
KUBECTL_BIN="$(command -v kubectl)"

log "Installing systemd service argocd-port-forward (0.0.0.0:${ARGOCD_EXTERNAL_PORT} -> argocd-server:443)"

# Unquoted heredoc on purpose: ${...} expands now, at install time.
sudo tee /etc/systemd/system/argocd-port-forward.service >/dev/null <<UNIT
[Unit]
Description=Persistent kubectl port-forward to ArgoCD (external access)
After=network-online.target kubelet.service
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=${SERVICE_USER}
Environment=KUBECONFIG=${HOME}/.kube/config
# Ports below 1024 are privileged. Grant just this one capability
# instead of running the whole service as root.
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
# --context is explicit on purpose: don't depend on whichever cluster
# happens to be the current-context in the kubeconfig.
ExecStart=${KUBECTL_BIN} --context=kubernetes-admin@kubernetes -n argocd port-forward svc/argocd-server --address 0.0.0.0 ${ARGOCD_EXTERNAL_PORT}:443
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable argocd-port-forward >/dev/null
sudo systemctl restart argocd-port-forward

REACHABLE=false
for i in $(seq 1 20); do
  if curl -sk --max-time 2 "https://localhost:${ARGOCD_EXTERNAL_PORT}" >/dev/null 2>&1; then
    REACHABLE=true
    break
  fi
  sleep 1
done
if [[ "$REACHABLE" == true ]]; then
  echo "ArgoCD is reachable on port ${ARGOCD_EXTERNAL_PORT} (https://<this-vm-ip>:${ARGOCD_EXTERNAL_PORT})"
else
  warn "Port ${ARGOCD_EXTERNAL_PORT} not responding yet — check: sudo journalctl -u argocd-port-forward -n 20 --no-pager"
fi
if command -v ufw >/dev/null && sudo ufw status 2>/dev/null | grep -q "Status: active"; then
  warn "ufw is active — allow the port yourself if needed: sudo ufw allow ${ARGOCD_EXTERNAL_PORT}/tcp"
fi