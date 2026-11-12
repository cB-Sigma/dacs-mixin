#!/usr/bin/env python3
"""Guard against invented metrics.

Extracts every PromQL expression from the rendered dashboards, rule files and
Kubernetes manifests, and checks each metric selector against
inventory/metrics.yaml:

  * the metric name must be in the inventory (histograms may use the
    _bucket/_sum/_count suffixes), or be a series recorded by a rule in this
    repository;
  * every label used in a matcher must be a label of that metric or a
    scrape-target label;
  * for labels with an enumerated value set (request_type, status, result),
    every literal value must be one the source can emit;
  * metrics whose Prometheus name is only "derived" (cache client metrics)
    may be used in dashboards and in the opt-in client rule files, never in
    the default rules and alerts.

Exit status is non-zero on any violation.
"""

import argparse
import json
import pathlib
import re
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent

# PromQL vocabulary. An identifier followed by "(" must be one of these,
# otherwise the checker stops rather than guess.
FUNCTIONS = {
    'abs', 'absent', 'absent_over_time', 'avg_over_time', 'ceil', 'changes', 'clamp', 'clamp_max', 'clamp_min',
    'count_over_time', 'delta', 'deriv', 'exp', 'floor', 'histogram_quantile', 'idelta', 'increase', 'irate',
    'label_join', 'label_replace', 'last_over_time', 'ln', 'log10', 'log2', 'max_over_time', 'min_over_time',
    'predict_linear', 'present_over_time', 'quantile_over_time', 'rate', 'resets', 'round', 'scalar', 'sgn',
    'sort', 'sort_desc', 'sqrt', 'stddev_over_time', 'sum_over_time', 'time', 'timestamp', 'vector',
}
AGGREGATIONS = {
    'sum', 'min', 'max', 'avg', 'group', 'stddev', 'stdvar', 'count', 'count_values', 'bottomk', 'topk', 'quantile',
}
LABEL_LIST_KEYWORDS = {'by', 'without', 'on', 'ignoring', 'group_left', 'group_right'}
KEYWORDS = {'and', 'or', 'unless', 'bool', 'offset', 'atan2', 'inf', 'nan'}

TOKEN = re.compile(
    r"""
    (?P<ws>\s+)
  | (?P<comment>\#[^\n]*)
  | (?P<string>"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`[^`]*`)
  | (?P<duration>\d+(?:ms|[smhdwy])(?:\d+(?:ms|[smhdwy]))*\b)
  | (?P<number>(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?|0x[0-9a-fA-F]+)
  | (?P<ident>[a-zA-Z_:][a-zA-Z0-9_:]*)
  | (?P<op>=~|!~|!=|==|<=|>=|[-+*/%^=<>(){}\[\],@])
    """,
    re.VERBOSE,
)

GRAFANA_RANGE_VARS = re.compile(r'\[\s*\$\{?(?:__rate_interval|__interval|__range|window)\}?\s*\]')


class PromQLError(Exception):
    pass


def tokenize(expr):
    tokens = []
    pos = 0
    while pos < len(expr):
        m = TOKEN.match(expr, pos)
        if not m:
            raise PromQLError('cannot tokenize at %r' % expr[pos:pos + 30])
        pos = m.end()
        kind = m.lastgroup
        if kind in ('ws', 'comment'):
            continue
        tokens.append((kind, m.group()))
    return tokens


def unquote(s):
    return s[1:-1]


