#!/usr/bin/env python3
"""Check that the mixin works with standard mixin tooling.

Runs `mixtool generate all` on mixin.libsonnet and compares the result with the
rendered files in rules_out/ and dashboards_out/. This proves that the mixin
can be consumed the usual way (mixtool, kube-prometheus, jsonnet-bundler) and
yields exactly what is committed here.
"""

import json
import pathlib
import subprocess
import sys
import tempfile

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent


def main():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        subprocess.run(
            ['mixtool', 'generate', 'all', '-a', str(tmp / 'alerts.yaml'), '-r', str(tmp / 'rules.yaml'),
             '-d', str(tmp / 'dashboards'), 'mixin.libsonnet'],
            check=True, cwd=ROOT, capture_output=True,
        )
        problems = []
        for generated, committed in (('alerts.yaml', 'prometheus_alerts.yaml'), ('rules.yaml', 'prometheus_rules.yaml')):
            if yaml.safe_load((tmp / generated).read_text()) != yaml.safe_load((ROOT / 'rules_out' / committed).read_text()):
                problems.append('rules_out/%s differs from mixtool output' % committed)
        generated = {p.name: json.loads(p.read_text()) for p in (tmp / 'dashboards').glob('*.json')}
        committed = {p.name: json.loads(p.read_text()) for p in (ROOT / 'dashboards_out').glob('*.json')}
        if generated != committed:
            problems.append('dashboards_out/ differs from mixtool output')
    for p in problems:
        print('ERROR: ' + p, file=sys.stderr)
    if problems:
        return 1
    print('mixtool generate: OK (identical to rules_out/ and dashboards_out/)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
