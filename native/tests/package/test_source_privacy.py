# SPDX-License-Identifier: GPL-3.0-only
"""Exercise both release verifiers' actual source-privacy checks."""
import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[3]


def load_verifier(path, name):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


VERIFIERS = (
    load_verifier('scripts/verify_release.py', 'frontend_source_verifier'),
    load_verifier('schemes/scripts/verify_release.py', 'scheme_source_verifier'),
)


class SourcePrivacyTests(unittest.TestCase):
    def check_sources(self, cases, expected):
        for module in VERIFIERS:
            for source in cases:
                with self.subTest(verifier=module.__name__, source=source):
                    self.assertEqual(module.contains_private_marker(source), expected)

    def test_official_and_other_urls_are_not_local_paths(self):
        self.check_sources([
            'https://github.com/rime/home/wiki/Configuration',
            'https://example.test/' + '/'.join(['home', 'fixture', 'guide']),
            'https://example.test/?next=' + '/' + '/'.join(['home', 'fixture', 'guide']),
            'https://example.test/#' + '/' + '/'.join(['Users', 'fixture', 'guide']),
            'ftp://example.test/' + '/'.join(['Users', 'fixture', 'guide']),
        ], False)

    def test_relative_fragments_are_not_absolute_paths(self):
        suffix = '/'.join(['home', 'fixture', 'source'])
        self.check_sources([suffix, './' + suffix, '../' + suffix,
                            'docs/' + suffix, 'docs//' + suffix,
                            'sources/' + '/'.join(['Users', 'fixture', 'source'])], False)

    def test_unix_absolute_paths_in_prose_code_and_assignments_are_private(self):
        for root in ['home', 'Users']:
            path = '/' + '/'.join([root, 'fixture', 'source', 'input.txt'])
            self.check_sources([path, 'path=' + path, 'source: ' + path,
                                '`' + path + '`', '"' + path + '"', '(' + path + ')'], True)

    def test_file_uris_remain_private(self):
        for root in ['home', 'Users']:
            path = '/' + '/'.join([root, 'fixture', 'source', 'input.txt'])
            self.check_sources(['file:' + path, 'file://' + path,
                                'file://localhost' + path, 'FILE://server' + path], True)

    def test_url_then_separate_absolute_path_is_private(self):
        path = '/' + '/'.join(['home', 'fixture', 'source'])
        self.check_sources(['https://example.test/guide ' + path,
                            '[guide](https://example.test/guide)\n`' + path + '`'], True)

    def test_windows_paths_remain_private_including_inside_urls(self):
        for directory in ['Users', 'Portable']:
            for separator in ['/', '\\']:
                path = 'C:' + separator + separator.join([directory, 'fixture', 'source'])
                self.check_sources([path, 'https://example.test/?path=' + path], True)

    def test_credentials_remain_private_including_inside_urls(self):
        tokens = ['gh' + kind + '_' + 'a' * 24 for kind in 'pousr']
        tokens += ['-' * 5 + 'BEGIN ' + kind + 'PRIVATE KEY' + '-' * 5
                   for kind in ['', 'RSA ', 'EC ', 'OPENSSH ']]
        for token in tokens:
            self.check_sources([token, 'https://example.test/?token=' + token], True)


if __name__ == '__main__':
    unittest.main()
