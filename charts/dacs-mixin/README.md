# dacs-mixin Helm chart

Installs the [dacs-mixin](https://github.com/cb-Sigma/dacs-mixin) monitoring
bundle for [DACS](https://github.com/Azure/dacs): a `PrometheusRule`, a
`PodMonitor` for cache servers, a `ServiceMonitor` for the cache-controller and
Grafana dashboard ConfigMaps.

Unofficial community project; not affiliated with or endorsed by Microsoft.

## Prerequisites

- Prometheus Operator CRDs (`monitoring.coreos.com/v1`)
- A Grafana dashboard sidecar that watches ConfigMaps labelled
  `grafana_dashboard` (the kube-prometheus-stack default), or import the JSON
  yourself
- kube-state-metrics for the replica panels and alerts

## Install

The chart is not published to a chart repository; install it from a clone.

```sh
git clone https://github.com/cb-Sigma/dacs-mixin.git
helm install dacs-mixin ./dacs-mixin/charts/dacs-mixin \
  --namespace monitoring \
  --set commonLabels.release=kube-prometheus-stack
```

`commonLabels` matters: most Prometheus Operator installations only select
rules and monitors that carry a particular label.

## Values

| Key | Default | Description |
|---|---|---|
| `nameOverride`, `fullnameOverride` | `""` | Standard name overrides |
| `commonLabels` | `{}` | Labels added to every object |
| `rules.enabled` | `true` | Create the `PrometheusRule` |
| `rules.labels` | `{}` | Extra labels for the `PrometheusRule` |
| `rules.cache.recording` | `true` | Cache recording rules (the cache alerts need them) |
| `rules.cache.alerts` | `true` | Cache server alerts |
| `rules.controller.alerts` | `true` | cache-controller alerts |
| `rules.client.enabled` | `false` | Opt-in client rules and alert; read `docs/client-metrics.md` first |
| `rules.capacity` | `[]` | List of `{namespace, cache, serverSizeInGB}`; arms `DacsCacheServerNearCapacity` |
| `monitors.labels` | `{}` | Extra labels for both monitors |
| `monitors.cacheServer.enabled` | `true` | Create the cache server `PodMonitor` |
| `monitors.cacheServer.namespaces` | `[]` | Namespaces to search; empty means all |
| `monitors.cacheServer.podSelector` | `app: cacheserver` | Pod labels to match |
| `monitors.cacheServer.interval` | `30s` | Scrape interval |
| `monitors.cacheServer.scrapeTimeout` | `""` | Scrape timeout |
| `monitors.controller.enabled` | `true` | Create the controller `ServiceMonitor` |
| `monitors.controller.namespaces` | `[]` | Namespaces to search; empty means all |
| `monitors.controller.serviceSelector` | `app.kubernetes.io/name: dacs`, `control-plane: controller-manager` | Service labels to match |
| `monitors.controller.interval` | `30s` | Scrape interval |
| `monitors.controller.scrapeTimeout` | `""` | Scrape timeout |
| `monitors.controller.bearerTokenFile` | service account token path | Token used to authenticate to the metrics endpoint |
| `monitors.controller.authorization` | `{}` | Alternative to `bearerTokenFile`: an `authorization` block referencing a Secret |
| `monitors.controller.tlsConfig` | `insecureSkipVerify: true` | TLS settings; the controller certificate is self-signed unless cert-manager is enabled in DACS |
| `dashboards.enabled` | `true` | Create dashboard ConfigMaps |
| `dashboards.namespace` | `""` | Namespace for the ConfigMaps; defaults to the release namespace |
| `dashboards.labels` | `grafana_dashboard: "1"` | Labels the Grafana sidecar watches for |
| `dashboards.annotations` | `{}` | For example `grafana_folder: DACS` |
| `dashboards.overview`, `.cacheServers`, `.clients`, `.controller` | `true` | Per-dashboard switches |

## What the chart cannot do

The rule files and dashboards under `files/` are rendered from jsonnet and
shipped as they are. Selectors (`job="dacs-cache-server"`,
`job="dacs-controller"`, `job="kube-state-metrics"`) and alert thresholds are
therefore fixed. The monitors in this chart set the two DACS job names for
you; if you need different selectors or thresholds, change
`config.libsonnet` in the repository and run `make render`.

## Notes

- **Controller scraping needs RBAC.** The controller's metrics endpoint
  requires Kubernetes authentication and authorization. Bind the DACS
  `<namePrefix>-metrics-reader` ClusterRole to your Prometheus service account.
- **Already using the DACS chart's own ServiceMonitor?** Set
  `monitors.controller.enabled=false` here to avoid scraping twice, and be
  aware that the controller alerts and dashboard expect `job="dacs-controller"`.
- **`bearerTokenFile`** mirrors what the upstream DACS ServiceMonitor uses.
  Newer Prometheus Operator versions prefer the `authorization` field; if
  yours rejects `bearerTokenFile`, set it to an empty string and fill in
  `monitors.controller.authorization` instead.
