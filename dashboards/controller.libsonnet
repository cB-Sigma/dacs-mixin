local g = import 'g.libsonnet';

{
  local c = $._config,
  local sel = '%(controllerSelector)s, namespace=~"$namespace", pod=~"$pod"' % c,

  local rate(metric, agg, matchers='') =
    'sum by (%s) (rate(%s{%s%s}[$__rate_interval]))' % [agg, metric, sel, if matchers == '' then '' else ', ' + matchers],
  local quantile(qt, metric, agg) = |||
    histogram_quantile(%(qt)s, sum by (%(agg)s, le) (
      rate(%(metric)s_bucket{%(sel)s}[$__rate_interval])
    ))
  ||| % { qt: qt, metric: metric, sel: sel, agg: agg },

  grafanaDashboards+:: {
    'dacs-controller.json':
      g.dashboard(
        'DACS / Controller',
        c.dashboardUIDs.controller,
        'cache-controller manager health from its standard controller-runtime metrics: reconciles, workqueue, admission webhook, Kubernetes API client and process resources.',
        c,
        [
          g.datasourceVar,
          g.queryVar('namespace', 'Namespace', 'label_values(controller_runtime_reconcile_total{%(controllerSelector)s}, namespace)' % c),
          g.queryVar('pod', 'Pod', 'label_values(controller_runtime_reconcile_total{%(controllerSelector)s, namespace=~"$namespace"}, pod)' % c),
        ],
        [
          {
            title: 'At a glance',
            height: 5,
            panels: [
              g.stat(
                'Controllers up',
                'cache-controller pods whose metrics endpoint was scraped successfully.',
                'short',
                [g.target('sum(up{%s})' % sel)],
                steps=[[null, 'red'], [1, 'green']],
                graph=false,
              ) { w:: 6 },
              g.stat(
                'Reconciles',
                'Reconcile rate across all controllers in the manager.',
                'ops',
                [g.target('sum(rate(controller_runtime_reconcile_total{%s}[$__rate_interval]))' % sel)],
              ) { w:: 6 },
              g.stat(
                'Reconcile error ratio',
                'Share of reconciles that returned an error.',
                'percentunit',
                [
                  g.target(
                    'sum(rate(controller_runtime_reconcile_errors_total{%(s)s}[$__rate_interval])) / sum(rate(controller_runtime_reconcile_total{%(s)s}[$__rate_interval]))' % { s: sel }
                  ),
                ],
                steps=[[null, 'green'], [0.01, 'orange'], [0.1, 'red']],
                decimals=2,
              ) { w:: 6 },
              g.stat(
                'Workqueue depth',
                'Items waiting in the controller workqueues.',
                'short',
                [g.target('sum(workqueue_depth{%s})' % sel)],
                steps=[[null, 'green'], [10, 'orange'], [100, 'red']],
              ) { w:: 6 },
            ],
          },
          {
            title: 'Reconciliation',
            panels: [
              g.timeseries(
                'Reconciles by result',
                'Reconcile rate by controller and result: success, error, requeue or requeue_after. The Cache reconciler is registered as controller "%s".' % c.controllerName,
                'ops',
                [g.target(rate('controller_runtime_reconcile_total', 'controller, result'), '{{controller}} {{result}}')],
                stack=true,
                min=0,
              ),
              g.timeseries(
                'Reconcile errors, panics and timeouts',
                'Reconciles that returned an error, returned a terminal (non-retried) error, panicked or timed out.',
                'ops',
                [
                  g.target(rate('controller_runtime_reconcile_errors_total', 'controller'), '{{controller}} errors'),
                  g.target(rate('controller_runtime_terminal_reconcile_errors_total', 'controller'), '{{controller}} terminal errors'),
                  g.target(rate('controller_runtime_reconcile_panics_total', 'controller'), '{{controller}} panics'),
                  g.target(rate('controller_runtime_reconcile_timeouts_total', 'controller'), '{{controller}} timeouts'),
                ],
                min=0,
              ),
              g.timeseries(
                'Reconcile duration',
                'Time spent in a single reconcile.',
                's',
                [
                  g.target(quantile('0.50', 'controller_runtime_reconcile_time_seconds', 'controller'), '{{controller}} p50'),
                  g.target(quantile('0.99', 'controller_runtime_reconcile_time_seconds', 'controller'), '{{controller}} p99'),
                ],
                min=0,
                fill=0,
              ),
              g.timeseries(
                'Workers',
                'Workers currently reconciling against the configured maximum.',
                'short',
                [
                  g.target('sum by (controller) (controller_runtime_active_workers{%s})' % sel, '{{controller}} active'),
                  g.target('sum by (controller) (controller_runtime_max_concurrent_reconciles{%s})' % sel, '{{controller}} max'),
                ],
                min=0,
                decimals=0,
                fill=0,
              ),
            ],
          },
          {
            title: 'Workqueue',
            panels: [
              g.timeseries(
                'Depth',
                'Items waiting to be reconciled.',
                'short',
                [g.target('sum by (name) (workqueue_depth{%s})' % sel, '{{name}}')],
                min=0,
              ) { w:: 8 },
              g.timeseries(
                'Adds and retries',
                'Items added to the queue and items re-queued after a failed reconcile.',
                'ops',
                [
                  g.target(rate('workqueue_adds_total', 'name'), '{{name}} adds'),
                  g.target(rate('workqueue_retries_total', 'name'), '{{name}} retries'),
                ],
                min=0,
              ) { w:: 8 },
              g.timeseries(
                'Time in queue and processing time (p99)',
                'How long items wait before a worker picks them up, and how long processing takes.',
                's',
                [
                  g.target(quantile('0.99', 'workqueue_queue_duration_seconds', 'name'), '{{name}} queue'),
                  g.target(quantile('0.99', 'workqueue_work_duration_seconds', 'name'), '{{name}} work'),
                ],
                min=0,
                fill=0,
              ) { w:: 8 },
              g.timeseries(
                'Unfinished work',
                'Seconds of work in progress that has not completed yet, and the age of the longest-running reconcile. A steadily rising line is a stuck worker.',
                's',
                [
                  g.target('max by (name) (workqueue_unfinished_work_seconds{%s})' % sel, '{{name}} unfinished'),
                  g.target('max by (name) (workqueue_longest_running_processor_seconds{%s})' % sel, '{{name}} longest running'),
                ],
                min=0,
                fill=0,
              ) { w:: 24 },
            ],
          },
          {
            title: 'Admission webhook and API client',
            panels: [
              g.timeseries(
                'Webhook requests by code',
                'Admission requests served by the Cache defaulting and validating webhooks, by HTTP status code. Empty when the webhook is disabled.',
                'reqps',
                [g.target(rate('controller_runtime_webhook_requests_total', 'webhook, code'), '{{webhook}} {{code}}')],
                min=0,
              ) { w:: 8 },
              g.timeseries(
                'Webhook latency p99',
                'p99 time to answer an admission request.',
                's',
                [g.target(quantile('0.99', 'controller_runtime_webhook_latency_seconds', 'webhook'), '{{webhook}}')],
                min=0,
                fill=0,
              ) { w:: 8 },
              g.timeseries(
                'Kubernetes API requests by code',
                'Requests the controller made to the Kubernetes API server, by status code and method. 429 and 5xx responses slow reconciliation down.',
                'reqps',
                [g.target(rate('rest_client_requests_total', 'code, method'), '{{method}} {{code}}')],
                min=0,
              ) { w:: 8 },
            ],
          },
          {
            title: 'Process',
            panels: [
              g.timeseries(
                'CPU',
                'CPU cores used by the controller process.',
                'short',
                [g.target('sum by (pod) (rate(process_cpu_seconds_total{%s}[$__rate_interval]))' % sel, '{{pod}}')],
                min=0,
              ) { w:: 8 },
              g.timeseries(
                'Memory',
                'Resident memory of the controller process.',
                'bytes',
                [g.target('max by (pod) (process_resident_memory_bytes{%s})' % sel, '{{pod}}')],
                min=0,
              ) { w:: 8 },
              g.timeseries(
                'Goroutines',
                'Goroutines in the controller process. Unbounded growth points to a leak.',
                'short',
                [g.target('max by (pod) (go_goroutines{%s})' % sel, '{{pod}}')],
                min=0,
              ) { w:: 8 },
            ],
          },
        ],
      ),
  },
}
