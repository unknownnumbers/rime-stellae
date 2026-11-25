"""Keep frontend appearance entrypoints independent across generated profiles.

SPDX-License-Identifier: GPL-3.0-only
"""
import importlib.util
import json
from pathlib import Path
import unittest

SCHEMES = Path(__file__).resolve().parents[3] / 'schemes'
spec = importlib.util.spec_from_file_location('appearance_profiles', SCHEMES / 'scripts/rebuild_profiles.py')
profiles = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profiles)


class AppearanceProfileTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        _, _, cls.inputs = profiles.load_inputs(SCHEMES / 'config/pc')
        cls.settings = json.loads((SCHEMES / 'config/profiles.json').read_bytes())['profiles']

    def test_stellae_uses_its_own_appearance_entrypoint(self):
        payload = profiles.adapt_profile(self.inputs, 'stellae', self.settings['stellae'])
        self.assertIn('stellae.custom.yaml', payload)
        self.assertNotIn('weasel.custom.yaml', payload)

    def test_official_host_retains_the_native_appearance_entrypoint(self):
        payload = profiles.adapt_profile(self.inputs, 'official-weasel', self.settings['official-weasel'])
        self.assertNotIn('stellae.custom.yaml', payload)
        self.assertNotIn('samples/stellae.custom.yaml', payload)
        self.assertEqual(payload['samples/weasel.custom.yaml'], self.inputs['stellae.custom.yaml'])

    def test_ambiguous_common_entrypoints_are_rejected(self):
        ambiguous = {**self.inputs, 'weasel.custom.yaml': b'patch: {}\n'}
        with self.assertRaisesRegex(ValueError, 'one appearance override'):
            profiles.adapt_profile(ambiguous, 'official-weasel', self.settings['official-weasel'])


if __name__ == '__main__':
    unittest.main()
