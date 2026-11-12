# Configuration

The rendered files in this repository use the defaults below. To change any of
them you need jsonnet: override `_config` and render again.

```jsonnet
// my-dacs-mixin.libsonnet
(import 'github.com/cb-Sigma/dacs-mixin/mixin.libsonnet') + {
  _config+:: {
    cacheServerSelector: 'job="dacs-cache-server", cluster="prod-gpu"',
    hitRatioLowThreshold: 0.3,
    cacheCapacities: [
      { namespace: 'cache-server', cache: 'cache-sample', serverSizeBytes: 100 * 1024 * 1024 * 1024 },
    ],
  },
}
```

Inside a clone of this repository the quickest way is to edit
[`config.libsonnet`](../config.libsonnet) and run `make render`.

## Selectors

| Key | Default | Purpose |
|---|---|---|
| `cacheServerSelector` | `job="dacs-cache-server"` | Matchers for cache server series |
| `controllerSelector` | `job="dacs-controller"` | Matchers for cache-controller series |
| `kubeStateMetricsSelector` | `job="kube-state-metrics"` | Matchers for kube-state-metrics |
| `clientSelector` | empty | Extra matchers for cache client series |
| `cacheLabel` | `cache` | Target label that holds the Cache name |
| `clientWorkloadLabel` | `job` | Label that identifies a client workload |
| `controllerName` | `cache` | Value of the `controller` label for the Cache reconciler |

The defaults match the PodMonitor and ServiceMonitor in this repository, which
pin the job names with a relabeling. If you scrape DACS some other way, either
reproduce these labels (`job`, `namespace`, `pod`, `cache`) or change the
selectors. The cache label must hold the Cache name, which is also the
StatefulSet name: the replica-count rules join kube-state-metrics on it.

## Status semantics

| Key | Default | Purpose |
|---|---|---|
| `errorStatuses` | `BadRequest\|InternalError\|NetworkError\|NotSet` | `status` values counted as errors |
| `ignoredRequestTypes` | `Unknown` | `request_type` values left out of error ratios |

## Alert thresholds

| Key | Default | Alert |
|---|---|---|
| `cacheServerDownFor` | `5m` | `DacsCacheServerDown` |
| `cacheServersNotReadyFor` | `15m` | `DacsCacheServersNotReady` |
| `cacheNoReadyServersFor` | `5m` | `DacsCacheNoReadyServers` |
| `cacheDiscoveryLookback` | `1h` | How long a cache stays tracked for the two alerts above after its last scrape |
| `hitRatioLowThreshold` | `0.5` | `DacsCacheHitRatioLow` |
| `hitRatioLowMinDownloadRate` | `1` (per second) | `DacsCacheHitRatioLow` |
| `hitRatioLowFor` | `30m` | `DacsCacheHitRatioLow` |
| `errorRatioWarningThreshold` | `0.05` | `DacsCacheErrorRatioHigh` |
| `errorRatioCriticalThreshold` | `0.25` | `DacsCacheErrorRatioCritical` |
| `errorRatioMinRequestRate` | `0.1` (per second) | both error ratio alerts |
| `errorRatioWarningFor` / `errorRatioCriticalFor` | `10m` / `5m` | |
| `downloadLatencyP99ThresholdMs` | `1000` | `DacsCacheDownloadLatencyHigh` |
| `downloadLatencyFor` | `15m` | `DacsCacheDownloadLatencyHigh` |
| `acceptQueueOverflowFor` | `10m` | `DacsCacheServerAcceptQueueOverflow` |
| `listenDropsPerSecondThreshold` | `1` | `DacsCacheServerListenDrops` |
| `listenDropsFor` | `10m` | `DacsCacheServerListenDrops` |
| `synQueueDropsFor` | `10m` | `DacsCacheServerSynQueueDrops` |
| `acceptErrorsFor` | `5m` | `DacsCacheServerAcceptErrors` |
| `nearCapacityThreshold` | `0.95` | `DacsCacheServerNearCapacity` |
| `nearCapacityFor` | `30m` | `DacsCacheServerNearCapacity` |
| `controllerDownFor` | `10m` | `DacsControllerDown` |
| `controllerReconcileErrorRatioThreshold` | `0.1` | `DacsControllerReconcileErrors` |
| `controllerReconcileErrorsFor` | `15m` | `DacsControllerReconcileErrors` |
| `controllerWorkqueueStalledSeconds` | `600` | `DacsControllerWorkqueueStalled` |
| `controllerWorkqueueStalledFor` | `5m` | `DacsControllerWorkqueueStalled` |
| `clientDnsErrorsFor` | `15m` | `DacsClientDnsErrors` |

The thresholds are starting points chosen from the DACS source and general
practice, not from production data. Expect to tune them.

## Capacity and clients

| Key | Default | Purpose |
|---|---|---|
| `cacheCapacities` | `[]` | Per-server capacity per cache; see [capacity.md](capacity.md) |
| `clientCounterSuffix` | `_total` | Suffix on client counters; see [client-metrics.md](client-metrics.md) |
| `clientRateInterval` | `15m` | Rate window for client rules and the Clients dashboard default |

## Presentation

| Key | Default | Purpose |
|---|---|---|
| `runbookURLPattern` | `https://github.com/cb-Sigma/dacs-mixin/blob/main/docs/runbooks/%s.md` | `runbook_url` annotation; point it at your fork or wiki |
| `dashboardTags` | `['dacs']` | Tags, also used for the cross-dashboard links |
| `dashboardRefresh` | `1m` | |
| `dashboardTimeFrom` | `now-3h` | |
| `dashboardUIDs` | `dacs-overview`, `dacs-cache-servers`, `dacs-clients`, `dacs-controller` | |

## Helm chart values

The Helm chart ships the rendered files as they are, so it cannot change
selectors or thresholds. It can switch components on and off, add labels, set
capacities and adjust the monitors. See
[`charts/dacs-mixin/values.yaml`](../charts/dacs-mixin/values.yaml).
