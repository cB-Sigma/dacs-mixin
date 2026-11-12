{
  local c = $._config,
  local runbook(name) = c.runbookURLPattern % name,
  local sel = if c.clientSelector == '' then '' else '{%s}' % c.clientSelector,

  // Opt-in. Kept out of prometheusAlerts because cache client metrics are
  // pushed over OTLP and their Prometheus names depend on the pipeline.
  clientAlerts+:: {
    groups+: [
      {
        name: 'dacs-client',
        rules: [
          {
            alert: 'DacsClientDnsErrors',
            expr: |||
              sum by (%(clientWorkloadLabel)s, hostname) (
                increase(cache_client_dns_errors%(clientCounterSuffix)s%(sel)s[%(clientRateInterval)s])
              ) > 0
            ||| % (c { sel: sel }),
            'for': c.clientDnsErrorsFor,
            labels: { severity: 'warning' },
            annotations: {
              summary: 'DACS clients cannot resolve a cache server.',
              description: 'Workload {{ $labels.%(clientWorkloadLabel)s }} failed to resolve cache server {{ $labels.hostname }} {{ $value | printf "%%.0f" }} times in the last %(clientRateInterval)s. Requests for keys owned by that server fall through to Blob Storage.' % c,
              runbook_url: runbook('DacsClientDnsErrors'),
            },
          },
        ],
      },
    ],
  },
}
