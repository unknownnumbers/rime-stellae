"""Preserve historical component evidence across the appearance config rename."""
# SPDX-License-Identifier: GPL-3.0-only
import copy
import json
from pathlib import Path
import sys
import unittest

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'scripts/package'))
from stage_settings_update import baseline_predecessors, APPEARANCE_PRESET, LEGACY_APPEARANCE_PRESET
sys.path.pop(0)


class SettingsBaselineTests(unittest.TestCase):
    def setUp(self):
        self.baseline = json.loads((REPO / 'installer/settings-update-baseline.json').read_text('utf-8-sig'))

    def test_fixed_historical_components_remain_accepted_without_rewriting_evidence(self):
        before = copy.deepcopy(self.baseline)
        original, previous = baseline_predecessors(self.baseline, 'b' * 64)
        self.assertEqual(self.baseline, before)
        self.assertEqual(original, {row['path']: row['sha256'] for row in before['files']})
        for component in before['previousComponents']:
            row = next(row for row in component['files'] if row['path'] == LEGACY_APPEARANCE_PRESET)
            self.assertIn(row['sha256'], previous[APPEARANCE_PRESET])
        self.assertIn('b' * 64, previous[APPEARANCE_PRESET])
        self.assertNotIn(LEGACY_APPEARANCE_PRESET, previous)

    def test_new_component_names_can_follow_the_original_historical_records(self):
        component = copy.deepcopy(self.baseline['previousComponents'][-1])
        component['sourceRef'] = 'a' * 40
        for row in component['files']:
            if row['path'] == LEGACY_APPEARANCE_PRESET:
                row['path'], row['sha256'] = APPEARANCE_PRESET, 'c' * 64
        self.baseline['previousComponents'].append(component)
        _, previous = baseline_predecessors(self.baseline, 'b' * 64)
        self.assertIn('c' * 64, previous[APPEARANCE_PRESET])

    def test_alias_mapping_does_not_accept_duplicate_targets_or_unknown_files(self):
        for path in (LEGACY_APPEARANCE_PRESET, 'data/unrecognized.yaml'):
            baseline = copy.deepcopy(self.baseline)
            baseline['previousComponents'][0]['files'][0]['path'] = path
            with self.assertRaises(AssertionError):
                baseline_predecessors(baseline, 'b' * 64)


if __name__ == '__main__':
    unittest.main()
