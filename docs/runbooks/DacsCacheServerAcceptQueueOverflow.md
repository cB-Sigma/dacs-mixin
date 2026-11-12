# DacsCacheServerAcceptQueueOverflow

| | |
|---|---|
| Severity | warning |
| Rule group | `dacs-cache-saturation` |
| Source | [`alerts/`](../../alerts/) |

## Meaning

The kernel's `TcpExt.ListenOverflows` counter in the cache server pod has been
increasing for 10 minutes: completed TCP handshakes are arriving faster than
the server calls `accept()`, and the accept queue is full.

The cache server samples the counter once a minute, so the rate is coarse.

## Impact

New client connections are dropped or delayed until the client retransmits;
clients see connect timeouts and multi-second stalls. Established connections
are unaffected.

## Diagnosis

Set these first; the alert labels give you the values:

```sh
NS=cache-server        # {{ $labels.namespace }}
CACHE=cache-sample     # {{ $labels.cache }}
POD=cache-sample-0     # {{ $labels.pod }}, where the alert has one
```

On **DACS / Cache servers**, section "Connections and accept queue":

- "New connections": a spike means clients are opening connections in bulk,
  for example many workers starting at once, or connections being discarded
  and re-opened after errors.
- "Listen backlog": the backlog the server asked for (4096 unless
  `CACHESERVER_TCP_BACKLOG_SIZE` is set). The kernel caps it at
  `net.core.somaxconn`:

  ```sh
  kubectl exec -n $NS $POD -c cacheserver -- cat /proc/sys/net/core/somaxconn
  ```
- "In-flight requests" and pod CPU: a server that is CPU-starved or throttled
  accepts slowly.

```sh
kubectl top pod -n $NS $POD
kubectl logs -n $NS $POD -c cacheserver --tail=200 | grep -i accept
```

## Mitigation

- Spread the load: add cache servers.
- Give the server more CPU (`spec.cpuLimit`) if it is throttled.
- Raise the backlog through `spec.env` (`CACHESERVER_TCP_BACKLOG_SIZE`) and
  make sure `net.core.somaxconn` on the nodes is at least as large.
- If a client is churning connections because of errors, fix that first
  ([DacsCacheErrorRatioHigh](DacsCacheErrorRatioHigh.md)).

## Tuning

`_config.acceptQueueOverflowFor` (default `10m`).
