"""Unit tests for the PromQL selector extraction behind scripts/check_metrics.py."""

import pathlib
import shutil
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'scripts'))

import check_metrics  # noqa: E402
from check_metrics import PromQLError, extract_selectors  # noqa: E402


def names(expr):
    return [name for name, _ in extract_selectors(expr)]


class ExtractSelectors(unittest.TestCase):
    def test_bare_metric(self):
        self.assertEqual(names('up'), ['up'])

    def test_matchers(self):
        self.assertEqual(
            extract_selectors('foo{a="1", b=~"x|y", c!="z", d!~".+"}'),
            [('foo', [('a', '=', '1'), ('b', '=~', 'x|y'), ('c', '!=', 'z'), ('d', '!~', '.+')])],
        )

    def test_functions_and_aggregations_are_not_metrics(self):
        self.assertEqual(
            names('histogram_quantile(0.99, sum by (le, pod) (rate(lat_bucket{job="x"}[5m])))'),
            ['lat_bucket'],
        )

    def test_grouping_labels_are_not_metrics(self):
        expr = 'sum without (instance) (a) / on (namespace, cache) group_left (pod) max by (namespace, cache) (b)'
        self.assertEqual(names(expr), ['a', 'b'])

    def test_aggregation_with_leading_by(self):
        self.assertEqual(names('sum by (job) (rate(x_total[5m]))'), ['x_total'])

    def test_binary_operators_and_keywords(self):
        self.assertEqual(names('a > bool 1 and b unless c or d offset 5m'), ['a', 'b', 'c', 'd'])

    def test_recording_rule_names_with_colons(self):
        self.assertEqual(names('dacs:cache:servers_ready < dacs:cache:servers_desired'), [
            'dacs:cache:servers_ready', 'dacs:cache:servers_desired',
        ])

    def test_grafana_variables(self):
        expr = 'sum(rate(x_total{namespace=~"$namespace", pod=~"${pod}"}[$__rate_interval])) + sum(rate(y_total[$window]))'
        self.assertEqual(names(expr), ['x_total', 'y_total'])

    def test_strings_are_ignored(self):
        self.assertEqual(names('label_replace(a, "cache", "$1", "statefulset", "(.+)")'), ['a'])
        self.assertEqual(names('label_replace(a{x="fake_metric{} sum("}, "b", "c", "d", "e")'), ['a'])

    def test_subquery_and_durations(self):
        self.assertEqual(names('max_over_time(rate(a[5m])[1h:1m]) > 2 * b offset 1d'), ['a', 'b'])

    def test_metric_named_like_a_keyword_prefix(self):
        self.assertEqual(names('sum(bytes_total) by (job)'), ['bytes_total'])

    def test_unknown_function_is_an_error(self):
        with self.assertRaises(PromQLError):
            extract_selectors('made_up_function(a)')

    def test_nameless_selector_is_an_error(self):
        with self.assertRaises(PromQLError):
            extract_selectors('{__name__=~"cache_.+"}')

    def test_untokenizable_input_is_an_error(self):
        with self.assertRaises(PromQLError):
            extract_selectors('a ? b')


class GuardOnRepository(unittest.TestCase):
    """Run the whole guard against copies of the repository with one thing broken."""

    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        for d in ('dashboards_out', 'rules_out', 'manifests', 'inventory', 'charts/dacs-mixin/files'):
            shutil.copytree(ROOT / d, self.tmp / d)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def edit(self, rel, old, new):
        path = self.tmp / rel
        text = path.read_text()
        self.assertIn(old, text)
        path.write_text(text.replace(old, new))

    def errors(self):
        return check_metrics.check(self.tmp)[0]

    def test_repository_is_clean(self):
        self.assertEqual(self.errors(), [])

    def test_invented_metric_in_rule(self):
        self.edit('rules_out/prometheus_alerts.yaml', 'cache_server_listen_drops_total', 'cache_server_listen_drop_total')
        self.assertTrue(any("'cache_server_listen_drop_total' is not in inventory" in e for e in self.errors()))

    def test_invented_metric_in_dashboard(self):
        self.edit('dashboards_out/dacs-overview.json', 'cache_server_cache_size_bytes', 'cache_server_cache_capacity_bytes')
        self.assertTrue(any("'cache_server_cache_capacity_bytes' is not in inventory" in e for e in self.errors()))

    def test_missing_counter_suffix(self):
        self.edit('dashboards_out/dacs-cache-servers.json', 'cache_server_passive_opens_total', 'cache_server_passive_opens')
        self.assertTrue(any("'cache_server_passive_opens' is not in inventory" in e for e in self.errors()))

    def test_unknown_label(self):
        self.edit('rules_out/prometheus_rules.yaml', 'cache_server_request_counter{job="dacs-cache-server"}',
                  'cache_server_request_counter{job="dacs-cache-server", operation="Download"}')
        self.assertTrue(any("label 'operation' is not a label of 'cache_server_request_counter'" in e for e in self.errors()))

    def test_unknown_label_value(self):
        self.edit('dashboards_out/dacs-overview.json', 'status=\\"InvalidTransition\\"', 'status=\\"NotFound\\"')
        self.assertTrue(any("'NotFound' is not a value of cache_server_request_counter{status}" in e for e in self.errors()))

    def test_client_metric_in_default_alerts(self):
        self.edit('rules_out/prometheus_alerts.yaml', 'cache_server_listen_drops_total', 'cache_client_dns_errors_total')
        self.assertTrue(any('may only be used in client rule files' in e for e in self.errors()))

    def test_histogram_suffix_on_non_histogram(self):
        self.edit('dashboards_out/dacs-cache-servers.json', 'cache_server_open_fds', 'cache_server_open_fds_bucket')
        self.assertTrue(any("'cache_server_open_fds_bucket' is not in inventory" in e for e in self.errors()))


if __name__ == '__main__':
    unittest.main()
