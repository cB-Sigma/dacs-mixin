# DacsControllerDown

| | |
|---|---|
| Severity | warning |
| Rule group | `dacs-controller` |
| Source | [`alerts/`](../../alerts/) |

## Meaning

For 10 minutes Prometheus has not had a single healthy scrape target for the
cache-controller manager (`job="dacs-controller"`). Either the controller is
not running, or it is running and Prometheus cannot scrape it.

The alert carries no namespace or pod labels because it is built on `absent()`.

## Impact

The controller is not in the data path: existing caches keep serving. While it
is down, though, `Cache` resources are not reconciled (no creation, resizing or
status updates), dynamic scaling stops, and in host-storage mode cache server
pods are **not scheduled**, because they use `schedulerName: cache-controller`.
A cache server pod that dies during the outage stays Pending.

## Diagnosis

```sh
NS=cache-server   # namespace of the DACS Helm release
kubectl get pods -n $NS -l app.kubernetes.io/name=dacs -o wide
kubectl describe pods -n $NS -l app.kubernetes.io/name=dacs
kubectl logs -n $NS -l app.kubernetes.io/name=dacs --tail=200
```

If the pod is Running and Ready, the problem is the scrape. In Prometheus,
open Status > Targets and read the error for `dacs-controller`:

- **No target at all:** the ServiceMonitor is not selected by your Prometheus
  (missing `release:` style label), or the upstream chart was installed with
  `metrics.enable=false`, or the Service labels differ from the selector.
- **401 / 403:** the endpoint requires Kubernetes authentication and
  authorization. Bind the upstream `metrics-reader` ClusterRole (GET on
  `/metrics`) to the Prometheus service account.
- **TLS errors:** the certificate is self-signed unless cert-manager is
  enabled; the shipped ServiceMonitor uses `insecureSkipVerify: true` for that
  reason.
- **Connection refused / timeout:** a NetworkPolicy, or the manager was started
  with `--metrics-bind-address=0`.

## Mitigation

- Controller crash-looping: read the logs; a bad feature gate, missing CRD or
  webhook certificate problem is typical after an upgrade. Roll back the
  release if needed.
- Scrape problem: fix selection, RBAC or TLS as above.
- If you do not run the controller's metrics endpoint on purpose, disable the
  controller alerts (`rules.controller.alerts=false` in the Helm chart).

## Tuning

`_config.controllerDownFor` (default `10m`) and `controllerSelector`.
