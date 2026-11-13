"""Verify the actual NSIS extraction and the reused production image hashes."""
# SPDX-License-Identifier: GPL-3.0-only
import argparse
import hashlib
import json
from pathlib import Path

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--stage',type=Path,required=True)
p.add_argument('--extracted',type=Path,required=True)
p.add_argument('--report',type=Path,required=True)
a=p.parse_args()
files=[path for path in a.extracted.rglob('*') if path.is_file()]
hashes={hashlib.sha256(path.read_bytes()).hexdigest() for path in files}
manifest=json.loads((a.stage/'package-manifest.json').read_text('utf-8-sig'))
shared=(a.stage/'shared-payload/data').resolve()
profile=json.loads((shared/'config-source-manifest.json').read_text('utf-8-sig'))
profile_records=profile['source_files']+profile['generated_files']
for entry in profile_records:
    path=(shared/entry['path']).resolve()
    if not path.is_relative_to(shared) or not path.is_file():raise SystemExit('Installed profile manifest has an invalid path')
    raw=path.read_bytes()
    if len(raw)!=entry['bytes'] or hashlib.sha256(raw).hexdigest()!=entry['sha256']:raise SystemExit('Installed profile manifest describes stale bytes: '+entry['path'])
snapshot=a.stage/profile['archive_provenance']['original_manifest']
if hashlib.sha256(snapshot.read_bytes()).hexdigest()!=profile['archive_provenance']['original_manifest_sha256']:raise SystemExit('Original scheme profile snapshot differs')
for entry in manifest['files']:
    if entry['sha256'] not in hashes:raise SystemExit('Completed installer is missing declared bytes: '+entry['path'])
for name in ['package-manifest.json','package-license-index.json']:
    if hashlib.sha256((a.stage/name).read_bytes()).hexdigest() not in hashes:raise SystemExit('Missing installed metadata: '+name)
for path in files:
    if path.suffix.lower() in {'.pdb','.dmp','.log'} or '.userdb' in path.name:raise SystemExit('Unexpected runtime or diagnostic file')
provenance=json.loads((a.stage/'bundle-provenance.json').read_text('utf-8-sig'))
core=[]
for row in provenance['files']:
    if row['source']=='frontendInstaller' and Path(row['installed_path']).suffix.lower() in {'.exe','.dll','.ime'}:
        path=a.stage/row['installed_path']
        if hashlib.sha256(path.read_bytes()).hexdigest()!=row['sha256']:raise SystemExit('Reused product differs')
        core.append({'path':row['installed_path'],'sha256':row['sha256']})
report={'format':'stellae-bundle-extraction-v1','passed':True,'bundleVersion':manifest['bundleVersion'],
    'frontendVersion':manifest['frontendVersion'],'verifiedInputFiles':len(manifest['files']),
    'installedProfileRecordsVerified':len(profile_records),
    'extractedFiles':len(files),'reusedImages':core,'physicalKeyboardTested':False}
a.report.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
print(json.dumps({'passed':True,'verifiedInputFiles':len(manifest['files']),'reusedImages':len(core)}))
