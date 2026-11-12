// Renders every generated file in the repository. Run through `make render`:
//   jsonnet -J . -S -c -m <out dir> lib/render.jsonnet
local mixin = import '../mixin.libsonnet';
local k8s = import 'k8s.libsonnet';

local header = '# Rendered from jsonnet by `make render`. Do not edit by hand.\n';
local yaml(value) = header + std.manifestYamlDoc(value, indent_array_in_object=true, quote_keys=false);
local json(value) = std.manifestJsonEx(value, '  ');

local withPrefix(groups, prefix) = { groups: [g for g in groups.groups if std.startsWith(g.name, prefix)] };

local dashboards = mixin.grafanaDashboards;
local rules = mixin.prometheusRules;
local alerts = mixin.prometheusAlerts;
local clientRules = mixin.clientRules;
local clientAlerts = mixin.clientAlerts;

// Standard mixin outputs.
{ ['dashboards_out/' + file]: json(dashboards[file]) for file in std.objectFields(dashboards) }
{
  'rules_out/prometheus_rules.yaml': yaml(rules),
  'rules_out/prometheus_alerts.yaml': yaml(alerts),
  'rules_out/prometheus_client_rules.yaml': yaml(clientRules),
  'rules_out/prometheus_client_alerts.yaml': yaml(clientAlerts),
}
// Kubernetes manifests.
{
  'manifests/prometheusrule.yaml': yaml(k8s.prometheusRule('dacs-mixin', rules.groups + alerts.groups)),
  'manifests/podmonitor-cache-server.yaml': yaml(k8s.cacheServerPodMonitor),
  'manifests/servicemonitor-controller.yaml': yaml(k8s.controllerServiceMonitor),
  'manifests/client/prometheusrule-client.yaml': yaml(k8s.prometheusRule('dacs-mixin-client', clientRules.groups + clientAlerts.groups)),
}
{
  ['manifests/dashboard-' + std.strReplace(std.strReplace(file, 'dacs-', ''), '.json', '') + '.yaml']: yaml(k8s.dashboardConfigMap(file, dashboards[file]))
  for file in std.objectFields(dashboards)
}
// Files consumed by the Helm chart through .Files.Get.
{ ['charts/dacs-mixin/files/dashboards/' + file]: json(dashboards[file]) for file in std.objectFields(dashboards) }
{
  'charts/dacs-mixin/files/rules/cache-rules.yaml': yaml(rules),
  'charts/dacs-mixin/files/rules/cache-alerts.yaml': yaml(withPrefix(alerts, 'dacs-cache-')),
  'charts/dacs-mixin/files/rules/controller-alerts.yaml': yaml(withPrefix(alerts, 'dacs-controller')),
  'charts/dacs-mixin/files/rules/client-rules.yaml': yaml(clientRules),
  'charts/dacs-mixin/files/rules/client-alerts.yaml': yaml(clientAlerts),
}
