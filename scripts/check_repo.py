#!/usr/bin/env python3
"""Structural checks that do not need promtool or jsonnet.

  * every JSON and YAML file in the repository parses;
  * every alert has a severity, a `for`-independent summary, a description and
    a runbook_url that points at an existing file in docs/runbooks/;
  * every runbook belongs to an alert;
  * every dashboard has a unique uid and title, a datasource variable and no
    hard-coded datasource uid; every panel has a description, and every panel
    that plots data has a unit;
  * every metric in inventory/metrics.yaml is documented in docs/metrics.md,
    and every alert and dashboard is listed in README.md.
"""

import json
import pathlib
import re
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
RUNBOOK_PREFIX = 'https://github.com/cb-Sigma/dacs-mixin/blob/main/docs/runbooks/'
SEVERITIES = {'warning', 'critical', 'info'}
SKIP_DIRS = {'.git', '.bin', 'vendor', 'node_modules'}

errors = []


def err(msg):
    errors.append(msg)


def repo_files(*suffixes):
    for path in sorted(ROOT.rglob('*')):
        if path.is_file() and path.suffix in suffixes and not (set(path.relative_to(ROOT).parts) & SKIP_DIRS):
            yield path


def check_syntax():
    n = 0
    for path in repo_files('.json'):
        n += 1
        try:
            json.loads(path.read_text())
        except ValueError as e:
            err('%s: invalid JSON: %s' % (path.relative_to(ROOT), e))
    for path in repo_files('.yaml', '.yml'):
        if 'charts/dacs-mixin/templates' in path.as_posix():
            continue  # Helm templates are not YAML until rendered.
        n += 1
        try:
            list(yaml.safe_load_all(path.read_text()))
        except yaml.YAMLError as e:
            err('%s: invalid YAML: %s' % (path.relative_to(ROOT), e))
    return n


def load_alerts():
    alerts = {}
    for name in ('prometheus_alerts.yaml', 'prometheus_client_alerts.yaml'):
        doc = yaml.safe_load((ROOT / 'rules_out' / name).read_text())
        for group in doc['groups']:
            for rule in group['rules']:
                alerts[rule['alert']] = rule
    return alerts


def check_alerts(alerts):
    readme = (ROOT / 'README.md').read_text()
    runbooks = {p.stem for p in (ROOT / 'docs/runbooks').glob('*.md')} - {'README'}
    referenced = set()
    for name, rule in alerts.items():
        if not re.fullmatch(r'Dacs[A-Z][A-Za-z]+', name):
            err("alert %s: name must be CamelCase and start with 'Dacs'" % name)
        if rule.get('labels', {}).get('severity') not in SEVERITIES:
            err('alert %s: missing or unknown severity label' % name)
        ann = rule.get('annotations', {})
        for key in ('summary', 'description', 'runbook_url'):
            if not ann.get(key):
                err('alert %s: missing %s annotation' % (name, key))
        if ann.get('summary', '').count('{{'):
            err('alert %s: summary must not be templated' % name)
        if ann.get('summary') and not ann['summary'].endswith('.'):
            err('alert %s: summary must end with a period' % name)
        url = ann.get('runbook_url', '')
        if not url.startswith(RUNBOOK_PREFIX) or not url.endswith('.md'):
            err('alert %s: runbook_url must point into docs/runbooks/' % name)
        else:
            stem = url[len(RUNBOOK_PREFIX):-3]
            referenced.add(stem)
            if stem not in runbooks:
                err('alert %s: runbook docs/runbooks/%s.md does not exist' % (name, stem))
        if '`%s`' % name not in readme:
            err('alert %s: not listed in README.md' % name)
        index = (ROOT / 'docs/runbooks/README.md').read_text()
        if name not in index:
            err('alert %s: not listed in docs/runbooks/README.md' % name)
    for stem in sorted(runbooks - referenced):
        err('docs/runbooks/%s.md: no alert links to this runbook' % stem)


def walk_panels(panels):
    for p in panels:
        yield p
        yield from walk_panels(p.get('panels', []))


