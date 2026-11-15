"""Extract production mode/icon code for bounded C++17 regression tests.

SPDX-License-Identifier: GPL-3.0-only
"""
from pathlib import Path
import argparse
import hashlib
import json

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source-root', type=Path)
parser.add_argument('--baseline-cpp', type=Path)
parser.add_argument('--candidate-cpp', type=Path)
parser.add_argument('--baseline-header', type=Path)
parser.add_argument('--candidate-header', type=Path)
parser.add_argument('--output-dir', type=Path, required=True)
args = parser.parse_args()
if args.source_root:
    assert not args.candidate_cpp and not args.candidate_header
    args.candidate_cpp = args.source_root / 'RimeWithWeasel/RimeWithWeasel.cpp'
    args.candidate_header = args.source_root / 'include/RimeWithWeasel.h'
assert args.candidate_cpp and args.candidate_header
assert bool(args.baseline_cpp) == bool(args.baseline_header)
paths = [args.candidate_cpp, args.candidate_header]
if args.baseline_cpp:
    paths += [args.baseline_cpp, args.baseline_header]
raw = [path.resolve(strict=True).read_bytes() for path in paths]
text = [value.decode('utf-8-sig').replace('\r\n', '\n') for value in raw]
candidate, new_header = text[:2]
assert new_header.count('  std::wstring mode_zhung_icon[2];\n') == 1
if args.baseline_cpp:
    baseline, old_header = text[2:]
    assert new_header.replace('  std::wstring mode_zhung_icon[2];\n', '') == old_header, 'Only the mode-icon cache may be added to SessionStatus.'
assert candidate.count('  // Context properties are response metadata, not popup notifications.\n  if (!strcmp(message_type, "property"))\n    return;') == 1
query_start = candidate.index('bool RimeWithWeaselHandler::QueryMetadata(')
query_end = candidate.index('void RimeWithWeaselHandler::FocusIn(', query_start)
query = candidate[query_start:query_end]
assert 'UIStyle style = session.style;' in query and 'ApplyModeStyle(session,' in query
assert 'AppendStyleMetadata(style, true, actions, messages);' in query
apply_start = candidate.index('static bool ApplyModeStyle(')
apply_end = candidate.index('WeaselSessionId _GenerateNewWeaselSessionId(', apply_start)
assert 'ascii_mode' not in candidate[apply_start:apply_end]
output = args.output_dir.resolve()
assert not output.exists(), 'Preserve earlier finite extraction.'
output.mkdir(parents=True)

def balanced_function(source, signature):
    first = source.index(signature)
    body = source.index('{', first)
    depth = 1
    cursor = body + 1
    while depth:
        if source[cursor] == '{':
            depth += 1
        elif source[cursor] == '}':
            depth -= 1
        cursor += 1
    return source[first:cursor] + '\n'

records = []
variants = [('patched', candidate, raw[0])]
if args.baseline_cpp:
    variants.insert(0, ('baseline', baseline, raw[2]))
for name, source, product_bytes in variants:
    folder = output / name
    folder.mkdir()
    apply = balanced_function(source, 'static bool ApplyModeStyle(')
    if name == 'baseline':
        first = source.index('    const auto load_icon = [](')
        body = source.index('{', first)
        depth, cursor = 1, body + 1
        while depth:
            depth += (source[cursor] == '{') - (source[cursor] == '}')
            cursor += 1
        assert source[cursor:cursor + 1] == ';'
        load = source[first:cursor + 1].strip().replace('const auto load_icon =', 'static const auto LoadSchemaIcon =', 1) + '\n'
    else:
        load = balanced_function(source, 'static std::wstring LoadSchemaIcon(')
    first = source.index('  // Optional per-schema layout')
    last = source.index('  rime_api->config_close(&config);', first)
    mode = source[first:last]
    blocks = {'production-load-icon.inc': load, 'production-apply-mode.inc': apply,
              'production-load-mode.inc': mode}
    for filename, content in blocks.items():
        (folder / filename).write_text(content, encoding='utf-8', newline='\n')
    records.append({'Variant': name, 'ProductionSha256': hashlib.sha256(product_bytes).hexdigest(),
                    'ExtractedSha256': {key: hashlib.sha256(value.encode()).hexdigest() for key, value in blocks.items()}})
proof = {'Prepared': True, 'Variants': records, 'HeaderOnlyModeIconCacheAdded': bool(args.baseline_cpp),
         'ActualProductionCode': ['ApplyModeStyle', 'LoadSchemaIcon or original load_icon lambda',
                                  '_LoadSchemaSpecificSettings mode overlay block'],
         'MetadataCopyProductionPatternVerified': True, 'AsciiModeUnchangedByOverlay': True,
         'OnNotifyPropertyGuardRetained': True, 'EngineOpened': False, 'CandidateServerStarted': False,
         'Limits': ['Configuration API and UIStyle/SessionStatus boundary fixtures',
                    'Existing metadata-copy production pattern is structurally verified; copied style uses actual ApplyModeStyle',
                    'No physical keyboard, language bar or popup window observation']}
(output / 'source-proof.json').write_text(json.dumps(proof, indent=2) + '\n', encoding='utf-8')
assert [path.resolve(strict=True).read_bytes() for path in paths] == raw
print(json.dumps({'Prepared': True, 'VariantCount': len(records), 'ProductionFilesModified': False}))
