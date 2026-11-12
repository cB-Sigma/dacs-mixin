# Capacity

## The problem

A cache server knows its size limit: it is started with
`--sizeLimitBytes "$CACHESERVER_CACHE_SIZE_BYTES"`, derived from
`spec.serverSizeInGB` on the `Cache` resource. It exports how much it is using
(`cache_server_cache_size_bytes`) but **not the limit**. Once a minute it logs
`CacheSize`, `CacheSizeLimit` and `CacheSizePercentage`, and only the first of
those becomes a metric.

So "capacity used" as a percentage cannot be computed from DACS metrics alone,
and this mixin will not guess. Out of the box you get:

- bytes used per cache and per pod, on both cache dashboards;
- an empty "Capacity used" panel and a silent `DacsCacheServerNearCapacity`
  alert.

## Supplying capacity

Tell the mixin how large each cache server is by creating one
`dacs:cache_server:capacity_bytes` series per cache, labelled `namespace` and
`cache`. The value is the **per-server** limit in bytes, that is
`spec.serverSizeInGB * 1024^3`.

Pick whichever fits how you installed the mixin.

**Helm**

```yaml
rules:
  capacity:
    - namespace: cache-server
      cache: cache-sample
      serverSizeInGB: 100
```

**kubectl / kustomize**: copy
[`manifests/examples/capacity-prometheusrule.yaml`](../manifests/examples/capacity-prometheusrule.yaml),
add one rule per cache and apply it.

**jsonnet**

```jsonnet
(import 'github.com/cb-Sigma/dacs-mixin/mixin.libsonnet') + {
  _config+:: {
    cacheCapacities: [
      { namespace: 'cache-server', cache: 'cache-sample', serverSizeBytes: 100 * 1024 * 1024 * 1024 },
    ],
  },
}
```

All three produce the same thing, a recording rule:

```yaml
- record: dacs:cache_server:capacity_bytes
  expr: vector(107374182400)
  labels:
    namespace: cache-server
    cache: cache-sample
```

## Keeping it honest

- The number is yours to maintain. If you resize a cache and forget the rule,
  the percentage is wrong. To read the current values:

  ```sh
  kubectl get cache -A -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,SIZE_GB:.spec.serverSizeInGB
  ```
- With default eviction settings (`sizeThreshold: "90"`, `sizeTarget: "80"`) a
  busy cache lives between 80% and 90%. That is healthy; a cache is supposed to
  be full. The alert threshold is 95% for that reason.
- If DACS starts exporting the limit, the static rule can be replaced by the
  real metric without touching dashboards or alerts. That is tracked in the
  roadmap.
