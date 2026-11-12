// Kubernetes objects rendered into manifests/.
{
  local labels = {
    'app.kubernetes.io/name': 'dacs-mixin',
    'app.kubernetes.io/part-of': 'dacs',
  },

  prometheusRule(name, groups):: {
    apiVersion: 'monitoring.coreos.com/v1',
    kind: 'PrometheusRule',
    metadata: { name: name, labels: labels },
    spec: { groups: groups },
  },

  // Cache server pods carry `app: cacheserver` and expose a container port
  // named `metrics`. Upstream DACS ships no monitor for them.
  cacheServerPodMonitor:: {
    apiVersion: 'monitoring.coreos.com/v1',
    kind: 'PodMonitor',
    metadata: { name: 'dacs-cache-server', labels: labels },
    spec: {
      namespaceSelector: { any: true },
      selector: { matchLabels: { app: 'cacheserver' } },
      podMetricsEndpoints: [
        {
          port: 'metrics',
          path: '/metrics',
          interval: '30s',
          relabelings: [
            // Fixed job name so rules and dashboards do not depend on the monitor's namespace/name.
            { action: 'replace', targetLabel: 'job', replacement: 'dacs-cache-server' },
            // The StatefulSet is named after the Cache; used as a fallback.
            { action: 'replace', sourceLabels: ['__meta_kubernetes_pod_controller_name'], targetLabel: 'cache' },
            // Preferred source: the label the cache-controller sets on every cache server pod.
            { action: 'replace', sourceLabels: ['__meta_kubernetes_pod_label_dacs_azure_com_cache_name'], regex: '(.+)', targetLabel: 'cache' },
          ],
        },
      ],
    },
  },

  // The controller serves metrics over HTTPS behind Kubernetes authn/authz.
  // The Prometheus service account needs `get` on the /metrics
  // nonResourceURL (upstream ships a metrics-reader ClusterRole for this).
  controllerServiceMonitor:: {
    apiVersion: 'monitoring.coreos.com/v1',
    kind: 'ServiceMonitor',
    metadata: { name: 'dacs-controller', labels: labels },
    spec: {
      namespaceSelector: { any: true },
      selector: {
        matchLabels: {
          'app.kubernetes.io/name': 'dacs',
          'control-plane': 'controller-manager',
        },
      },
      endpoints: [
        {
          port: 'https',
          path: '/metrics',
          scheme: 'https',
          interval: '30s',
          bearerTokenFile: '/var/run/secrets/kubernetes.io/serviceaccount/token',
          // The controller uses a self-signed certificate unless cert-manager is enabled.
          tlsConfig: { insecureSkipVerify: true },
          relabelings: [
            { action: 'replace', targetLabel: 'job', replacement: 'dacs-controller' },
          ],
        },
      ],
    },
  },

  dashboardConfigMap(file, dashboard):: {
    apiVersion: 'v1',
    kind: 'ConfigMap',
    metadata: {
      name: 'dacs-dashboard-' + std.strReplace(std.strReplace(file, 'dacs-', ''), '.json', ''),
      labels: labels { grafana_dashboard: '1' },
    },
    data: { [file]: std.manifestJsonEx(dashboard, '  ') + '\n' },
  },
}