def extract_selectors(expr):
    """Return [(metric_name, [(label, op, value), ...]), ...] for one expression."""
    expr = GRAFANA_RANGE_VARS.sub('[5m]', expr)
    tokens = tokenize(expr)
    out = []
    i = 0
    n = len(tokens)

    def skip_group(j, open_, close):
        depth = 0
        while j < n:
            if tokens[j][1] == open_:
                depth += 1
            elif tokens[j][1] == close:
                depth -= 1
                if depth == 0:
                    return j + 1
            j += 1
        raise PromQLError('unbalanced %s' % open_)

    def parse_matchers(j):
        # tokens[j] is "{"
        matchers = []
        j += 1
        while tokens[j][1] != '}':
            if tokens[j][1] == ',':
                j += 1
                continue
            kind, label = tokens[j]
            if kind != 'ident':
                raise PromQLError('expected label name, got %r' % label)
            op = tokens[j + 1][1]
            vkind, value = tokens[j + 2]
            if op not in ('=', '!=', '=~', '!~') or vkind != 'string':
                raise PromQLError('malformed matcher for label %r' % label)
            matchers.append((label, op, unquote(value)))
            j += 3
        return matchers, j + 1

    while i < n:
        kind, text = tokens[i]
        nxt = tokens[i + 1][1] if i + 1 < n else None
        if kind == 'op' and text == '[':
            i = skip_group(i, '[', ']')
        elif kind == 'op' and text == '{':
            raise PromQLError('selector without a metric name is not supported')
        elif kind == 'ident':
            if text in LABEL_LIST_KEYWORDS:
                i = skip_group(i + 1, '(', ')') if nxt == '(' else i + 1
            elif text in KEYWORDS and nxt != '{':
                i += 1
            elif nxt == '(':
                if text not in FUNCTIONS and text not in AGGREGATIONS:
                    raise PromQLError('unknown function %r' % text)
                i += 1
            elif text in AGGREGATIONS and nxt in ('by', 'without'):
                i += 1
            else:
                if nxt == '{':
                    matchers, i = parse_matchers(i + 1)
                else:
                    matchers, i = [], i + 1
                out.append((text, matchers))
        else:
            i += 1
    return out


# ---------------------------------------------------------------------------
# Expression sources
# ---------------------------------------------------------------------------

def rule_groups_from(doc):
    if not isinstance(doc, dict):
        return []
    if doc.get('kind') == 'PrometheusRule':
        return doc['spec']['groups']
    return doc.get('groups', []) or []


def dashboard_exprs(dash):
    """Yield (where, expr) for panel targets and template variable queries."""
    def panels(items):
        for p in items:
            yield p
            yield from panels(p.get('panels', []))

    for p in panels(dash.get('panels', [])):
        for t in p.get('targets', []):
            if 'expr' in t:
                yield "panel '%s'" % p.get('title'), t['expr']
    for v in dash.get('templating', {}).get('list', []):
        if v.get('type') != 'query':
            continue
        q = v['query']['query'] if isinstance(v['query'], dict) else v['query']
        m = re.match(r'^\s*label_values\((.+),\s*[a-zA-Z_][a-zA-Z0-9_]*\s*\)\s*$', q, re.S)
        if not m:
            raise PromQLError("variable '%s': unsupported query %r" % (v['name'], q))
        yield "variable '%s'" % v['name'], m.group(1)


def collect(root):
    """Return (expressions, recorded) where expressions is a list of
    (file, where, expr, is_client_scope, is_dashboard)."""
    exprs = []
    recorded = set()

    def add_rules(path, doc):
        client = 'client' in path.name
        for g in rule_groups_from(doc):
            for r in g['rules']:
                name = r.get('alert') or r.get('record')
                if 'record' in r:
                    recorded.add(r['record'])
                exprs.append((path, "rule '%s'" % name, r['expr'], client, False))

    def add_dashboard(path, where, dash):
        for w, e in dashboard_exprs(dash):
            exprs.append((path, (where + ' ' + w).strip(), e, True, True))

    for path in sorted((root / 'dashboards_out').glob('*.json')):
        add_dashboard(path, '', json.loads(path.read_text()))
    for path in sorted((root / 'charts/dacs-mixin/files/dashboards').glob('*.json')):
        add_dashboard(path, '', json.loads(path.read_text()))
    yaml_files = (
        sorted((root / 'rules_out').glob('*.yaml'))
        + sorted((root / 'manifests').rglob('*.yaml'))
        + sorted((root / 'charts/dacs-mixin/files/rules').glob('*.yaml'))
    )
    for path in yaml_files:
        for doc in yaml.safe_load_all(path.read_text()):
            if not isinstance(doc, dict):
                continue
            add_rules(path, doc)
            if doc.get('kind') == 'ConfigMap':
                for key, value in doc.get('data', {}).items():
                    if key.endswith('.json'):
                        add_dashboard(path, key, json.loads(value))
    return exprs, recorded


