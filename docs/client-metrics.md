# Cache client metrics

The **DACS / Clients** dashboard and the opt-in client rules depend on metrics
emitted by the DACS cache client library inside your workloads. They behave
differently from everything else in this mixin, and **this part of the mixin
is the least verified**. Read this page before relying on it.

## What the source says

(DACS commit `27ec57c`; details and line references in
[metrics.md](metrics.md#cache-client).)

- Client metrics are **off by default**. They are enabled per process with
  environment variables:

  | Variable | Default | |
  |---|---|---|
  | `STORAGE_METRIC_OTEL_ENABLED` | `false` | Turns OTLP export on |
  | `STORAGE_METRIC_OTEL_ENDPOINT` | `http://localhost:4318/v1/metrics` | OTLP/HTTP metrics endpoint |
  | `STORAGE_METRIC_OTEL_SERVICENAME` | `dacs` | `service.name` resource attribute |
  | `STORAGE_METRIC_OTEL_EXPORT_INTERVAL_MINS` | `5` | Export interval, whole minutes |

- They are **pushed** over OTLP/HTTP. There is nothing to scrape, so no
  PodMonitor can collect them.
- Data points carry `pid` and, in distributed training, `rank`. The resource
  carries `service.name` and optionally `process.rank`. **Nothing identifies
  the pod, the namespace or the cache.**

## What this mixin assumes

| Assumption | Config knob | Default |
|---|---|---|
| Monotonic counters gain a `_total` suffix on the way into Prometheus | `clientCounterSuffix` | `_total` |
| `service.name` ends up in the `job` label | `clientWorkloadLabel` | `job` |
| No extra matchers are needed to find the series | `clientSelector` | empty |
| Rates need a long window because of the 5-minute export interval | `clientRateInterval` | `15m` |

These follow the OpenTelemetry-to-Prometheus compatibility rules that both
Prometheus' OTLP endpoint and the Collector's Prometheus exporters implement
by default. They were **not** tested against a live pipeline. If your pipeline
is configured differently (for example `add_metric_suffixes: false`, or a
metric namespace prefix), change the knobs and run `make render`.

To see what you actually have:

```promql
count by (__name__) ({__name__=~"cache_client_.+"})
```

## Getting the metrics into Prometheus

Either of these should work; neither was run as part of this project.

**Prometheus as the OTLP receiver.** Start Prometheus with
`--web.enable-otlp-receiver` and point the clients at it:

```sh
STORAGE_METRIC_OTEL_ENABLED=true
STORAGE_METRIC_OTEL_ENDPOINT=http://<prometheus>:9090/api/v1/otlp/v1/metrics
STORAGE_METRIC_OTEL_SERVICENAME=<workload name>
STORAGE_METRIC_OTEL_EXPORT_INTERVAL_MINS=1
```

**An OpenTelemetry Collector in between.** Receive OTLP, add Kubernetes
metadata, and expose a scrape endpoint or remote-write:

```yaml
receivers:
  otlp:
    protocols:
      http:
        endpoint: 0.0.0.0:4318
processors:
  k8sattributes: {}        # adds k8s.pod.name, k8s.namespace.name, ...
exporters:
  prometheus:
    endpoint: 0.0.0.0:8889
    resource_to_telemetry_conversion:
      enabled: true
service:
  pipelines:
    metrics:
      receivers: [otlp]
      processors: [k8sattributes]
      exporters: [prometheus]
```

## Pitfalls

- **Use one service name per workload.** With the default `dacs` every
  workload in the cluster reports as the same `job`, and the dashboard cannot
  tell them apart.
- **Series can collide.** Two pods with the same service name and the same
  `pid` (very common in containers) produce identical label sets unless your
  pipeline adds something that distinguishes them, such as the pod name from
  the Collector's `k8sattributes` processor. Colliding counters produce
  garbage rates. Check that
  `count by (job, pid) (cache_client_download_requests_total)` never exceeds
  the number of series you expect.
- **Rates need long windows.** At the default 5-minute export interval a
  `[5m]` rate has at most one sample and returns nothing. The dashboard has a
  "Rate window" variable (default `15m`), and the client rules use
  `clientRateInterval`. Lowering the export interval to 1 minute makes
  everything more responsive.
- **Counters appear late.** A counter series is created on its first
  increment, already non-zero. Prometheus cannot see that first step, so
  `increase()` under-reports brand-new series. `DacsClientDnsErrors` therefore
  fires on continued errors, not on the very first one.
- **Short-lived processes** flush on exit, but a process that is killed loses
  whatever it had not exported yet.
- **There is no cache label.** A workload that uses two caches reports them
  combined. Per-cache numbers come from the cache server side, which is what
  the Overview and Cache servers dashboards use.

## What you get without client metrics

Everything except the Clients dashboard and `DacsClientDnsErrors`. Hit ratio,
traffic, bytes, latency and errors are all available per cache from the cache
servers, which are scraped directly and whose metric names are verified.
