# DacsClientDnsErrors

| | |
|---|---|
| Severity | warning (opt-in) |
| Rule group | `dacs-client` |
| Source | [`alerts/`](../../alerts/) |

## Meaning

A workload's cache client has been failing to resolve the DNS name of a cache
server pod (`getaddrinfo()` failed) for 15 minutes. The `hostname` label is
the name it could not resolve, of the form
`<cache>-<n>.<cache>.<namespace>.svc.cluster.local`.

This alert is part of the opt-in client rules. It needs cache client metrics
exported over OTLP; see [client-metrics.md](../client-metrics.md).

## Impact

The client cannot reach that server, so every key that hashes to it is read
from Blob Storage. Other servers are unaffected.

## Diagnosis

Clients get the server list from discovery: any cache server answers with
`<server count>` names built from its mounted discovery ConfigMap. A name that
does not resolve therefore means the list mentions a pod that has no DNS
record.

```sh
NS=cache-server; CACHE=cache-sample      # taken from the hostname label
kubectl get configmap -n $NS $CACHE-discovery-config -o yaml   # cache_server_count, endpoint format
kubectl get pods -n $NS -l dacs.azure.com/cache-name=$CACHE -o wide
kubectl get endpointslices -n $NS -l kubernetes.io/service-name=$CACHE
```

- **Pod missing or Pending:** the ConfigMap advertises more servers than are
  running. See [DacsCacheServersNotReady](DacsCacheServersNotReady.md). Common
  right after a scale-up, before the new pods have started.
- **Pod running, name still does not resolve:** cluster DNS. Test from a
  workload pod with `nslookup <hostname>` and check CoreDNS health and its
  logs.
- **Only one workload affected:** that pod's DNS configuration (`dnsPolicy`,
  custom `dnsConfig`, a different cluster or namespace without access to the
  cache's headless Service).

## Mitigation

- Get the missing cache server pods running, or scale the cache back to what
  the cluster can hold.
- Fix cluster DNS if that is the cause.
- Short bursts during scale-up are expected; lengthen
  `_config.clientDnsErrorsFor` if they page you.

## Tuning

`_config.clientDnsErrorsFor` (default `15m`), `clientRateInterval`, `clientCounterSuffix`.
