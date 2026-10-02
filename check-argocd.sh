#!/usr/bin/env bash
#
# workstation/check-argocd.sh
#
# Read-only health check for ArgoCD and both clusters. Changes nothing —
# safe to run anytime, especially after a reboot or when the ArgoCD GUI
# looks off, before diving into manual kubectl diagnosis. Checks the
# specific things that actually broke this setup in practice: the
# workstation node's own kubelet/swap state, ArgoCD's pods, Application
# sync/health, whether the AppProject exists at all, and whether the
# Talos cluster is still reachable as a registered remote target.
#
# -----------------------------------------------------------------------------
# Configuration — override as environment variables if your context
# names differ from the defaults used throughout this repo:
# -----------------------------------------------------------------------------
KUBEADM_CONTEXT="${KUBEADM_CONTEXT:-kubernetes-admin@kubernetes}"
TALOS_CONTEXT="${TALOS_CONTEXT:-admin@observability-cluster}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
APPPROJECT_NAME="${APPPROJECT_NAME:-observability}"

# Deliberately no `set -e` — this script's whole job is to keep checking
# everything and report a full summary, not stop at the first failure.
set -uo pipefail

PASS=0
WARN=0
FAIL=0

ok()      { printf '  \033[1;32m[OK]\033[0m   %s\n' "$*"; PASS=$((PASS+1)); }
warn()    { printf '  \033[1;33m[WARN]\033[0m %s\n' "$*"; WARN=$((WARN+1)); }
fail()    { printf '  \033[1;31m[FAIL]\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
section() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# -----------------------------------------------------------------------------
section "1. Workstation VM node health (kubeadm cluster)"
# -----------------------------------------------------------------------------
if sudo systemctl is-active --quiet kubelet 2>/dev/null; then
  ok "kubelet is active"
else
  fail "kubelet is NOT active — check: sudo systemctl status kubelet"
fi

SWAP_ON="$(swapon --show 2>/dev/null || true)"
if [[ -z "$SWAP_ON" ]]; then
  ok "swap is off"
else
  fail "swap is ON — kubelet refuses to run at all with swap enabled. Fix: sudo swapoff -a && sudo systemctl restart kubelet (then check /etc/fstab has the swap line actually commented out, tabs not spaces)"
fi

if kubectl --context="$KUBEADM_CONTEXT" get nodes >/dev/null 2>&1; then
  NODE_STATUS="$(kubectl --context="$KUBEADM_CONTEXT" get nodes --no-headers 2>/dev/null | awk '{print $2}')"
  if [[ "$NODE_STATUS" == "Ready" ]]; then
    ok "kubeadm node is Ready"
  else
    fail "kubeadm node status: $NODE_STATUS (expected Ready)"
  fi
else
  fail "Cannot reach the kubeadm cluster API at all (context: $KUBEADM_CONTEXT) — check kubelet above first"
fi

# -----------------------------------------------------------------------------
section "2. ArgoCD pods"
# -----------------------------------------------------------------------------
if kubectl --context="$KUBEADM_CONTEXT" -n "$ARGOCD_NAMESPACE" get pods >/dev/null 2>&1; then
  POD_LINES="$(kubectl --context="$KUBEADM_CONTEXT" -n "$ARGOCD_NAMESPACE" get pods --no-headers 2>/dev/null)"
  if [[ -z "$POD_LINES" ]]; then
    fail "No pods at all in the $ARGOCD_NAMESPACE namespace — ArgoCD may not be installed, or the namespace is empty for some other reason"
  else
    while IFS= read -r line; do
      name="$(awk '{print $1}' <<< "$line")"
      ready="$(awk '{print $2}' <<< "$line")"
      status="$(awk '{print $3}' <<< "$line")"
      restarts="$(awk '{print $4}' <<< "$line")"
      ready_num="${ready%%/*}"
      ready_den="${ready##*/}"
      if [[ "$status" == "Running" && "$ready_num" == "$ready_den" ]]; then
        ok "$name — Running, $ready ready"
      else
        fail "$name — $status, $ready ready (restarts: $restarts)"
      fi
    done <<< "$POD_LINES"
  fi
else
  fail "Cannot list pods in the $ARGOCD_NAMESPACE namespace — is the kubeadm cluster reachable? (see section 1)"
fi

# -----------------------------------------------------------------------------
section "3. AppProject sanity"
# -----------------------------------------------------------------------------
if kubectl --context="$KUBEADM_CONTEXT" -n "$ARGOCD_NAMESPACE" get appproject "$APPPROJECT_NAME" >/dev/null 2>&1; then
  ok "AppProject '$APPPROJECT_NAME' exists"
else
  fail "AppProject '$APPPROJECT_NAME' does NOT exist — every Application referencing it will show Unknown/Unknown until this is reapplied: kubectl --context=$KUBEADM_CONTEXT apply -f argocd/project-observability.yaml"
fi

# -----------------------------------------------------------------------------
section "4. ArgoCD Applications (sync + health)"
# -----------------------------------------------------------------------------
if kubectl --context="$KUBEADM_CONTEXT" -n "$ARGOCD_NAMESPACE" get applications >/dev/null 2>&1; then
  APP_LINES="$(kubectl --context="$KUBEADM_CONTEXT" -n "$ARGOCD_NAMESPACE" get applications --no-headers 2>/dev/null)"
  if [[ -z "$APP_LINES" ]]; then
    warn "No Applications found yet — nothing to check (expected before root-app.yaml has been applied)"
  else
    while IFS= read -r line; do
      name="$(awk '{print $1}' <<< "$line")"
      sync="$(awk '{print $2}' <<< "$line")"
      health="$(awk '{print $3}' <<< "$line")"
      if [[ "$sync" == "Synced" && "$health" == "Healthy" ]]; then
        ok "$name — Synced / Healthy"
      elif [[ "$sync" == "Unknown" || "$health" == "Unknown" ]]; then
        fail "$name — Unknown status (see AppProject check above — this is almost always the cause)"
      else
        warn "$name — $sync / $health"
      fi
    done <<< "$APP_LINES"
  fi
else
  warn "Cannot list Applications (ArgoCD CRDs missing, or cluster unreachable — see section 1/2)"
fi

# -----------------------------------------------------------------------------
section "5. Talos cluster reachability (registered remote target)"
# -----------------------------------------------------------------------------
if kubectl --context="$TALOS_CONTEXT" get nodes >/dev/null 2>&1; then
  NOT_READY="$(kubectl --context="$TALOS_CONTEXT" get nodes --no-headers 2>/dev/null | awk '$2 != "Ready" {print $1}')"
  if [[ -z "$NOT_READY" ]]; then
    ok "All Talos nodes Ready"
  else
    fail "Talos node(s) not Ready: $NOT_READY"
  fi
else
  fail "Cannot reach the Talos cluster at all (context: $TALOS_CONTEXT) — if ArgoCD's Applications are also failing, this is likely why"
fi

# -----------------------------------------------------------------------------
section "6. External access (port-forward systemd service)"
# -----------------------------------------------------------------------------
if systemctl is-active --quiet argocd-port-forward 2>/dev/null; then
  ok "argocd-port-forward service is active"
else
  warn "argocd-port-forward is not active — external GUI access (https://<vm-ip>:8080) won't work, but ArgoCD itself may be fine locally. Fix: sudo systemctl restart argocd-port-forward"
fi

# -----------------------------------------------------------------------------
section "Summary"
# -----------------------------------------------------------------------------
echo
echo "  Passed: $PASS   Warnings: $WARN   Failed: $FAIL"
if [[ $FAIL -gt 0 ]]; then
  echo
  echo "  Something's actually broken. Start with the FIRST [FAIL] above,"
  echo "  top to bottom — later failures are very often just consequences"
  echo "  of an earlier one, not separate problems (this was true almost"
  echo "  every time today)."
  exit 1
else
  [[ $WARN -eq 0 ]] && echo "  Everything looks healthy."
  exit 0
fi
