#!/usr/bin/env python3
"""Turn every dashboard query into a recording rule so promtool can parse it.

Grafana variables that are not valid PromQL are replaced first; variables
inside label matcher strings are left alone because they are plain strings to
the parser. Usage:

    scripts/dashboard_queries.py > /tmp/dashboard-queries.yaml
    promtool check rules /tmp/dashboard-queries.yaml
"""

import json
import pathlib
import re
import sys

import yaml

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from check_metrics import GRAFANA_RANGE_VARS, ROOT, dashboard_exprs  # noqa: E402


def main():
    rules = []
    for path in sorted((ROOT / 'dashboards_out').glob('*.json')):
        dash = json.loads(path.read_text())
        for n, (where, expr) in enumerate(dashboard_exprs(dash)):
            rules.append({
                'record': 'dashboard:%s:query%d' % (re.sub(r'[^a-z0-9]+', '_', path.stem), n),
                'expr': GRAFANA_RANGE_VARS.sub('[5m]', expr),
                'labels': {'source': where[:120]},
            })
    yaml.safe_dump({'groups': [{'name': 'dashboard-queries', 'rules': rules}]}, sys.stdout, sort_keys=False, width=1000)
    print('%d dashboard queries written' % len(rules), file=sys.stderr)


if __name__ == '__main__':
    main()
