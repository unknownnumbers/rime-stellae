"""Extract production notification methods for bounded native regression tests.

SPDX-License-Identifier: GPL-3.0-only
"""
from pathlib import Path
import argparse
import difflib
import hashlib
import json

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--baseline-cpp', type=Path, required=True)
parser.add_argument('--candidate-cpp', type=Path, required=True)
parser.add_argument('--output-dir', type=Path, required=True)
args = parser.parse_args()
baseline = args.baseline_cpp.resolve(strict=True)
candidate = args.candidate_cpp.resolve(strict=True)
assert not baseline.is_symlink() and not candidate.is_symlink()
original = baseline.read_bytes()
proposed = candidate.read_bytes()
newline = b'\r\n' if b'\r\n' in original else b'\n'
anchor = newline.join([b'  if (!self || !message_type || !message_value)', b'    return;', b''])
guard = newline.join([
    b'  // Context properties are response metadata, not popup notifications.',
    b'  if (!strcmp(message_type, "property"))',
    b'    return;', b'',
])
assert original.count(anchor) == 1
assert proposed == original.replace(anchor, anchor + guard), 'The proposed source must contain only the scoped notification guard.'
output = args.output_dir.resolve()
assert not output.exists(), 'Preserve previous finite test extraction.'
output.mkdir(parents=True)
methods = (
    ('BOOL RimeWithWeaselHandler::ProcessKeyEvent(', 'void RimeWithWeaselHandler::CommitComposition(', 'production-engine-handler.inc'),
    ('void RimeWithWeaselHandler::OnNotify(', 'void RimeWithWeaselHandler::_ReadClientInfo(', 'production-notify-handler.inc'),
    ('bool RimeWithWeaselHandler::_ShowMessage(', 'inline std::string _GetLabelText(', 'production-show-message.inc'),
)
records = []
for name, raw in (('baseline', original), ('patched', proposed)):
    text = raw.decode('utf-8-sig').replace('\r\n', '\n')
    folder = output / name
    folder.mkdir()
    hashes = {}
    for start, end, filename in methods:
        first = text.index(start)
        last = text.index(end, first)
        extracted = text[first:last]
        (folder / filename).write_text(extracted, encoding='utf-8', newline='\n')
        hashes[filename] = hashlib.sha256(extracted.encode('utf-8')).hexdigest()
    first = text.index('void RimeWithWeaselHandler::_UpdateUI(')
    last = text.index('void RimeWithWeaselHandler::_LoadSchemaSpecificSettings(', first)
    reset = '\n'.join('  ' + line.strip() for line in text[first:last].splitlines()
                       if line.strip().startswith(('m_message_type.clear()', 'm_message_value.clear()', 'm_message_label.clear()', 'm_option_name.clear()'))) + '\n'
    assert len(reset.splitlines()) == 4
    (folder / 'production-notification-reset.inc').write_text(reset, encoding='utf-8', newline='\n')
    hashes['production-notification-reset.inc'] = hashlib.sha256(reset.encode()).hexdigest()
    records.append({'Variant': name, 'ProductBytes': len(raw), 'ProductSha256': hashlib.sha256(raw).hexdigest(),
                    'ExtractedMethodSha256': hashes})
diff = ''.join(difflib.unified_diff(original.decode('utf-8-sig').splitlines(True), proposed.decode('utf-8-sig').splitlines(True),
                                     fromfile='original/RimeWithWeasel.cpp', tofile='proposed/RimeWithWeasel.cpp'))
(output / 'policy.diff').write_text(diff, encoding='utf-8', newline='\n')
report = {'Prepared': True, 'ProductionFilesModified': False, 'CandidateChangeOnlyOnNotifyPropertyGuard': True,
          'Variants': records, 'ActualMethods': ['ProcessKeyEvent', 'OnNotify', '_ShowMessage'],
          'AdditionalProductionLines': 'Pending notification reset in _UpdateUI'}
(output / 'source-proof.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
assert baseline.read_bytes() == original and candidate.read_bytes() == proposed
print(json.dumps({'Prepared': True, 'VariantCount': len(records), 'ProductionFilesModified': False}))
