# Talos: 1 control-plane + 2 workers

## A note before you build this

A single control-plane node has no etcd quorum to fall back on. If that
VM dies or its disk fails, the API server, scheduler, and etcd all go
down with it — running pods on the 2 workers keep serving traffic, but
nothing can be scheduled, healed, or changed until the control-plane node
comes back or is rebuilt from etcd backups. Take etcd snapshots on a
schedule and keep them off that box:

```bash
talosctl -n $CP_IP etcd snapshot db.snapshot
```

## System extensions (worker nodes only)

Longhorn needs `iscsiadm` and `nsenter` on every node it schedules onto.
Talos's base image ships neither — build a custom installer image via
the Talos Image Factory:

```bash
curl -X POST https://factory.talos.dev/schematics \
  -H "Content-Type: application/json" \
  -d '{
    "customization": {
      "systemExtensions": {
        "officialExtensions": [
          "siderolabs/iscsi-tools",
          "siderolabs/util-linux-tools"
        ]
      }
    }
  }'
# -> returns {"id": "<schematic-id>"}
```

```bash
export TALOS_VERSION=v1.9.0   # check https://github.com/siderolabs/talos/releases for current
export SCHEMATIC_ID=<schematic-id-from-above>
export WORKER_INSTALL_IMAGE=factory.talos.dev/installer/$SCHEMATIC_ID:$TALOS_VERSION
```

## Generate config

```bash
export CLUSTER_NAME=observability-cluster
export CP_IP=192.168.1.11
export W1_IP=192.168.1.21
export W2_IP=192.168.1.22
export ENDPOINT=https://$CP_IP:6443

talosctl gen config $CLUSTER_NAME $ENDPOINT --output-dir _out
```

Worker patch — save as `_out/worker-longhorn-patch.yaml`:

```yaml
machine:
  install:
    image: factory.talos.dev/installer/<schematic-id>:v1.9.0   # $WORKER_INSTALL_IMAGE
  kubelet:
    extraMounts:
      - destination: /var/lib/longhorn
        type: bind
        source: /var/lib/longhorn
        options:
          - bind
          - rshared
          - rw
  sysctls:
    vm.max_map_count: "262144"
```

Apply configs — control-plane gets the plain `controlplane.yaml` (no
patch needed: Talos taints control-plane nodes `NoSchedule` by default,
which is exactly what we want with dedicated workers); workers get
`worker.yaml` plus the Longhorn patch:

```bash
talosctl apply-config --insecure -n $CP_IP --file _out/controlplane.yaml

for ip in $W1_IP $W2_IP; do
  talosctl apply-config --insecure \
    -n $ip \
    --file _out/worker.yaml \
    --config-patch @_out/worker-longhorn-patch.yaml
done
```

Bootstrap etcd (once, against the control-plane node) and fetch config:

```bash
export TALOSCONFIG=_out/talosconfig
talosctl config endpoint $CP_IP
talosctl config node $CP_IP

talosctl bootstrap -n $CP_IP

talosctl kubeconfig .
export KUBECONFIG=$PWD/kubeconfig

kubectl get nodes -o wide
# expect: 1 node with role control-plane, 2 with role <none>/worker, all Ready
```

Keep the `kubeconfig` this produced — you'll merge it with the
workstation VM's own (kubeadm) kubeconfig in the next step so ArgoCD can
be pointed at this cluster as a remote deployment target.

Next: `../workstation/README.md`.
