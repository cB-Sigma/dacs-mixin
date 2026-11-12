{
  local c = $._config,
  local runbook(name) = c.runbookURLPattern % name,

  prometheusAlerts+:: {
    groups+: [
      {
        name: 'dacs-controller',
        rules: [
          {
            alert: 'DacsControllerDown',
            expr: |||
              absent(up{%(controllerSelector)s} == 1)
            ||| % c,
            'for': c.controllerDownFor,
            labels: { severity: 'warning' },
            annotations: {
              summary: 'DACS cache-controller is down or not scraped.',
              description: 'No healthy cache-controller target has been scraped. Existing caches keep serving, but Cache resources are not reconciled, scaled or rescheduled.',
              runbook_url: runbook('DacsControllerDown'),
            },
          },
          {
            alert: 'DacsControllerReconcileErrors',
            expr: |||
              sum by (namespace, controller) (
                rate(controller_runtime_reconcile_errors_total{%(controllerSelector)s, controller="%(controllerName)s"}[5m])
              )
              /
              sum by (namespace, controller) (
                rate(controller_runtime_reconcile_total{%(controllerSelector)s, controller="%(controllerName)s"}[5m])
              )
              > %(controllerReconcileErrorRatioThreshold)g
            ||| % c,
            'for': c.controllerReconcileErrorsFor,
            labels: { severity: 'warning' },
            annotations: {
              summary: 'DACS cache-controller reconciles are failing.',
              description: '{{ $value | humanizePercentage }} of reconciles by controller "{{ $labels.controller }}" in namespace {{ $labels.namespace }} returned an error.',
              runbook_url: runbook('DacsControllerReconcileErrors'),
            },
          },
          {
            alert: 'DacsControllerReconcilePanics',
            expr: |||
              sum by (namespace, controller) (
                increase(controller_runtime_reconcile_panics_total{%(controllerSelector)s}[15m])
              ) > 0
            ||| % c,
            labels: { severity: 'warning' },
            annotations: {
              summary: 'DACS cache-controller reconciler panicked.',
              description: 'Controller "{{ $labels.controller }}" in namespace {{ $labels.namespace }} recovered from {{ $value | printf "%.0f" }} panic(s) in the last 15 minutes.',
              runbook_url: runbook('DacsControllerReconcilePanics'),
            },
          },
          {
            alert: 'DacsControllerWorkqueueStalled',
            expr: |||
              max by (namespace, name) (
                workqueue_longest_running_processor_seconds{%(controllerSelector)s}
              ) > %(controllerWorkqueueStalledSeconds)g
            ||| % c,
            'for': c.controllerWorkqueueStalledFor,
            labels: { severity: 'warning' },
            annotations: {
              summary: 'DACS cache-controller has a stuck reconcile.',
              description: 'A worker of workqueue "{{ $labels.name }}" in namespace {{ $labels.namespace }} has been processing a single item for {{ $value | humanizeDuration }}.',
              runbook_url: runbook('DacsControllerWorkqueueStalled'),
            },
          },
        ],
      },
    ],
  },
}
