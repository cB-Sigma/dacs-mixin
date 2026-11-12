# DacsCacheHitRatioLow

| | |
|---|---|
| Severity | warning |
| Rule group | `dacs-cache-traffic` |
| Source | [`alerts/`](../../alerts/) |

## Meaning

For 30 minutes fewer than half of the download requests to this cache were
hits, while the cache was receiving more than one download per second.

Hits and misses come from `cache_server_request_counter{request_type="Download"}`:
`status="Success"` is a hit, `status="InvalidTransition"` is how the server
reports "not in cache".

## Impact

Most reads are being served from Azure Blob Storage instead of local NVMe:
slower data loading, more Blob egress and transactions. Nothing is failing.

A low ratio is **normal** while a cache warms up: first epoch over a new
dataset, a new model being pulled for the first time, or just after the cache
was created.

## Diagnosis

Set these first; the alert labels give you the values:

```sh
NS=cache-server        # {{ $labels.namespace }}
CACHE=cache-sample     # {{ $labels.cache }}
POD=cache-sample-0     # {{ $labels.pod }}, where the alert has one
```

Open the **DACS / Overview** and **DACS / Cache servers** dashboards for the
cache, then work through:

1. **Is it warming up?** In "Download hits and misses", misses that fall over
   time while "Bytes written into cache" is busy means the cache is filling.
   Wait.
2. **Did the server set change?** Keys are spread by hashing over the server
   list, so scaling, a rescheduled pod or a restart without a usable snapshot
   empties part of the keyspace.

   ```sh
   kubectl get cache -n $NS $CACHE
   kubectl get pods -n $NS -l dacs.azure.com/cache-name=$CACHE -o wide   # AGE, RESTARTS
   ```

   "Hit ratio by pod" singles out the servers that are refilling.
3. **Is the cache too small?** If space used sits at the eviction threshold and
   the ratio never recovers, the working set does not fit and chunks are
   evicted before they are read again.

   ```sh
   kubectl get cache -n $NS $CACHE -o jsonpath='{.spec.serverSizeInGB}{"\n"}{.spec.eviction}{"\n"}'
   ```
4. **Are fills failing?** After a miss, the client that holds the lock uploads
   the chunk. Look at Upload requests by status:

   ```promql
   sum by (status) (rate(cache_server_request_counter{namespace="<ns>", cache="<cache>", request_type="Upload"}[5m]))
   ```

   No successful uploads after misses means the cache never fills; check
   [DacsCacheErrorRatioHigh](DacsCacheErrorRatioHigh.md) and client logs.
5. **Is the workload cacheable at all?** One-pass reads over data larger than
   the cache will never hit.

## Mitigation

- Warming up: nothing to do.
- Too small: raise `spec.serverSizeInGB` if the NVMe has room, or add servers.
- Churn: avoid frequent scaling. For dynamic scaling, the stabilization
  windows live in the controller's operator configuration; see the upstream
  scaling documentation.
- Uncacheable workload: raise the threshold or silence the alert for that
  cache.

## Tuning

`_config.hitRatioLowThreshold` (0.5), `hitRatioLowMinDownloadRate` (1 download/s) and `hitRatioLowFor` (`30m`).
