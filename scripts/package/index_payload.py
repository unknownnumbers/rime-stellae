"""Resolve every payload file to the reviewed source and license inventory."""
# SPDX-License-Identifier: GPL-3.0-only
import argparse
import fnmatch
import hashlib
import json
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('--root', required=True)
p.add_argument('--repository', required=True)
p.add_argument('--report', required=True)
a = p.parse_args()
root, repo = Path(a.root), Path(a.repository)
data = json.loads((repo/'licenses/package-sources.json').read_text(encoding='utf-8-sig'))
notices = {v['path']: v for v in json.loads((repo/'licenses/third-party-source-manifest.json').read_text(encoding='utf-8-sig'))['files']}
file_index = {v['path']: v for v in json.loads((repo/'licenses/file-licenses.json').read_text(encoding='utf-8-sig'))['files']}
records = []
for path in sorted(root.rglob('*')):
    if not path.is_file():
        continue
    name = path.relative_to(root).as_posix()
    if name in {'install.nsi', 'package-license-index.json'} or name.startswith('archives/'):
        continue
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    record = {'path': name, 'bytes': path.stat().st_size, 'sha256': digest}
    if name in notices:
        if digest != notices[name]['sha256']:
            raise SystemExit('Original notice differs: '+name)
        record['notice_record'] = notices[name]
        record['retained_terms'] = 'Original notice text and exact source record retained.'
    elif name.startswith('licenses/'):
        entry = file_index.get(name)
        if not entry or not entry.get('source_ids'):
            raise SystemExit('No exact source index for license metadata: '+name)
        record['source_ids'] = entry['source_ids']
        record['references'] = entry.get('references', [])
    else:
        rules = [rule for rule in data['rules'] if fnmatch.fnmatchcase(name, rule['pattern'])]
        if not rules:
            raise SystemExit('Unmapped payload file: '+name)
        record['source_ids'] = list(dict.fromkeys(i for rule in rules for i in rule['source_ids']))
        for source_id in record['source_ids']:
            if source_id not in data['sources']:
                raise SystemExit('Unknown source: '+source_id)
    records.append(record)
report = {'format': 'stellae-generated-payload-license-index-v1', 'scope': 'Package input files. The generated index excludes its own bytes; installer and uninstaller runtime also use the NSIS source and notices below.', 'sources': data['sources'], 'installer_runtime_source_ids': ['project-code', 'nsis'], 'files': records}
Path(a.report).write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
print('Indexed payload files:', len(records))
