# observability-gitops

Grafana + Prometheus + Loki + Tempo on a Talos cluster (1 control-plane +
2 workers), deployed and kept in sync by ArgoCD running on a **separate**
workstation VM — not on Talos itself. That VM hosts ArgoCD on its own
single-node kubeadm cluster, manages Talos as a remote deployment
target, and doubles as the box you run `talosctl`/`kubectl`/`helm` from.

Deliberately minimal beyond that: just storage (Longhorn) and the
observability stack. No cert-manager, no TLS, no Sealed Secrets. On
Talos: exactly two namespaces, `longhorn-system` and `observability` —
`argocd` lives on the workstation's own cluster instead, so it doesn't
count against that.

## Topology

```
┌───────────────────────┐     ┌───────────────────────────────────┐
│  Workstation VM          │     │  Talos cluster                    │
│  local kubeadm cluster   │────▶│  1 control-plane + 2 workers      │
│  hosts ArgoCD             │     │  namespaces: longhorn-system,     │
│  + talosctl/kubectl/helm  │     │  observability                    │
└───────────────────────┘     └───────────────────────────────────┘
      registered as a remote cluster via `argocd cluster add`
```

## Layout

```
talos/                           talosctl commands: 1 CP + 2 workers, Longhorn extensions
workstation/                     kubeadm + ArgoCD + tool install; registering Talos as a remote target
argocd/
  project-observability.yaml     AppProject — scopes what this setup can touch, on both clusters
  root-app.yaml                  app-of-apps root; lives on the workstation's kubeadm cluster
  apps/
    00-longhorn.yaml             replicated block storage — deployed onto Talos
    10-observability-stack.yaml  the stack itself — deployed onto Talos
charts/observability-stack/      umbrella Helm chart — Grafana/Prometheus/Loki/Tempo toggles
docs/vm-sizing.md                VM specs worked out from retention requirements
```

The distinction that matters throughout `argocd/`: every `Application`
and the `AppProject` are Kubernetes resources that live on the
workstation's kubeadm cluster (since that's where ArgoCD runs and
watches for them), but each Application's `destination:` says where its
rendered resources actually get deployed — the Talos cluster, referenced
by the name it's registered under (`observability-cluster`), not
`https://kubernetes.default.svc` (which would mean "the same cluster
this Application resource lives on," i.e. the workstation, not Talos).

## Order of operations

1. **`talos/README.md`** — bring up the 3 Talos VMs (1 CP, 2 workers),
   with the Longhorn system extensions baked into the worker install
   image. Run this from the workstation VM. Keep the kubeconfig it
   produces.
2. **`workstation/README.md`** — install `talosctl`/`kubectl`/`helm`/
   `git`, stand up a local kubeadm cluster, install ArgoCD onto it,
   then register the Talos cluster as a remote target
   (`argocd cluster add --name observability-cluster`).
3. Push this repo to your own GitHub repo. Then, everywhere you see
   `vonbolfos/motstack` — `argocd/project-observability.yaml`,
   `argocd/root-app.yaml`, `argocd/apps/10-observability-stack.yaml` —
   replace it with your actual org/user. If you named the registered
   Talos cluster something other than `observability-cluster`, update
   that too, in `argocd/project-observability.yaml` and both files
   under `argocd/apps/`.
4. `kubectl apply -f argocd/project-observability.yaml`
   `kubectl apply -f argocd/root-app.yaml`
   (against the workstation/kubeadm context) — the last manual steps.
   From here, ArgoCD brings up Longhorn, then the observability stack,
   both on Talos, and keeps reconciling against Git.
5. Toggle stack components in `charts/observability-stack/values.yaml`,
   commit, push. `selfHeal: true` picks it up automatically.

## Accessing Grafana

Grafana runs on the Talos cluster, not the workstation's local cluster —
make sure your `kubectl` context is the Talos one before this:

```
kubectl config use-context <talos-context-name>
kubectl -n observability port-forward svc/grafana 3000:80
```

Log in at http://localhost:3000 with `grafana.adminUser` /
`grafana.adminPassword` from `charts/observability-stack/values.yaml`.

## What's deliberately not here

- **cert-manager / TLS.** Nothing is exposed outside the cluster, so
  there's nothing to put a certificate on.
- **Sealed Secrets.** `grafana.adminPassword` is plain text in
  `values.yaml` (see the caveat comment right above it). Fine for a
  setup nobody but you can reach; the first thing to fix if this repo
  or cluster access gets shared more widely.
- **Prometheus HA / Mimir.** Single Prometheus replica, 30d local
  retention, Longhorn-backed storage.
- **HA for the workstation's own kubeadm cluster.** It's one VM; if
  it's down, Grafana/Prometheus/Loki/Tempo on Talos keep running
  exactly as they were — you just can't sync changes from Git until
  it's back. That's the trade this topology makes on purpose (see
  `workstation/README.md`'s opening note on why ArgoCD is off-cluster
  at all), not an oversight to fix later.
# motstack
