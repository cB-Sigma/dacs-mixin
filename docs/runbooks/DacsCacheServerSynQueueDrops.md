# DacsCacheServerSynQueueDrops

| | |
|---|---|
| Severity | warning |
| Rule group | `dacs-cache-saturation` |
| Source | [`alerts/`](../../alerts/) |

## Meaning

The kernel in the cache server pod has been dropping SYNs because a listener's
request (SYN) queue is full (`TcpExt.TCPReqQFullDrop`) for 10 minutes. This
happens when connection attempts arrive faster than handshakes complete and
SYN cookies are disabled or not applicable.

## Impact

Some connection attempts are silently dropped and retried by the client after
a retransmission timeout (about a second, then doubling). Clients see slow or
failed connects.

## Diagnosis

Set these first; the alert labels give you the values:

```sh
NS=cache-server        # {{ $labels.namespace }}
CACHE=cache-sample     # {{ $labels.cache }}
POD=cache-sample-0     # {{ $labels.pod }}, where the alert has one
```

- "SYN queue drops and SYN cookies" on **DACS / Cache servers**: cookies being
  sent without drops is the kernel coping; drops mean it is not.
- Check the relevant sysctls in the pod's network namespace:

  ```sh
  kubectl exec -n $NS $POD -c cacheserver -- sh -c \
    'cat /proc/sys/net/ipv4/tcp_max_syn_backlog /proc/sys/net/ipv4/tcp_syncookies /proc/sys/net/core/somaxconn'
  ```
- "New connections": look for a burst or a reconnect storm.

## Mitigation

- Reduce connection churn at the source, or add cache servers.
- Raise `net.ipv4.tcp_max_syn_backlog` and `net.core.somaxconn`, and the
  server backlog (`CACHESERVER_TCP_BACKLOG_SIZE` through `spec.env`).
- Enable `net.ipv4.tcp_syncookies` if your policy allows it.

## Tuning

`_config.synQueueDropsFor` (default `10m`).
