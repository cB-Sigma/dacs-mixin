// DACS monitoring mixin.
//
// Exposes the standard mixin fields:
//   grafanaDashboards  - four dashboards, keyed by file name
//   prometheusRules    - recording rules for cache server metrics
//   prometheusAlerts   - alerts for cache servers and the cache-controller
// and two opt-in fields for cache client (OTLP) metrics:
//   clientRules, clientAlerts
(import 'config.libsonnet') +
(import 'rules/rules.libsonnet') +
(import 'alerts/alerts.libsonnet') +
(import 'dashboards/dashboards.libsonnet')
