# DacsControllerReconcileErrors

| | |
|---|---|
| Severity | warning |
| Rule group | `dacs-controller` |
| Source | [`alerts/`](../../alerts/) |

## Meaning

More than 10% of reconciles by the `cache` controller have returned an error
for 15 minutes. controller-runtime retries failed reconciles with backoff, so
this is a persistent failure, not a blip.

## Impact

At least one `Cache` resource is not converging: changes to it (size, replica
count, image, eviction settings) are not applied, and its status may be stale.
Running cache servers keep serving.

## Diagnosis

```sh
NS=cache-server   # namespace of the DACS Helm release
kubectl logs -n $NS -l app.kubernetes.io/name=dacs --tail=500 | grep -iE 'error|failed'
kubectl get cache -A
kubectl describe cache -n <namespace> <name>     # conditions and events
```

The controller logs the namespace and name of the Cache it failed on.
Frequent causes:

- the Kubernetes API is rejecting or throttling requests ("Kubernetes API
  requests by code" on **DACS / Controller**: 403, 409, 429, 5xx);
- RBAC was changed and the manager can no longer manage StatefulSets,
  Services, ConfigMaps, Pods or Nodes;
- a Cache spec the reconciler cannot realise (admission webhook disabled, so
  invalid specs get through);
- a StatefulSet change that Kubernetes refuses to apply in place.

## Mitigation

- Fix the spec of the offending Cache, or restore the missing RBAC.
- If the API server is the problem, the errors clear when it recovers.
- If the error follows a DACS upgrade, check CRD and controller versions match
  and roll back if necessary.

## Tuning

`_config.controllerReconcileErrorRatioThreshold` (0.1) and `controllerReconcileErrorsFor` (`15m`).