# ---------------------------------------------------------------------------
# Checking
# ---------------------------------------------------------------------------

class Inventory:
    def __init__(self, path):
        doc = yaml.safe_load(path.read_text())
        self.target_labels = set(doc['target_labels'])
        self.metrics = {m['name']: m for m in doc['metrics']}

    def lookup(self, name):
        if name in self.metrics:
            return self.metrics[name]
        for suffix in ('_bucket', '_sum', '_count'):
            if name.endswith(suffix):
                base = self.metrics.get(name[:-len(suffix)])
                if base and base['type'] == 'histogram':
                    return base
        return None


def literal_values(op, value):
    """Values a matcher pins down, or None when it is not a plain literal or alternation."""
    if '$' in value:
        return None
    if op in ('=', '!='):
        return [value]
    if re.fullmatch(r'[A-Za-z0-9_|]+', value):
        return value.split('|')
    return None


def check(root, verbose=False):
    inventory = Inventory(root / 'inventory/metrics.yaml')
    exprs, recorded = collect(root)
    errors = []
    used = set()
    for path, where, expr, client_scope, _ in exprs:
        rel = path.relative_to(root)
        try:
            selectors = extract_selectors(expr)
        except PromQLError as e:
            errors.append('%s: %s: %s' % (rel, where, e))
            continue
        if not selectors:
            # Constant vector(...) rules have no selector; anything else is suspicious.
            if not re.fullmatch(r'\s*vector\([0-9.eE+*\s]+\)\s*', expr):
                errors.append('%s: %s: no metric selector found' % (rel, where))
        for name, matchers in selectors:
            if name in recorded:
                used.add(name)
                continue
            metric = inventory.lookup(name)
            if metric is None:
                errors.append("%s: %s: metric '%s' is not in inventory/metrics.yaml" % (rel, where, name))
                continue
            used.add(metric['name'])
            if metric['status'] == 'derived' and not client_scope:
                errors.append(
                    "%s: %s: '%s' has a pipeline-dependent name and may only be used in client rule files"
                    % (rel, where, name)
                )
            labels = metric.get('labels') or {}
            for label, op, value in matchers:
                if label not in labels and label not in inventory.target_labels:
                    errors.append("%s: %s: label '%s' is not a label of '%s'" % (rel, where, label, name))
                    continue
                allowed = labels.get(label)
                values = literal_values(op, value)
                if allowed and values:
                    for v in values:
                        if v not in allowed:
                            errors.append(
                                "%s: %s: '%s' is not a value of %s{%s}" % (rel, where, v, name, label)
                            )
    if verbose:
        unused = sorted(set(inventory.metrics) - used)
        print('expressions checked: %d' % len(exprs))
        print('distinct metrics used: %d' % len(used))
        print('inventory metrics not used anywhere: %s' % (', '.join(unused) or 'none'))
    return errors, len(exprs), len(used)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--root', type=pathlib.Path, default=ROOT)
    ap.add_argument('-v', '--verbose', action='store_true')
    args = ap.parse_args()
    errors, n_exprs, n_metrics = check(args.root, args.verbose)
    for e in errors:
        print('ERROR: ' + e, file=sys.stderr)
    if errors:
        print('%d problem(s) found' % len(errors), file=sys.stderr)
        return 1
    print('metric inventory guard: OK (%d expressions, %d distinct metrics)' % (n_exprs, n_metrics))
    return 0


if __name__ == '__main__':
    sys.exit(main())
