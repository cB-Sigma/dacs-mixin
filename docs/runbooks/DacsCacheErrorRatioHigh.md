# DacsCacheErrorRatioHigh / DacsCacheErrorRatioCritical

| | |
|---|---|
| Severity | warning / critical |
| Rule group | `dacs-cache-traffic` |
| Source | [`alerts/`](../../alerts/) |

## Meaning

The share of requests to this cache that ended in an error status is above 5%
for 10 minutes (warning) or above 25% for 5 minutes (critical).

Error statuses are `BadRequest`, `InternalError`, `NetworkError` and `NotSet`.
Cache misses (`InvalidTransition`) are not errors, and connections that close
before a request could be parsed (`request_type="Unknown"`) are excluded. The
alert stays silent below 0.1 requests per second.

## Impact

Failed downloads make clients fall back to Blob Storage; failed uploads leave
the cache unfilled, so later reads miss as well. Clients discard the
connection after an error and reconnect, which adds connection churn.

## Diagnosis

Set these first; the alert labels give you the values:

```sh
NS=cache-server        # {{ $labels.namespace }}
CACHE=cache-sample     # {{ $labels.cache }}
POD=cache-sample-0     # {{ $labels.pod }}, where the alert has one
```

Break the errors down:

```promql
sum by (pod, request_type, status) (
  rate(cache_server_request_counter{namespace="<ns>", cache="<cache>", status=~"BadRequest|InternalError|NetworkError|NotSet"}[5m])
)
```

```sh
kubectl logs -n $NS $POD -c cacheserver --tail=500 | grep -iE 'warn|error|critical'
```

| Status | Usual causes |
|---|---|
| `NetworkError` | The connection broke mid-request: workload pods being killed or preempted, node or CNI trouble, an egress limit (`spec.egressBandwidthLimitGbps`) making clients time out. Often one side of a wider incident. |
| `InternalError` | The server could not read or write cache files: disk errors, a full filesystem, or cache state that no longer matches the files on disk (the server then resets the entry). Check `dmesg` and the storage on the node. |
| `BadRequest` | A client sent an invalid offset/length or an over-long file name. Points at a client bug or a version mismatch between client library and server. |
| `NotSet` | The handler returned without a result. Unexpected; capture logs and report it upstream. |

One pod only: suspect that node's disk or network. All pods at once: suspect
the clients, a rollout, or the network.

## Mitigation

- Single bad server: delete the pod so it restarts. If the node's storage is
  failing, cordon the node and let the controller reschedule.
- Client-side cause: fix or roll back the workload or client library.
- `NetworkError` during node drains or spot evictions is expected in bursts;
  the alert's `for` should absorb it.

## Tuning

`_config.errorRatioWarningThreshold` (0.05), `errorRatioCriticalThreshold` (0.25), `errorRatioMinRequestRate` (0.1/s), `errorRatioWarningFor`, `errorRatioCriticalFor`, and `errorStatuses`.
