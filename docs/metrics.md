# DACS metric inventory

Every dashboard query, recording rule and alert in this repository is built on
the metrics listed here, and CI enforces it: `scripts/check_metrics.py` parses
every PromQL expression and fails if it references a metric, label or label
value that is not in [`inventory/metrics.yaml`](../inventory/metrics.yaml),
the machine-readable twin of this page.

- **Verified against:** [Azure/dacs](https://github.com/Azure/dacs) commit
  `27ec57c` (2026-11-11).
- **How:** by reading the source. Nothing here was observed on a running
  cluster. Source paths below are relative to the DACS repository root.
- **DACS is pre-release.** Names can change without notice; see
  [Re-verifying](#re-verifying-against-a-newer-dacs).

## Summary

| Component | Library | Transport | Default state | Names in Prometheus |
|---|---|---|---|---|
| Cache server | prometheus-cpp 1.3.0 | Pull: `GET /metrics` on the pod's `metrics` port (9096) | Always on | Exactly as written in source |
| Cache client | opentelemetry-cpp 1.22.0 | Push: OTLP/HTTP to a collector | **Off** (`STORAGE_METRIC_OTEL_ENABLED=false`) | Depend on the pipeline; see below |
| cache-controller | controller-runtime 0.25.2 (client_golang) | Pull: HTTPS `GET /metrics` on port 8443, authenticated | On in the Helm chart (`metrics.enable: true`) | Standard controller-runtime names |

DACS defines no custom controller metrics, and it exports no metric for a
cache's desired or ready server count: `cache_server_count`, which looks like
one, is a key in the discovery ConfigMap
(`src/subsystems/cache-controller/internal/controller/templates/cacheserver-discovery-config.yaml:24`).
Replica counts in this mixin therefore come from kube-state-metrics.

## Cache server

Source: `src/subsystems/storage/cache_server/Metrics.cpp`,
`MetricsStore.h` and `Server.cpp`.

The server builds a `prometheus::Registry` and serves it with a
`prometheus::Exposer` bound to `0.0.0.0:$CACHESERVER_METRICS_PORT`
(`Metrics.cpp:35-38`). prometheus-cpp is used directly, with no OpenTelemetry
layer, so nothing is renamed: counters get no automatic `_total`, and
histograms expose the usual `_bucket`, `_sum` and `_count` series.

### Scrape endpoint

| | Value | Source |
|---|---|---|
| Port | `spec.metricsPort` on the `Cache` resource, default **9096**; container port name `metrics` | `src/subsystems/cache-controller/api/v1/cache_types.go:208-211`, `internal/controller/templates/cacheserver-app.yaml:138` |
| Path | `/metrics` (prometheus-cpp default; the upstream e2e test curls `http://localhost:9096/metrics`) | `test/pkg/scenario/cache_metrics.go:75` |
| Scheme / auth | Plain HTTP, none | |
| Pod labels | `app: cacheserver`, `dacs.azure.com/cache-name: <cache>` | `internal/controller/templates/cacheserver-app.yaml:38-39` |
| Workload | StatefulSet named after the Cache; headless Service of the same name also exposes the `metrics` port | `cacheserver-app.yaml:16-18`, `cacheserver-service.yaml:28` |
| Upstream monitor | **None.** No ServiceMonitor, PodMonitor or scrape annotations exist for cache servers. | |

This mixin ships a `PodMonitor` that fills the gap. It selects
`app: cacheserver`, scrapes the `metrics` port, sets `job="dacs-cache-server"`
and adds a `cache` label taken from `dacs.azure.com/cache-name` (falling back
to the StatefulSet name, which is the same thing).

### The `instance` label

Every cache server series is created with an explicit label
`instance="<CACHESERVER_HOSTNAME>"`, which the pod template sets to the pod
name (`Metrics.cpp:45`, `cacheserver-app.yaml:149`). Prometheus attaches its
own `instance` target label, so with the default `honorLabels: false` the
scraped one is renamed to **`exported_instance`**. The mixin never relies on
it; it uses the `pod` target label instead.

### Metrics

| Metric | Type | Unit | Labels | Source |
|---|---|---|---|---|
| `cache_server_request_counter` | counter | requests | `request_type`, `status` | `Metrics.cpp:111` |
| `cache_server_successful_request_latency_ms` | histogram | milliseconds | `request_type`, `status` (always `Success`) | `Metrics.cpp:100` |
| `cache_server_download_request_size_bytes` | histogram | bytes | | `Metrics.cpp:120` |
| `cache_server_upload_request_size_bytes` | histogram | bytes | | `Metrics.cpp:125` |
| `cache_server_cache_size_bytes` | gauge | bytes | | `Metrics.cpp:47` |
| `cache_server_active_connections` | gauge | requests | | `Metrics.cpp:42` |
| `cache_server_listen_backlog_max` | gauge | connections | | `Metrics.cpp:52` |
| `cache_server_passive_opens_total` | counter | connections | | `Metrics.cpp:77` |
| `cache_server_accept_queue_overflows_total` | counter | events | | `Metrics.cpp:57` |
| `cache_server_listen_drops_total` | counter | events | | `Metrics.cpp:62` |
| `cache_server_syn_queue_full_drops_total` | counter | events | | `Metrics.cpp:67` |
| `cache_server_syn_cookies_sent_total` | counter | events | | `Metrics.cpp:72` |
| `cache_server_accept_errors_total` | counter | errors | `errno` | `Metrics.cpp:87` |
| `cache_server_open_fds` | gauge | file handles | | `Metrics.cpp:82` |

All of them additionally carry the `instance` label described above.

Things the names do not tell you:

- **`cache_server_request_counter` has no `_total` suffix.** That is how it is
  spelled in source. Every `request_type` x `status` combination is registered
  at start-up with value 0 (`Metrics.cpp:106-115`), so the series always exist.
- **`cache_server_active_connections` counts in-flight requests, not sockets.**
  It is incremented when a worker thread picks a request up and decremented
  when the request finishes (`Server.cpp:97`, `Server.cpp:139`). Idle
  keep-alive connections are not counted, and the value cannot exceed the
  thread pool size (`spec.serverThreads`), plus InfiniBand handlers.
- **`cache_server_open_fds` is node-wide.** It is read from
  `/proc/sys/fs/file-nr`, which reports allocated file handles for the whole
  system, not for the cache server process.
- **Kernel counters are sampled once a minute.** A background thread reads
  `TcpExt.ListenOverflows`, `TcpExt.ListenDrops`, `TcpExt.TCPReqQFullDrop`,
  `TcpExt.TCPReqQFullDoCookies` and `Tcp.PassiveOpens` every 60 s and adds the
  deltas to the counters; `cache_server_cache_size_bytes` and
  `cache_server_open_fds` are refreshed on the same tick (`Server.cpp:310-395`).
  The counters cover the pod's network namespace, so they include the metrics
  listener as well as the cache port.
- **The size limit is not exported.** The same thread logs
  `CacheSize`, `CacheSizeLimit` and `CacheSizePercentage` but only publishes
  the size (`Server.cpp:386-393`). See [capacity.md](capacity.md).
- **`cache_server_accept_errors_total` series appear lazily**, on the first
  failure with a given `errno` (`Metrics.cpp:236-247`).
- **Sizes and latencies are recorded for successful requests only**
  (`Metrics.cpp:151-161`).

Histogram buckets:

| Metric | Upper bounds |
|---|---|
| `cache_server_successful_request_latency_ms` | 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000, +Inf (`Metrics.cpp:97`) |
| `cache_server_*_request_size_bytes` | 100000, 512000, 1024000, 4096000, 16384000, +Inf (`Metrics.cpp:118`) |

### `request_type` values

Defined in `MetricsStore.h:47-58`, indexed by the protobuf `Request` oneof
case (`src/subsystems/storage/common/proto/cache.proto:277-291`).

| Value | Meaning |
|---|---|
| `Download` | Read a chunk from the cache |
| `Upload` | Write a chunk into the cache |
| `Delete` | Delete by file name, group or last access time |
| `Getcacheservers` | Client discovery: return the server list |
| `Getcachelastaccesstimedistributionrequest` | Query the last-access-time distribution |
| `Ibinit` | Set up an InfiniBand session |
| `Unknown` | No request could be read or parsed before the connection ended |
| `Reserved1`, `Reserved4`, `Reserved5` | Retired protocol slots, always 0 |

### `status` values

Defined in `MetricsStore.h:59-66`, from the `ResponseCode` enum
(`cache_server/operations/ResponseCode.h:23-32`).

| Value | Meaning |
|---|---|
| `Success` | Request served. For `Download` this is a **cache hit**. |
| `InvalidTransition` | **Not an error.** For `Download` it is a **cache miss** (`NOT_FOUND`, `NOT_FOUND_GOT_LOCK`, `NOT_FOUND_ALREADY_LOCKED`; `operations/DownloadRequest.h:38-41`). For `Upload` it means the chunk is already cached (`FILE_EXISTS`; `operations/UploadRequest.h:31-32`). |
| `BadRequest` | Invalid offset/length, file name too long, malformed upload |
| `InternalError` | Server-side failure, including cache state that no longer matches the files on disk (`operations/DownloadRequest.cpp:139-150`) |
| `NetworkError` | The connection failed while sending or receiving. Also assigned when a handler closes the connection after an otherwise successful request (`Server.cpp:129-132`). |
| `NotSet` | Response code never assigned |

The upstream end-to-end tests compute hits and misses exactly this way
(`test/pkg/scenario/cache_metrics.go:108-121`), which is what the hit ratio in
this mixin is built on:

```promql
  sum(rate(cache_server_request_counter{request_type="Download", status="Success"}[5m]))
/
  sum(rate(cache_server_request_counter{request_type="Download", status=~"Success|InvalidTransition"}[5m]))
```

`request_type="Unknown"` with `status="NetworkError"` is what a connection
that closes before sending a complete request looks like
(`operations/HandleRequest.cpp:38-70` returns before the type is known, then
`Server.cpp:129-132` applies). The mixin excludes `Unknown` from error ratios
and plots it separately as "aborted connections".

## Cache client

Source: `src/subsystems/storage/cache_client/CacheClientImpl.cpp`,
`cache_client/connection/ConnectionManager.cpp` and
`src/subsystems/storage/common/metrics/`.

The cache client is a library that runs inside workload processes. Its metrics
go through `StorageMetrics`, which fans out to two backends
(`common/metrics/StorageMetrics.cpp:98-151`):

| Backend | Enabled by | Default | What it does |
|---|---|---|---|
| `LoggerMetricsStore` | `STORAGE_METRIC_LOGGING_ENABLED` | `true` | Logs aggregated values every `STORAGE_METRIC_LOGGING_INTERVAL_MINS` (15) minutes |
| `OtelMetricsStore` | `STORAGE_METRIC_OTEL_ENABLED` | **`false`** | Pushes OTLP/HTTP to `STORAGE_METRIC_OTEL_ENDPOINT` (default `http://localhost:4318/v1/metrics`) every `STORAGE_METRIC_OTEL_EXPORT_INTERVAL_MINS` (5) minutes |

**There is no scrape endpoint for client metrics.** `IMetricsStore.h:19`
says so explicitly ("To add a Prometheus /metrics scrape endpoint, implement a
PrometheusMetricsStore"). To get these metrics into Prometheus you need an
OTLP receiver in between: an OpenTelemetry Collector, or Prometheus' own OTLP
endpoint. [client-metrics.md](client-metrics.md) covers the options.

### Instruments (verified)

These are the instrument names as created in source. Counters are
`UInt64Counter`, histograms are `DoubleHistogram`; none has a unit set
(`common/metrics/OtelMetricsStore.cpp:165`, `:214`).

| OTLP instrument | Type | Unit | Extra attributes | Source |
|---|---|---|---|---|
| `cache_client_download_requests` | counter | requests | | `CacheClientImpl.cpp:542` |
| `cache_client_download_requested_bytes` | counter | bytes | | `CacheClientImpl.cpp:543` |
| `cache_client_download_cache_hits` | counter | requests | | `CacheClientImpl.cpp:789` |
| `cache_client_downloaded_bytes` | counter | bytes | | `CacheClientImpl.cpp:790` |
| `cache_client_download_cache_misses` | counter | requests | | `CacheClientImpl.cpp:796`, `:802` |
| `cache_client_upload_requests` | counter | requests | | `CacheClientImpl.cpp:282` |
| `cache_client_uploaded_bytes` | counter | bytes | | `CacheClientImpl.cpp:481` |
| `cache_client_delete_group_requests` | counter | requests | | `CacheClientImpl.cpp:844` |
| `cache_client_delete_by_last_access_time_requests` | counter | requests | | `CacheClientImpl.cpp:1133` |
| `cache_client_get_last_access_time_distribution_requests` | counter | requests | | `CacheClientImpl.cpp:990` |
| `cache_client_dns_errors` | counter | errors | `hostname` | `connection/ConnectionManager.cpp:604` |
| `cache_client_download_latency_ms` | histogram | milliseconds | | `CacheClientImpl.cpp:541`, `:791` |
| `cache_client_upload_latency_ms` | histogram | milliseconds | | `CacheClientImpl.cpp:281`, `:482` |

Each latency histogram has five siblings, one per I/O size class, created by
appending a suffix to the name (`common/metrics/StorageMetrics.cpp:27-34`,
`:214-231`): `_40KB` (up to 40 KiB), `_400KB`, `_4MB`, `_40MB` and `_huge`.
For example `cache_client_download_latency_ms_4MB`.

Every data point carries a `pid` attribute and, when the `RANK` environment
variable is a non-negative integer, a `rank` attribute
(`common/metrics/MetricsStoreBase.cpp:30-31`). The OTel resource has
`service.name` (from `STORAGE_METRIC_OTEL_SERVICENAME`, default `dacs`) and
optionally `process.rank` (`OtelMetricsStore.cpp:85-86`). There is no cache
name, namespace or pod attribute.

Latency is recorded only for successful operations: downloads that hit and
uploads that complete.

### Names in Prometheus (derived, not verified)

What these instruments are called once they reach Prometheus is decided by
whatever converts OTLP to Prometheus, not by DACS. This mixin assumes the
standard translation used by Prometheus' OTLP endpoint and by the Collector's
Prometheus exporters with default settings:

| OTLP instrument | Assumed Prometheus series |
|---|---|
| `cache_client_download_requests` | `cache_client_download_requests_total` |
| `cache_client_download_requested_bytes` | `cache_client_download_requested_bytes_total` |
| `cache_client_download_cache_hits` | `cache_client_download_cache_hits_total` |
| `cache_client_downloaded_bytes` | `cache_client_downloaded_bytes_total` |
| `cache_client_download_cache_misses` | `cache_client_download_cache_misses_total` |
| `cache_client_upload_requests` | `cache_client_upload_requests_total` |
| `cache_client_uploaded_bytes` | `cache_client_uploaded_bytes_total` |
| `cache_client_delete_group_requests` | `cache_client_delete_group_requests_total` |
| `cache_client_delete_by_last_access_time_requests` | `cache_client_delete_by_last_access_time_requests_total` |
| `cache_client_get_last_access_time_distribution_requests` | `cache_client_get_last_access_time_distribution_requests_total` |
| `cache_client_dns_errors` | `cache_client_dns_errors_total` |
| `cache_client_download_latency_ms` | `cache_client_download_latency_ms` (`_bucket`, `_sum`, `_count`) |
| `cache_client_download_latency_ms_40KB` | `cache_client_download_latency_ms_40KB` |
| `cache_client_download_latency_ms_400KB` | `cache_client_download_latency_ms_400KB` |
| `cache_client_download_latency_ms_4MB` | `cache_client_download_latency_ms_4MB` |
| `cache_client_download_latency_ms_40MB` | `cache_client_download_latency_ms_40MB` |
| `cache_client_download_latency_ms_huge` | `cache_client_download_latency_ms_huge` |
| `cache_client_upload_latency_ms` | `cache_client_upload_latency_ms` (`_bucket`, `_sum`, `_count`) |
| `cache_client_upload_latency_ms_40KB` | `cache_client_upload_latency_ms_40KB` |
| `cache_client_upload_latency_ms_400KB` | `cache_client_upload_latency_ms_400KB` |
| `cache_client_upload_latency_ms_4MB` | `cache_client_upload_latency_ms_4MB` |
| `cache_client_upload_latency_ms_40MB` | `cache_client_upload_latency_ms_40MB` |
| `cache_client_upload_latency_ms_huge` | `cache_client_upload_latency_ms_huge` |

Assumptions behind that table: monotonic sums gain `_total`; no unit suffix is
added because the instruments have no unit; the exporter uses cumulative
temporality; and `service.name` becomes the `job` label. Labels are `pid`,
optionally `rank`, `hostname` on the DNS counter, plus whatever your pipeline
adds.

Because of that uncertainty these metrics are marked `derived` in the
inventory and are treated differently from everything else:

- they appear only on the **DACS / Clients** dashboard and in the **opt-in**
  client rule files, never in the default rules and alerts (CI enforces this);
- `_config.clientCounterSuffix`, `clientWorkloadLabel` and `clientSelector`
  exist so the names can be adjusted without editing queries.

## cache-controller

Source: `src/subsystems/cache-controller/cmd/main.go`,
`internal/controller/crd_controller.go`, and controller-runtime v0.25.2
(`src/subsystems/cache-controller/go.mod:19`).

The manager uses the stock controller-runtime metrics server
(`cmd/main.go:248-281`). The source registers no metrics of its own, so what
you get is the standard controller-runtime, workqueue, client-go and
Go/process set.

### Scrape endpoint

| | Value | Source |
|---|---|---|
| Bind address | `--metrics-bind-address`, set to `:8443` by the chart when `metrics.enable` is true (default) | `charts/dacs/templates/manager/manager.yaml:46-47`, `charts/dacs/values.yaml:158-160` |
| Scheme / auth | HTTPS (`--metrics-secure=true`), protected by Kubernetes authentication and authorization; self-signed certificate unless cert-manager is enabled | `cmd/main.go:161`, `:254-259` |
| Service | `<namePrefix>-manager-metrics-service` (default `dacs-manager-metrics-service`), port name `https`, labels `app.kubernetes.io/name: dacs`, `control-plane: controller-manager` | `charts/dacs/templates/metrics/controller-manager-metrics-service.yaml` |
| Upstream monitor | A `ServiceMonitor`, **off by default** (`prometheus.enable: false`) | `charts/dacs/templates/monitoring/servicemonitor.yaml`, `charts/dacs/values.yaml:185-186` |
| RBAC | The scraper needs `get` on the `/metrics` non-resource URL; upstream ships a `metrics-reader` ClusterRole | `charts/dacs/templates/rbac/metrics-reader.yaml` |

The upstream ServiceMonitor sets no job label, so its job would be the Service
name. This mixin ships its own ServiceMonitor that pins `job="dacs-controller"`.
Enable one or the other, or point `_config.controllerSelector` at the upstream
job.

### Metrics used by this mixin

Paths are relative to `sigs.k8s.io/controller-runtime@v0.25.2`.

| Metric | Type | Labels | Source |
|---|---|---|---|
| `controller_runtime_reconcile_total` | counter | `controller`, `result` (`success`, `error`, `requeue`, `requeue_after`) | `pkg/internal/controller/metrics/metrics.go:33` |
| `controller_runtime_reconcile_errors_total` | counter | `controller` | `metrics.go:40` |
| `controller_runtime_terminal_reconcile_errors_total` | counter | `controller` | `metrics.go:47` |
| `controller_runtime_reconcile_panics_total` | counter | `controller` | `metrics.go:54` |
| `controller_runtime_reconcile_timeouts_total` | counter | `controller` | `metrics.go:89` |
| `controller_runtime_reconcile_time_seconds` | histogram | `controller` | `metrics.go:61` |
| `controller_runtime_max_concurrent_reconciles` | gauge | `controller` | `metrics.go:73` |
| `controller_runtime_active_workers` | gauge | `controller` | `metrics.go:80` |
| `workqueue_depth` | gauge | `name`, `controller`, `priority` | `pkg/internal/metrics/workqueue.go:49` |
| `workqueue_adds_total` | counter | `name`, `controller` | `workqueue.go:55` |
| `workqueue_retries_total` | counter | `name`, `controller` | `workqueue.go:97` |
| `workqueue_queue_duration_seconds` | histogram | `name`, `controller` | `workqueue.go:61` |
| `workqueue_work_duration_seconds` | histogram | `name`, `controller` | `workqueue.go:71` |
| `workqueue_unfinished_work_seconds` | gauge | `name`, `controller` | `workqueue.go:81` |
| `workqueue_longest_running_processor_seconds` | gauge | `name`, `controller` | `workqueue.go:90` |
| `controller_runtime_webhook_requests_total` | counter | `webhook`, `code` | `pkg/webhook/internal/metrics/metrics.go:48` |
| `controller_runtime_webhook_latency_seconds` | histogram | `webhook` | `metrics.go:34` |
| `controller_runtime_webhook_requests_in_flight` | gauge | `webhook` | `metrics.go:59` |
| `rest_client_requests_total` | counter | `code`, `method`, `host` | `pkg/metrics/client_go_adapter.go:131` |
| `leader_election_master_status` | gauge | `name` | `pkg/metrics/leaderelection.go:30` |
| `process_cpu_seconds_total` | counter | | client_golang process collector, registered at `pkg/internal/controller/metrics/metrics.go:105` |
| `process_resident_memory_bytes` | gauge | | same |
| `go_goroutines` | gauge | | client_golang Go collector, registered at `metrics.go:107` |

The Cache reconciler is registered with `.Named("cache")`
(`internal/controller/crd_controller.go:859`), so its series have
`controller="cache"` and its workqueue has `name="cache"`. It is the only
controller in the manager. Webhook series exist only when the admission
webhook is enabled (`api/v1/cache_webhook.go:34-36`).

## Metrics from other projects

| Metric | Type | From | Used for |
|---|---|---|---|
| `up` | gauge | Prometheus | Target health, dashboard variables |
| `kube_statefulset_replicas` | gauge | kube-state-metrics | Desired cache servers |
| `kube_statefulset_status_replicas_ready` | gauge | kube-state-metrics | Ready cache servers |

The join assumes the kube-state-metrics series carry the StatefulSet's own
namespace in `namespace`, which is the case when kube-state-metrics is scraped
with `honorLabels: true` (the kube-prometheus-stack default).

The StatefulSet is named after the Cache, so the mixin maps the
kube-state-metrics `statefulset` label onto `cache` and keeps only caches it
has scraped within `_config.cacheDiscoveryLookback`. Cache server pods have a
liveness probe but **no readiness probe**
(`cacheserver-app.yaml:187-195`), so "ready" means "container running".

## Series supplied by you

| Metric | Type | Purpose |
|---|---|---|
| `dacs:cache_server:capacity_bytes` | gauge | Per-server size limit for a cache, labelled `namespace` and `cache`. DACS does not export it; see [capacity.md](capacity.md). |

## Unverified, and therefore unused

- **Prometheus names of client metrics**, as explained above. Dashboard and
  opt-in rules only.
- **prometheus-cpp exposer self-metrics** (`exposer_*`). Whether the 1.3.0
  exposer publishes them on the same endpoint was not checked. Not used.
- **Go runtime metrics beyond `go_goroutines`.** controller-runtime enables the
  full runtime metric set, whose names depend on the Go version. Not used.
- **Cache server scheduler** (`src/subsystems/storage/cache_server_scheduler`)
  and the legacy `helm/cache-server` chart. No metrics code was found in the
  scheduler. Pods from the legacy chart also carry `app: cacheserver` and a
  `metrics` port, so the PodMonitor should pick them up with the StatefulSet
  name as `cache`, but that path was only read, not exercised.
- **Azure Monitor managed Prometheus.** `deploy/ama-metrics-settings-configmap.yaml`
  enables annotation-based pod scraping for the `cache-server` namespace, but
  the cache server pod template sets no `prometheus.io/*` annotations, so
  nothing is scraped that way out of the box.

## Re-verifying against a newer DACS

```sh
cd /path/to/dacs
git log --oneline 27ec57c..HEAD -- \
  src/subsystems/storage/cache_server/Metrics.cpp \
  src/subsystems/storage/cache_server/MetricsStore.h \
  src/subsystems/storage/cache_server/Server.cpp \
  src/subsystems/storage/cache_client \
  src/subsystems/storage/common/metrics \
  src/subsystems/cache-controller/cmd/main.go \
  src/subsystems/cache-controller/go.mod \
  src/subsystems/cache-controller/internal/controller/templates \
  src/subsystems/cache-controller/charts/dacs

# Every metric name in the cache server and client sources:
grep -rhoE '"cache_(server|client)_[a-z_]+"' src/subsystems/storage | sort -u
```

If anything changed, update `inventory/metrics.yaml` and this page together,
then run `make all`. The guard will point at every query that needs to follow.