def check_dashboards():
    readme = (ROOT / 'README.md').read_text()
    uids, titles = set(), set()
    count = 0
    for path in sorted((ROOT / 'dashboards_out').glob('*.json')):
        rel = path.relative_to(ROOT)
        dash = json.loads(path.read_text())
        count += 1
        for key, seen in (('uid', uids), ('title', titles)):
            if not dash.get(key) or dash[key] in seen:
                err('%s: missing or duplicate %s' % (rel, key))
            seen.add(dash.get(key))
        if len(dash.get('uid', '')) > 40:
            err('%s: uid longer than 40 characters' % rel)
        if dash['title'] not in readme:
            err("%s: dashboard '%s' is not listed in README.md" % (rel, dash['title']))
        if not dash.get('description'):
            err('%s: dashboard has no description' % rel)
        variables = {v['name']: v for v in dash['templating']['list']}
        if variables.get('datasource', {}).get('type') != 'datasource':
            err('%s: no datasource template variable' % rel)
        ids = set()
        for p in walk_panels(dash['panels']):
            title = p.get('title')
            if p['id'] in ids:
                err("%s: duplicate panel id %s" % (rel, p['id']))
            ids.add(p['id'])
            if p['type'] == 'row':
                continue
            if p['type'] != 'text' and not p.get('description'):
                err("%s: panel '%s' has no description" % (rel, title))
            sources = [p.get('datasource')] + [t.get('datasource') for t in p.get('targets', [])]
            if p['type'] != 'text':
                for ds in sources:
                    if not isinstance(ds, dict) or ds.get('uid') != '${datasource}':
                        err("%s: panel '%s' does not use the ${datasource} variable" % (rel, title))
                        break
            if p['type'] in ('timeseries', 'stat'):
                if not p['fieldConfig']['defaults'].get('unit'):
                    err("%s: panel '%s' has no unit" % (rel, title))
            if p['type'] == 'heatmap' and not p['options']['yAxis'].get('unit'):
                err("%s: panel '%s' has no unit" % (rel, title))
            if p['type'] == 'table':
                units = [o for o in p['fieldConfig']['overrides'] if any(x['id'] == 'unit' for x in o['properties'])]
                if len(units) != len(p['targets']):
                    err("%s: table '%s' has columns without a unit" % (rel, title))
            if p['type'] != 'text' and not p.get('targets'):
                err("%s: panel '%s' has no targets" % (rel, title))
    return count


def check_inventory_docs():
    inventory = yaml.safe_load((ROOT / 'inventory/metrics.yaml').read_text())
    doc = (ROOT / 'docs/metrics.md').read_text()
    commit = inventory['verified_against']['commit']
    for path in ('docs/metrics.md', 'README.md'):
        if commit not in (ROOT / path).read_text():
            err('%s: does not mention the verified DACS commit %s' % (path, commit))
    for m in inventory['metrics']:
        if '`%s`' % m['name'] not in doc:
            err("docs/metrics.md: metric '%s' from the inventory is not documented" % m['name'])
        if m['status'] not in ('verified', 'derived', 'external', 'config-supplied'):
            err("inventory: metric '%s' has unknown status %r" % (m['name'], m['status']))
        if m['type'] not in ('counter', 'gauge', 'histogram', 'summary'):
            err("inventory: metric '%s' has unknown type %r" % (m['name'], m['type']))
    return len(inventory['metrics'])


def main():
    n_files = check_syntax()
    alerts = load_alerts()
    check_alerts(alerts)
    n_dash = check_dashboards()
    n_metrics = check_inventory_docs()
    for e in errors:
        print('ERROR: ' + e, file=sys.stderr)
    if errors:
        print('%d problem(s) found' % len(errors), file=sys.stderr)
        return 1
    print('repository checks: OK (%d JSON/YAML files, %d alerts, %d dashboards, %d inventory metrics)'
          % (n_files, len(alerts), n_dash, n_metrics))
    return 0


if __name__ == '__main__':
    sys.exit(main())
