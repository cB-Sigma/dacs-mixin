#!/usr/bin/env python3
"""Render the Helm chart and compare it with the jsonnet-rendered artifacts.

Checks, using `helm template`:
  * default values: the PrometheusRule contains exactly the default rule and
    alert groups, the monitors match manifests/, and every dashboard ConfigMap
    embeds the same JSON as dashboards_out/;
  * ci/all-values.yaml: client groups and capacity rules appear, labels and
    overrides are applied;
  * every toggle switched off: nothing is rendered.
"""

import json
import pathlib
import subprocess
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
CHART = ROOT / 'charts/dacs-mixin'

errors = []


def expect(cond, msg):
    if not cond:
        errors.append(msg)


def template(*args):
    out = subprocess.run(
        ['helm', 'template', 'dacs-mixin', str(CHART), '--namespace', 'monitoring', *args],
        check=True, capture_output=True, text=True,
    ).stdout
    return [d for d in yaml.safe_load_all(out) if d]


def by_kind(docs, kind):
    return [d for d in docs if d['kind'] == kind]


def groups(name):
    return yaml.safe_load((ROOT / 'rules_out' / name).read_text())['groups']


def manifest(name):
    return yaml.safe_load((ROOT / 'manifests' / name).read_text())


def check_defaults():
    docs = template()
    kinds = sorted(d['kind'] for d in docs)
    expect(kinds == ['ConfigMap'] * 4 + ['PodMonitor', 'PrometheusRule', 'ServiceMonitor'],
           'default values: unexpected objects %s' % kinds)

    rule = by_kind(docs, 'PrometheusRule')[0]
    want = groups('prometheus_rules.yaml') + groups('prometheus_alerts.yaml')
    expect(rule['spec']['groups'] == want, 'default values: PrometheusRule groups differ from rules_out/')
    expect(rule['spec']['groups'] == manifest('prometheusrule.yaml')['spec']['groups'],
           'default values: PrometheusRule groups differ from manifests/prometheusrule.yaml')

    pm = by_kind(docs, 'PodMonitor')[0]
    expect(pm['spec'] == manifest('podmonitor-cache-server.yaml')['spec'],
           'default values: PodMonitor spec differs from manifests/podmonitor-cache-server.yaml')
    sm = by_kind(docs, 'ServiceMonitor')[0]
    expect(sm['spec'] == manifest('servicemonitor-controller.yaml')['spec'],
           'default values: ServiceMonitor spec differs from manifests/servicemonitor-controller.yaml')

    seen = set()
    for cm in by_kind(docs, 'ConfigMap'):
        expect(cm['metadata']['labels'].get('grafana_dashboard') == '1',
               '%s: missing grafana_dashboard label' % cm['metadata']['name'])
        for file, content in cm['data'].items():
            seen.add(file)
            source = json.loads((ROOT / 'dashboards_out' / file).read_text())
            expect(json.loads(content) == source, 'default values: %s differs from dashboards_out/' % file)
    expect(seen == {p.name for p in (ROOT / 'dashboards_out').glob('*.json')},
           'default values: dashboards in chart %s do not match dashboards_out/' % sorted(seen))
    for d in docs:
        expect(d['metadata']['namespace'] == 'monitoring', '%s: wrong namespace' % d['metadata']['name'])


def check_all_values():
    docs = template('-f', str(CHART / 'ci/all-values.yaml'))
    rule = by_kind(docs, 'PrometheusRule')[0]
    names = [g['name'] for g in rule['spec']['groups']]
    for g in groups('prometheus_client_rules.yaml') + groups('prometheus_client_alerts.yaml'):
        expect(g in rule['spec']['groups'], 'all values: client group %s missing' % g['name'])
    expect('dacs-cache-capacity.rules' in names, 'all values: capacity group missing')
    capacity = [g for g in rule['spec']['groups'] if g['name'] == 'dacs-cache-capacity.rules'][0]['rules']
    expect(capacity == [
        {'record': 'dacs:cache_server:capacity_bytes', 'expr': 'vector(107374182400)',
         'labels': {'namespace': 'cache-server', 'cache': 'cache-sample'}},
        {'record': 'dacs:cache_server:capacity_bytes', 'expr': 'vector(1932735283200)',
         'labels': {'namespace': 'ml', 'cache': 'weights'}},
    ], 'all values: capacity rules are wrong: %s' % capacity)
    expect(rule['metadata']['labels'].get('role') == 'alert-rules', 'all values: rules.labels not applied')
    for d in docs:
        expect(d['metadata']['labels'].get('release') == 'kube-prometheus-stack',
               'all values: commonLabels not applied to %s' % d['metadata']['name'])
    pm = by_kind(docs, 'PodMonitor')[0]
    expect(pm['spec']['namespaceSelector'] == {'matchNames': ['cache-server', 'ml']}, 'all values: PodMonitor namespaceSelector')
    expect(pm['spec']['podMetricsEndpoints'][0].get('scrapeTimeout') == '10s', 'all values: PodMonitor scrapeTimeout')
    expect(pm['metadata']['labels'].get('team') == 'storage', 'all values: monitors.labels not applied')
    sm = by_kind(docs, 'ServiceMonitor')[0]
    tls = sm['spec']['endpoints'][0]['tlsConfig']
    expect(tls.get('insecureSkipVerify') is False and tls.get('ca', {}).get('secret', {}).get('name') == 'metrics-server-cert',
           'all values: ServiceMonitor tlsConfig not applied')
    for cm in by_kind(docs, 'ConfigMap'):
        expect(cm['metadata']['namespace'] == 'monitoring', 'all values: dashboards.namespace')
        expect(cm['metadata'].get('annotations', {}).get('grafana_folder') == 'DACS', 'all values: dashboards.annotations')


def check_toggles():
    docs = template(
        '--set', 'rules.enabled=false',
        '--set', 'monitors.cacheServer.enabled=false',
        '--set', 'monitors.controller.enabled=false',
        '--set', 'dashboards.enabled=false',
    )
    expect(docs == [], 'all toggles off: chart still renders %s' % [d['kind'] for d in docs])

    docs = template('--set', 'rules.cache.alerts=false', '--set', 'rules.controller.alerts=false',
                    '--set', 'dashboards.clients=false', '--set', 'dashboards.controller=false')
    rule = by_kind(docs, 'PrometheusRule')[0]
    expect(rule['spec']['groups'] == groups('prometheus_rules.yaml'), 'alerts off: only recording rules expected')
    expect(sorted(k for cm in by_kind(docs, 'ConfigMap') for k in cm['data']) == ['dacs-cache-servers.json', 'dacs-overview.json'],
           'dashboard toggles: wrong set of dashboards')

    docs = template('--set', 'rules.cache.recording=false', '--set', 'rules.cache.alerts=false',
                    '--set', 'rules.controller.alerts=false')
    expect(by_kind(docs, 'PrometheusRule') == [], 'all rule groups off: PrometheusRule should not be rendered')


def main():
    check_defaults()
    check_all_values()
    check_toggles()
    for e in errors:
        print('ERROR: ' + e, file=sys.stderr)
    if errors:
        return 1
    print('helm chart: OK (defaults, all values and toggles render as expected)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
