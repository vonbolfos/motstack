# VM sizing — 30-day metrics + logs retention

Retention size is driven by two numbers only you know: how many
Prometheus series you're actually scraping, and how verbose your
application logs are. Rather than guess, here's the math and three
scenarios — pick whichever is closest to your real workload, or plug
your own numbers into the formulas.

## Metrics (Prometheus)

**Formula:** `series_count × days × (86400 / scrape_interval_seconds) ×
bytes_per_sample × safety_multiplier`

- `bytes_per_sample`: Prometheus's own docs cite ~1–2 bytes/sample for
  compressed chunk data; using 1.5 as a middle estimate.
- `safety_multiplier`: 2x, to cover the inverted index (which isn't
  captured by the raw chunk estimate above), WAL, and headroom during
  compaction (which briefly needs up to 2x space for the blocks being
  merged). This is a floor, not a ceiling — bump it if you're not
  watching disk usage closely.
- Assumes the kube-prometheus-stack default 30s scrape interval.

| Scenario | Active series | Rough source | 30-day disk |
|---|---|---|---|
| Small | ~15,000 | This stack's own components only: node-exporter + kube-state-metrics + cAdvisor for 3 nodes, ~40–60 pods, no real application workload yet | ~4 GB → provision **20Gi** |
| Medium | ~50,000 | Small + a handful of actual application services with normal instrumentation (RED metrics, standard client libraries) | ~12 GB → provision **50Gi** |
| Large | ~150,000 | Medium + several services with high-cardinality labels (per-user, per-endpoint, per-tenant labels — the usual way cardinality gets away from people) | ~37 GB → provision **100Gi** |

Check where you actually land: `sum(prometheus_tsdb_head_series)` in
Grafana against the running Prometheus, after a day or two of real
traffic. Cardinality tends to only grow over a cluster's life, so I'd
round up to the next tier rather than down.

## Logs (Loki)

**Formula:** `raw_GB_ingested_per_day × days / compression_ratio ×
safety_multiplier`

- `compression_ratio`: ~10x is typical for structured/JSON logs with
  Loki's default compression — conservative; plain-text logs sometimes
  compress even better.
- `safety_multiplier`: 2x, same rationale as above (Loki's own index +
  headroom).
- **Loki's default retention is unlimited** — nothing gets deleted
  unless you explicitly configure it. `values.yaml` didn't set this
  before; it does now (see below). Worth confirming this line item
  specifically, since silently unlimited retention is the easiest way
  to fill a disk without noticing.

| Scenario | Raw log volume | Rough source | 30-day disk |
|---|---|---|---|
| Small | ~300 MB/day | Cluster + addon logs only (kubelet, coredns, the stack's own components), minimal application logging | ~1.8 GB → provision **20Gi** |
| Medium | ~1.5 GB/day | Small + a handful of app services logging at normal (info-level) verbosity | ~9 GB → provision **40Gi** |
| Large | ~5 GB/day | Medium + debug-level logging somewhere, or a genuinely high-traffic service | ~30 GB → provision **100Gi** |

Same advice: check `sum(rate({job=~".+"}[1d]))` bytes ingested (or the
Loki ingester's own metrics) after real traffic, and size to what you
actually see, not the estimate.

## What's in `values.yaml` right now

Set to **Medium** on both — a reasonable default for "the stack plus
some real application workload," but genuinely a guess without knowing
what you're running. Adjust `kube-prometheus-stack.prometheus
.prometheusSpec.storageSpec` and `loki.singleBinary.persistence.size`
if Small or Large fits better.

## Longhorn: double the PVC size for the physical disk

Longhorn is configured with `defaultReplicaCount: 2` (2 workers = 2
copies of everything). That means whatever you set as a PVC's logical
size, Longhorn needs that much space *on 2 different nodes*, not once
total. Prometheus + Alertmanager + Grafana + Loki + Tempo's PVCs sum to
**115Gi logical** at the Medium tier — with 2 replicas across exactly 2
workers, each worker ends up holding one full copy of everything, so
each worker's dedicated Longhorn disk needs to fit that full 115Gi, plus
Longhorn's own recommended ~20–25% free space margin for its
operations. That's where the worker disk numbers below come from.

## VM specs

| Node | vCPU | RAM | OS disk | Longhorn data disk | Notes |
|---|---|---|---|---|---|
| Control-plane (x1) | 4 | 8 GiB | 100 GB SSD/NVMe | — | Unaffected by retention — no workloads scheduled here |
| Worker (x2), **Small** tier | 8 | 16 GiB | 100 GB | **100 GB**, separate disk | ~65Gi logical PVCs × RF2, /2 nodes + margin |
| Worker (x2), **Medium** tier | 8 | 24–32 GiB | 100 GB | **200 GB**, separate disk | 115Gi logical PVCs × RF2, /2 nodes + margin — matches current `values.yaml` |
| Worker (x2), **Large** tier | 12–16 | 32–48 GiB | 100 GB | **350–400 GB**, separate disk | ~225Gi logical PVCs × RF2, /2 nodes + margin |
| Workstation VM | 2 | 4 GiB | 40–50 GB | — | Retention-independent — runs kubeadm + ArgoCD, not affected by data volume |

RAM goes up across tiers because higher series/log volume means more
active chunks held in memory by Prometheus and Loki before they're
flushed to disk, not because of retention length itself — a 7-day
retention at Large-tier ingestion rates would want the same RAM as
30-day retention at Large-tier rates. Disk is what retention actually
buys you more of.

## Total footprint (Medium tier, 1 CP + 2 workers + workstation VM)

- vCPU: 1×4 + 2×8 + 1×2 = **22 vCPU**
- RAM: 1×8 + 2×28 (midpoint of 24–32) + 1×4 = **68 GiB**
- Disk: 1×100 (CP) + 2×(100 + 200) (workers) + 1×45 (workstation) ≈
  **745 GB**
