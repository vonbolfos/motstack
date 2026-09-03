# The workstation VM

One VM, two jobs: it hosts ArgoCD (on its own single-node **kubeadm**
cluster), and it's the box you run `talosctl`/`kubectl`/`helm`/`argocd`
from to administer both that local cluster and the remote Talos cluster.
ArgoCD's controllers are pods — they need *some* Kubernetes API to run
on — but that API is this VM's own kubeadm cluster, not Talos. ArgoCD
then talks *out* to the Talos cluster's API as a remote deployment
target.

Why kubeadm instead of k3s/k0s/microk8s: vanilla upstream Kubernetes,
managed with nothing but plain `kubectl` once it's up — no
distro-specific CLI, no snap confinement, no swapped-out datastore to
account for. The trade-off is that kubeadm gives you none of the
batteries k3s includes (container runtime, CNI, single binary, systemd
unit) — those are separate steps below.

Why ArgoCD off Talos at all: it keeps the GitOps control plane's
availability independent of the cluster it's managing. If something's
badly wrong with Talos, you still have a working ArgoCD — and a working
`talosctl` right there on the same box — to diagnose and fix it from.

Sizing this modestly: 2 vCPU / 4 GiB RAM / 40–50 GB disk covers a
single-node control plane plus ArgoCD's default component requests at
this scale.

## Install the tools

```bash
# talosctl — bootstraps and administers the Talos nodes
curl -sL https://talos.dev/install | sh

# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -m 755 kubectl /usr/local/bin/kubectl

# helm — not used to install anything by hand (ArgoCD renders charts
# itself), but useful for `helm show values <chart>` when verifying a
# chart version's schema before bumping it in argocd/apps/*.yaml
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# git — to clone/push this repo
sudo apt-get install -y git   # or your distro's equivalent
```

(The `argocd` CLI comes later, after ArgoCD itself is installed below.)

## Install a container runtime (containerd)

```bash
sudo apt-get update
sudo apt-get install -y containerd

sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null

# kubeadm requires the systemd cgroup driver
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

sudo systemctl restart containerd
sudo systemctl enable containerd
```

## Kernel prerequisites

```bash
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab   # keep swap off across reboots

cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system
```

## Install kubeadm, kubelet

```bash
export K8S_VERSION=v1.31   # check https://kubernetes.io/releases/ for current

sudo apt-get install -y apt-transport-https ca-certificates curl gpg

curl -fsSL https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update
sudo apt-get install -y kubelet kubeadm
sudo apt-mark hold kubelet kubeadm
# kubectl is already installed above — no need to pull it again here
```

## Bootstrap the local cluster

```bash
sudo kubeadm init --pod-network-cidr=10.244.0.0/16

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

Install a CNI — Flannel is the simplest match for the
`--pod-network-cidr` above, and this node has no complex networking
needs beyond running ArgoCD's own pods:

```bash
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
```

Single-node cluster, so remove the control-plane taint — without this,
ArgoCD's pods have nowhere to schedule:

```bash
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
kubectl get nodes -o wide   # expect 1 node, Ready
```

## Install ArgoCD

```bash
kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

kubectl -n argocd rollout status deploy/argocd-server --timeout=180s
```

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo

kubectl -n argocd port-forward svc/argocd-server 8080:443
# https://localhost:8080
```

Now install the `argocd` CLI and log in:

```bash
curl -sSL -o argocd-linux-amd64 https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
sudo install -m 555 argocd-linux-amd64 /usr/local/bin/argocd

argocd login localhost:8080 --username admin
```

## Bring up Talos, then register it with ArgoCD

Follow `../talos/README.md` now, from this same VM (that's what
`talosctl` above is for). It produces a `kubeconfig` for the Talos
cluster — merge it in as a second context, alongside the kubeadm
context you're already using:

```bash
export KUBECONFIG=./kubeconfig:$HOME/.kube/config   # ./kubeconfig is Talos's, from talos/README.md
kubectl config view --flatten > ~/.kube/config
kubectl config get-contexts
# expect two: something like "kubernetes-admin@kubernetes" (local/kubeadm)
# and "observability-cluster" (Talos)
```

Register Talos as ArgoCD's deployment target — confirm this VM can
reach the Talos control-plane node's `:6443` first (that reachability
is a hard dependency from here on):

```bash
argocd cluster add <talos-context-name> --name observability-cluster
```

This installs a ServiceAccount + ClusterRoleBinding into the Talos
cluster that ArgoCD uses to deploy — the actual over-the-network link.
The `--name observability-cluster` matters: `argocd/apps/*.yaml`
reference the Talos cluster by this exact name in their `destination:`
block, so if you name it something else here, update those files to
match.

If your GitHub repo is private, register it too (a fine-grained PAT
with read-only access to just this repo is enough):

```bash
argocd repo add https://github.com/<you>/observability-gitops.git \
  --username <github-username> \
  --password <github-personal-access-token>
```

## Bring up everything else

```bash
kubectl config use-context kubernetes-admin@kubernetes   # back to the local/kubeadm context —
                                                           # the Application/AppProject CRDs
                                                           # live where ArgoCD runs, not on Talos
kubectl apply -f argocd/project-observability.yaml
kubectl apply -f argocd/root-app.yaml
```

That's the last manual `kubectl apply`. The root Application recurses
into `argocd/apps/`, which brings up Longhorn and then the observability
stack — both *on the Talos cluster*, via the remote connection just
registered. Watch it land:

```bash
kubectl -n argocd get applications -w
```
