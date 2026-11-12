# dacs-mixin

**Dashboards, alerts and recording rules for [DACS](https://github.com/Azure/dacs), the Kubernetes cache that keeps Azure Blob data on GPU-node NVMe. Every query is checked against a metric inventory read from the DACS source.**

[![CI](https://github.com/cb-Sigma/dacs-mixin/actions/workflows/ci.yml/badge.svg)](https://github.com/cb-Sigma/dacs-mixin/actions/workflows/ci.yml)
[![License](https://img.shields.io/github/license/cb-Sigma/dacs-mixin)](LICENSE)

> [!IMPORTANT]
> **Unofficial community project.** dacs-mixin is not affiliated with,
> endorsed by, or supported by Microsoft or the DACS maintainers.
>
> **DACS is pre-release**, so its metric names and labels can change at any
> time. This mixin was verified against Azure/dacs commit **`27ec57c`**
> (2026-11-11) by reading the source. The dashboards have **not yet been
> loaded against a live DACS cluster**; see
> [How this is tested, and what is not](#how-this-is-tested-and-what-is-not).

DACS (Distributed Accelerator for Cloud Storage) exposes Prometheus metrics
from its cache servers and its controller, and ships a ServiceMonitor for the
controller. It ships no dashboards, no alerts, no recording rules, and nothing
that scrapes the cache servers. This repository fills that gap as a standard
[monitoring mixin](https://monitoring.mixins.dev/), with the rendered
artifacts committed so you do not need jsonnet to use it.

## What you get

| | |
|---|---|
| **4 Grafana dashboards** | Overview, cache servers, clients, controller |
| **17 alerts** | 12 for cache servers, 4 for the controller, 1 opt-in for clients; each with a severity, a `for`, and a [runbook](docs/runbooks/README.md) |
| **12 recording rules** | Hit ratio, error ratio, latency quantiles, byte rates, fleet size |
| **Scrape configuration** | A `PodMonitor` for cache servers (upstream has none) and a `ServiceMonitor` for the controller |
| **Three ways to install** | `kubectl apply -k`, a Helm chart, or plain files (dashboard JSON, rule YAML) |
| **A verified [metric inventory](docs/metrics.md)** | Names, types, labels and label values, each with a source file reference |

### Dashboards

No screenshots yet: there was no Grafana or DACS cluster available when this
was built, and faking them would defeat the purpose. If you run this against a
real cluster, [screenshots are very welcome](CONTRIBUTING.md#screenshots-wanted).
Until then, this is what each dashboard contains.

| Dashboard | File | Variables | What it shows |
|---|---|---|---|
| **DACS / Overview** | [`dacs-overview.json`](dashboards_out/dacs-overview.json) | data source, namespace, cache | Headline stats (hit ratio, request rate, error ratio, bytes served from cache, space used, servers ready vs desired); hit ratio and hits vs misses per cache; requests by type and by status; bytes served from cache and bytes written into it; download and upload latency p50/p99; space used, capacity used and server counts; a per-cache summary table |
| **DACS / Cache servers** | [`dacs-cache-servers.json`](dashboards_out/dacs-cache-servers.json) | data source, namespace, cache, pod | Per-pod table; requests, hit ratio, errors by status and aborted connections per pod; latency p99 per pod and a latency heatmap; in-flight requests, new connections, listen backlog, accept-queue overflows, listen drops, SYN-queue drops, SYN cookies and `accept()` errors by errno; file handles and space used; request sizes (throughput, average, distribution) |
| **DACS / Clients** | [`dacs-clients.json`](dashboards_out/dacs-clients.json) | data source, workload, rate window | Hit ratio, hits and misses, download requests per workload; bytes requested vs served from cache, upload volume, maintenance requests; DNS errors per cache server; client-side latency, overall and by I/O size class. **Needs client metrics, which are opt-in; see below.** |
| **DACS / Controller** | [`dacs-controller.json`](dashboards_out/dacs-controller.json) | data source, namespace, pod | Reconciles by result, errors, panics and timeouts, reconcile duration, workers; workqueue depth, adds, retries, queue and work duration, unfinished work; admission webhook requests and latency; Kubernetes API requests by code; CPU, memory, goroutines |

Every panel has a description and a unit. Data sources are a template
variable; there are no hard-coded data source UIDs. The dashboards query raw
metrics, so they work even if you do not install the recording rules.

### Alerts

| Alert | Severity | Fires when |
|---|---|---|
| `DacsCacheServerDown` | warning | A cache server's metrics endpoint has been unreachable for 5 minutes |
| `DacsCacheServersNotReady` | warning | A cache has had fewer ready servers than desired for 15 minutes |
| `DacsCacheNoReadyServers` | critical | A cache has had no ready servers for 5 minutes |
| `DacsCacheHitRatioLow` | warning | Under 50% of downloads hit the cache for 30 minutes, with real traffic |
| `DacsCacheErrorRatioHigh` | warning | Over 5% of requests end in an error status for 10 minutes |
| `DacsCacheErrorRatioCritical` | critical | Over 25% of requests end in an error status for 5 minutes |
| `DacsCacheDownloadLatencyHigh` | warning | p99 server-side download latency above 1 s for 15 minutes |
| `DacsCacheServerAcceptQueueOverflow` | warning | The TCP accept queue has been overflowing for 10 minutes |
| `DacsCacheServerListenDrops` | critical | More than 1 connection attempt per second dropped for 10 minutes |
| `DacsCacheServerSynQueueDrops` | warning | SYNs dropped because the SYN queue is full, for 10 minutes |
| `DacsCacheServerAcceptErrors` | warning | `accept()` has been failing for 5 minutes (labelled by errno) |
| `DacsCacheServerNearCapacity` | warning | A server is above 95% of its size for 30 minutes. **Needs capacity supplied by you**, see [Capacity](#capacity) |
| `DacsControllerDown` | warning | No healthy cache-controller target for 10 minutes |
| `DacsControllerReconcileErrors` | warning | Over 10% of reconciles fail for 15 minutes |
| `DacsControllerReconcilePanics` | warning | A reconcile panicked in the last 15 minutes |
| `DacsControllerWorkqueueStalled` | warning | One reconcile has been running for over 10 minutes |
| `DacsClientDnsErrors` | warning | **Opt-in.** A workload cannot resolve a cache server for 15 minutes |

Each alert links to a runbook in [`docs/runbooks/`](docs/runbooks/README.md)
covering meaning, impact, diagnosis commands and mitigation.

## Things worth knowing about DACS metrics

Reading the source turned up a few things that are easy to get wrong:

- **A cache miss is reported as `status="InvalidTransition"`.** On a
  `Download` it means "not in cache"; on an `Upload` it means "already
  cached". Neither is an error, and the hit ratio is
  `Download/Success` over `Download/(Success + InvalidTransition)`.
- **`cache_server_request_counter` has no `_total` suffix**, and
  `cache_server_count` is not a metric at all (it is a ConfigMap key).
- **`cache_server_active_connections` counts in-flight requests**, not open
  connections, and **`cache_server_open_fds` is node-wide**, not per process.
- **The cache size limit is not exported**, only the bytes used.
- **Cache servers expose their own `instance` label**, which Prometheus
  renames to `exported_instance`.
- **Client metrics are pushed over OTLP, off by default, every 5 minutes**,
  and carry no pod or cache identity.

Details and source references are in [docs/metrics.md](docs/metrics.md).

## Requirements

- **DACS** deployed through its cache-controller (`Cache` custom resources).
- **Prometheus**. For the `PodMonitor`, `ServiceMonitor` and `PrometheusRule`
  objects you need the **Prometheus Operator CRDs** (`monitoring.coreos.com/v1`),
  as installed by kube-prometheus-stack. Without the operator, use the plain
  rule files and your own scrape configuration; see
  [Without the Prometheus Operator](#without-the-prometheus-operator).
- **kube-state-metrics** for the desired/ready server panels and the two
  replica alerts (`kube_statefulset_replicas`,
  `kube_statefulset_status_replicas_ready`). Everything else works without it.
- **Grafana** 10 or newer. The dashboards use schema version 39 and the
  `timeseries`, `stat`, `table` and `heatmap` panels.
- To scrape the **controller**: its metrics endpoint is HTTPS with Kubernetes
  authentication, so the Prometheus service account must be allowed to `GET
  /metrics`. DACS ships a ClusterRole for this, named `<namePrefix>-metrics-reader`
  (`dacs-metrics-reader` with the default prefix); bind it:

  ```sh
  kubectl create clusterrolebinding prometheus-dacs-metrics-reader \
    --clusterrole=dacs-metrics-reader \
    --serviceaccount=<prometheus namespace>:<prometheus service account>
  ```

## Install

All four paths install the same rules and dashboards.

Whichever you pick, check that your Prometheus selects the objects. Most
operator installations only pick up monitors and rules carrying a specific
label, such as `release: kube-prometheus-stack`.

### kubectl and kustomize

```sh
git clone https://github.com/cb-Sigma/dacs-mixin.git
cd dacs-mixin
kubectl apply -k manifests/
```

This creates, in namespace `monitoring`: one `PrometheusRule`, the cache server
`PodMonitor`, the controller `ServiceMonitor` and four dashboard ConfigMaps
labelled `grafana_dashboard: "1"` for the Grafana sidecar. To change the
namespace or add the label your Prometheus needs, use an overlay:

```yaml
# kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: observability
resources:
  - https://github.com/cb-Sigma/dacs-mixin//manifests?ref=main
labels:
  - pairs:
      release: kube-prometheus-stack
```

### Helm

The chart lives in this repository; it is not published to a chart repository.

```sh
git clone https://github.com/cb-Sigma/dacs-mixin.git
helm install dacs-mixin ./dacs-mixin/charts/dacs-mixin \
  --namespace monitoring \
  --set commonLabels.release=kube-prometheus-stack
```

Toggles (all in [`values.yaml`](charts/dacs-mixin/values.yaml)):

| Value | Default | |
|---|---|---|
| `rules.enabled` | `true` | The `PrometheusRule` |
| `rules.cache.recording`, `rules.cache.alerts` | `true` | Cache server rules and alerts |
| `rules.controller.alerts` | `true` | Controller alerts |
| `rules.client.enabled` | `false` | Opt-in client rules and alert |
| `rules.capacity` | `[]` | Per-cache server size, enables the capacity alert |
| `monitors.cacheServer.enabled` | `true` | Cache server `PodMonitor` |
| `monitors.controller.enabled` | `true` | Controller `ServiceMonitor` |
| `dashboards.enabled` | `true` | Dashboard ConfigMaps; each dashboard also has its own switch |
| `commonLabels` | `{}` | Labels for every object |

### Import the dashboards into Grafana

Download the files in [`dashboards_out/`](dashboards_out/) and use
**Dashboards > New > Import** in Grafana. Pick your Prometheus data source
when prompted. The rule files for a non-operator Prometheus are in
[`rules_out/`](rules_out/).

### As a jsonnet mixin

```sh
jb install github.com/cb-Sigma/dacs-mixin@main
```

```jsonnet
local dacs = (import 'github.com/cb-Sigma/dacs-mixin/mixin.libsonnet') + {
  _config+:: {
    cacheServerSelector: 'job="dacs-cache-server"',
    hitRatioLowThreshold: 0.3,
  },
};

{
  dashboards: dacs.grafanaDashboards,
  rules: dacs.prometheusRules,
  alerts: dacs.prometheusAlerts,
  // Opt-in, see docs/client-metrics.md:
  // clientRules: dacs.clientRules, clientAlerts: dacs.clientAlerts,
}
```

The mixin has **no jsonnet dependencies**: dashboards are written in plain
jsonnet with a small helper library
([`dashboards/g.libsonnet`](dashboards/g.libsonnet)) instead of grafonnet.
That keeps rendering reproducible with nothing but a `jsonnet` binary, with no
`jb install`, no vendor directory and no lock file to keep fresh. It also works with
`mixtool generate all`.

### Without the Prometheus Operator

Load [`rules_out/prometheus_rules.yaml`](rules_out/prometheus_rules.yaml) and
[`rules_out/prometheus_alerts.yaml`](rules_out/prometheus_alerts.yaml) through
`rule_files`, and scrape cache servers so that the series carry the labels the
mixin expects (`job`, `namespace`, `pod`, `cache`). This scrape configuration
is the equivalent of the shipped `PodMonitor`:

```yaml
scrape_configs:
  - job_name: dacs-cache-server
    kubernetes_sd_configs:
      - role: pod
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_label_app]
        regex: cacheserver
        action: keep
      - source_labels: [__meta_kubernetes_pod_container_port_name]
        regex: metrics
        action: keep
      - source_labels: [__meta_kubernetes_namespace]
        target_label: namespace
      - source_labels: [__meta_kubernetes_pod_name]
        target_label: pod
      - source_labels: [__meta_kubernetes_pod_label_dacs_azure_com_cache_name]
        target_label: cache
```

## Configuration

Selectors, label names and every alert threshold live in
[`config.libsonnet`](config.libsonnet) and are documented in
[docs/configuration.md](docs/configuration.md). The most likely ones to touch:

| Key | Default | |
|---|---|---|
| `cacheServerSelector` | `job="dacs-cache-server"` | How to find cache server series |
| `controllerSelector` | `job="dacs-controller"` | How to find controller series |
| `kubeStateMetricsSelector` | `job="kube-state-metrics"` | How to find kube-state-metrics |
| `cacheLabel` | `cache` | Label holding the Cache name |
| `hitRatioLowThreshold` | `0.5` | |
| `errorRatioWarningThreshold` / `errorRatioCriticalThreshold` | `0.05` / `0.25` | |
| `downloadLatencyP99ThresholdMs` | `1000` | |
| `nearCapacityThreshold` | `0.95` | |
| `cacheCapacities` | `[]` | See [Capacity](#capacity) |
| `runbookURLPattern` | this repository | Point alerts at your own runbooks |

Changing these needs jsonnet (`make render`). The Helm chart can switch things
on and off but ships the rules as rendered.

### Capacity

DACS exports how many bytes a cache server is using but not its limit, so a
"percent full" number cannot be computed from DACS metrics alone. Rather than
guess, the mixin asks you for it: provide the per-server size once per cache
(Helm `rules.capacity`, `_config.cacheCapacities`, or a small
`PrometheusRule`) and the capacity panel and `DacsCacheServerNearCapacity`
come alive. Until then they stay empty and silent.
[docs/capacity.md](docs/capacity.md) has the details.

### Client metrics

The Clients dashboard and `DacsClientDnsErrors` use metrics from the DACS
client library inside your workloads. Those are disabled by default, pushed
over OTLP rather than scraped, and their names in Prometheus depend on your
OpenTelemetry pipeline. They are therefore **opt-in and kept out of the
default alerts**. [docs/client-metrics.md](docs/client-metrics.md) explains how
to enable them and what can go wrong.

## How this is tested, and what is not

Run everything with `make all` (see [Development](#development)). CI runs the
same targets on every push and pull request.

**Tested**

| Check | Command | What it proves |
|---|---|---|
| Metric inventory guard | `make test-inventory` | Every metric, label and enumerated label value in every dashboard query, rule and manifest exists in [`inventory/metrics.yaml`](inventory/metrics.yaml). Client metrics cannot leak into default alerts. This is the main defence against invented metrics. |
| Alert unit tests | `make test-rules` | `promtool test rules` with synthetic series: every alert has a case where it fires and a case where it must stay silent, including annotation text. |
| Rule validation | `make lint-rules` | `promtool check rules --lint=all --lint-fatal` on all rule files. |
| Dashboard query syntax | `make lint-dashboard-queries` | Every dashboard query and variable query is parsed by promtool. |
| Repository checks | `make test-repo` | JSON and YAML validity; every alert has a severity, summary, description and an existing runbook; every panel has a description, a unit and the data source variable; docs list every metric, alert and dashboard. |
| Drift | `make drift` | Committed rendered files are byte-identical to what the jsonnet produces. |
| jsonnet | `make lint-jsonnet` | `jsonnetfmt --test` and `jsonnet-lint`. |
| Dashboard lint | `make lint-dashboards` | grafana `dashboard-linter --strict`, with the documented exclusions in [`.dashboard-lint.yaml`](.dashboard-lint.yaml). |
| Helm chart | `make lint-helm` | `helm lint --strict`; `helm template` with defaults, with everything enabled and with everything disabled, compared against the jsonnet output. |
| Manifests | `make lint-manifests` | `kustomize build` and `kubeconform -strict` against Kubernetes and Prometheus Operator CRD schemas. |
| Mixin compatibility | `make lint-mixtool` | `mixtool generate all` reproduces the committed rules and dashboards. |

**Not tested**

- **Nothing has run against a live DACS cluster.** The inventory comes from
  reading source code at one commit. No metric has been observed on a real
  `/metrics` endpoint, no dashboard has been opened in Grafana against real
  data, and no alert has fired on a real incident.
- **Dashboards have not been rendered in Grafana at all.** They pass the
  linter and a structural check, which says nothing about how they look.
- **The PodMonitor and ServiceMonitor have not scraped anything.** They are
  schema-valid and match the labels and ports in the DACS templates, but
  relabeling, TLS and RBAC for the controller endpoint are untested.
- **Client metric names are derived, not observed.** See
  [docs/client-metrics.md](docs/client-metrics.md).
- **Thresholds are educated guesses**, not tuned on production traffic.
- **Runbooks have not been used in anger.**
- `mixtool lint` is not clean and is not part of CI: it insists on `job` and
  `instance` template variables, which these dashboards deliberately replace
  with a fixed job selector and a `pod` variable, and it flags
  `DacsControllerDown` for an untemplated description (an `absent()` alert has
  no labels to template).
- `jb install` from GitHub has not been exercised.

If you try it on a real cluster, please
[open an issue](https://github.com/cb-Sigma/dacs-mixin/issues/new/choose) with
what worked and what did not. A confirmed-working report is as valuable as a
bug.

## FAQ

**Is this an official DACS project?**
No. It is an independent community project built by reading the public DACS
source. Questions about DACS itself belong in the
[DACS repository](https://github.com/Azure/dacs).

**The dashboards are empty. What now?**
Check Prometheus' targets page for `dacs-cache-server`. If the target is
missing, your Prometheus is not selecting the PodMonitor (add the label it
wants). If the target is there, check that the series have a `cache` label and
`job="dacs-cache-server"`; if your labels differ, adjust the selectors in
`config.libsonnet` and re-render.

**Why does my hit ratio look low right after deploying?**
A new or resized cache starts empty and fills on demand. Scaling changes which
server owns which key, so part of the cache is cold again afterwards.

**Why is `InvalidTransition` so high? Is something broken?**
No. That is how the cache server labels a cache miss on download and an
already-cached chunk on upload. See [docs/metrics.md](docs/metrics.md#status-values).

**Why is the "Capacity used" panel empty?**
DACS does not export its size limit. See [Capacity](#capacity).

**Why is the Clients dashboard empty?**
Client metrics are opt-in and pushed over OTLP. See
[docs/client-metrics.md](docs/client-metrics.md).

**I already enabled the ServiceMonitor in the DACS Helm chart.**
Then disable the one here (`monitors.controller.enabled=false`, or drop
`servicemonitor-controller.yaml` from the kustomization) and set
`controllerSelector` to the job that monitor produces, which is the name of the
controller's metrics Service.

**Does it work with Azure Monitor managed Prometheus?**
Untested. The rule files are plain Prometheus rules and the dashboards are
plain Grafana JSON, so they should load, but you need a scrape configuration
that produces the `job`, `namespace`, `pod` and `cache` labels.

**DACS changed a metric. How do I update?**
Follow [Re-verifying against a newer DACS](docs/metrics.md#re-verifying-against-a-newer-dacs),
update the inventory, and let `make all` point at every query that has to
change.

## Development

Requirements: Go (to build the tools), Python 3 with PyYAML, make, git.

```sh
make tools         # jsonnet, jsonnetfmt, jsonnet-lint, promtool -> ./.bin (git-ignored)
make all           # render, lint, test, drift check
make tools-extra   # helm, kustomize, kubeconform, dashboard-linter, mixtool
make lint-extra    # dashboard-linter, helm, kubeconform, mixtool
make help          # every target
```

Layout:

```
mixin.libsonnet        entry point
config.libsonnet       selectors and thresholds
alerts/ rules/         alert and recording rule sources
dashboards/            dashboard sources (plain jsonnet)
lib/                   render entry point and Kubernetes objects
dashboards_out/        rendered dashboards            (generated)
rules_out/             rendered rule files            (generated)
manifests/             kustomize base                 (generated, except kustomization.yaml and examples/)
charts/dacs-mixin/     Helm chart                     (files/ is generated)
inventory/metrics.yaml machine-readable metric inventory
docs/                  metric inventory, configuration, runbooks
scripts/ tests/        checks and unit tests
```

Never edit generated files by hand; change the jsonnet and run `make render`.

## Roadmap

- Validate against a live DACS cluster and add real screenshots.
- Confirm client metric names against a real OTLP pipeline and, if they hold,
  promote the client alert out of opt-in.
- Replace the hand-supplied capacity with a real metric if DACS starts
  exporting its size limit.
- Multi-cluster support (a `cluster` variable and label).
- SLO-style burn-rate alerts for hit ratio and errors once there is real data
  to base objectives on.
- Publish the Helm chart to a chart repository and tag releases.
- Track DACS releases once it leaves pre-release, with a compatibility table.

## Contributing

Issues and pull requests are welcome, especially reports from real clusters.
See [CONTRIBUTING.md](CONTRIBUTING.md) and the
[Code of Conduct](CODE_OF_CONDUCT.md). Security reports: [SECURITY.md](SECURITY.md).

## License

[Apache License 2.0](LICENSE). Copyright 2026 The dacs-mixin Authors.

DACS is a project of Microsoft, licensed separately under Apache-2.0. "Azure"
and "Microsoft" are trademarks of the Microsoft group of companies; their use
here is purely descriptive.
