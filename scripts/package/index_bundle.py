"""Index the combined installation with exact inherited license records."""
# SPDX-License-Identifier: GPL-3.0-only
import argparse
import hashlib
import json
from pathlib import Path

from prepare_bundle import DEFAULT_FONT_NAME

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--stage', type=Path, required=True)
p.add_argument('--ref', required=True)
a=p.parse_args()
root=a.stage
load=lambda path: json.loads(path.read_text('utf-8-sig'))
base=load(root/'base-package-license-index.json')
scheme=load(root/'scheme-notices/package-license-index.json')
old={row['path']:row for row in base['files']}
incoming={row['path']:row for row in scheme['files']}
scheme_paths={row['source_path']:row['path'] for row in scheme['files']}
active_scheme_ids={key for row in scheme['files'] for key in row['license'].get('source_ids',[])}
provenance=load(root/'bundle-provenance.json')
origins={row['installed_path']:row for row in provenance['files']}
scheme_archive_paths={row['archive_member']:row['installed_path'] for row in provenance['files'] if row['source']=='schemes'}
font_manifest=root/'font-payload/font-manifest.json'
font_records={row['file']:row for row in load(font_manifest)['files'] if row['file']==DEFAULT_FONT_NAME} if font_manifest.is_file() else {}
font_sources={
    'candidate-font:regular':{
        'name':'Noto Sans CJK Regular Collection',
        'families':entry['families'],
        'version':entry['version'],
        'license':entry['license'],
        'url':entry['source'],
        'notices':['font-notices/OFL.txt','font-notices/NOTICE.txt'],
        'evidence':['font-notices/font-manifest.json'],
    } for entry in font_records.values()
}
records=[]
excluded={'install.nsi','bundle.nsi','bundle_architecture.nsh','InstallProfilePolicy.ps1','NativeProfileSnapshot.ps1','stellae_identity.nsh'}

def scheme_reference(name):
    if '://' in name:return name
    archive=scheme_paths.get(name,name)
    installed=scheme_archive_paths.get(archive, 'scheme-notices/'+archive)
    actual=root/'shared-payload'/installed if installed.startswith('data/') else root/installed
    if not actual.is_file():raise SystemExit('Scheme license reference is absent from the package: '+name)
    return installed

for key in active_scheme_ids:
    for field in ['notices','evidence']:
        for name in scheme['sources'][key].get(field,[]):scheme_reference(name)
for path in sorted(root.rglob('*')):
    if not path.is_file():continue
    relative=path.relative_to(root).as_posix()
    if relative in excluded or relative.startswith('archives/') or relative in {'package-manifest.json','package-license-index.json'}:continue
    installed='data/'+relative[len('shared-payload/data/'):] if relative.startswith('shared-payload/data/') else relative
    digest=hashlib.sha256(path.read_bytes()).hexdigest()
    row={'path':relative,'installed_path':installed,'bytes':path.stat().st_size,'sha256':digest}
    origin=origins.get(installed)
    if origin and origin.get('transformation'):
        row['transformation']=origin['transformation']
        row['original_sha256']=origin['original_sha256']
        if origin.get('generated_source_ids'):
            row['generated_source_ids']=origin['generated_source_ids']
            row['generated_license']='GPL-3.0-only'
            row['generated_references']=['LICENSE.txt']
    if origin and origin['source']=='schemes':
        name=origin['archive_member']
        if name in incoming:
            expected=incoming[name].get('sha256')
            if expected and expected!=origin.get('original_sha256',digest):raise SystemExit('Scheme source license bytes differ')
            if not expected and name not in {'package-manifest.json','package-license-index.json'}:raise SystemExit('A scheme source hash is missing')
            row['license_record']=incoming[name]
        elif name in {'package-manifest.json','package-license-index.json'}:
            row['license_record']={'terms':'GPL-3.0-only','references':['LICENSE']}
        else:raise SystemExit('Scheme file has no exact license record: '+name)
        row['license_reference_root']='scheme-notices'
        row['license_index']='scheme-notices/package-license-index.json'
        original_license=row['license_record'].get('license',{})
        scheme_ids=list(original_license.get('source_ids',[]))
        if original_license.get('project_license')=='GPL-3.0-only' and 'project' not in scheme_ids:scheme_ids.append('project')
        row['source_ids']=origin.get('generated_source_ids',[])+['scheme:'+key for key in scheme_ids]
        row['resolved_references']=[scheme_reference(name) for name in row['license_record'].get('license',row['license_record']).get('references',[])]
    elif origin and origin['source'] in {'frontendInstaller','rebuiltServer','rebuiltFrontend','rebuiltRuntimeEngine'} and installed in old and old[installed]['sha256']==origin.get('original_sha256',digest):
        row['license_record']=old[installed]
        row['license_reference_root']='.'
        row['license_index']='base-package-license-index.json'
        row['source_ids']=list(dict.fromkeys(origin.get('generated_source_ids',[])+old[installed].get('source_ids',[])))
        if origin['source'] in {'rebuiltServer','rebuiltFrontend','rebuiltRuntimeEngine'}:
            row['corresponding_source']=origin['corresponding_source']
            row['rebuild_source_ref']=origin['source_ref']
            if origin['source']=='rebuiltServer':
                row['rebuild_run_id']=origin['source_run']
            if origin['source']=='rebuiltRuntimeEngine':
                row['corresponding_source_sha256']=origin['corresponding_source_sha256']
                row['native_manifest_sha256']=origin['native_manifest_sha256']
                row['engine_variant']=origin['variant']
    elif origin and origin['source']=='officialSharedData':
        refs=['licenses/package/prelude-LICENSE.txt'] if path.name=='pinyin.yaml' else ['scheme-notices/licenses/radical-stroke/stroke-LGPL-3.0.txt','scheme-notices/licenses/radical-stroke/stroke-AUTHORS']
        row['license_record']={'terms':'LGPL-3.0; retain original authors and source headers','references':refs}
    elif relative.startswith('scheme-notices/'):
        row['license_record']={'terms':'See the retained source distribution and its per-file index','references':['scheme-notices/package-license-index.json']}
    elif relative.startswith('shared-payload/migrations/math/'):
        math = 'shared-payload/migrations/math/'
        source = provenance['inputs']['indexedMath']
        row['license_record'] = {
            'terms': 'CC-BY-SA-4.0' if relative.startswith(math+'english_index/') else 'Original notice or source metadata',
            'references': [math+'LICENSE-CC-BY-SA-4.0.txt', math+'NOTICE.txt', math+'SOURCE.json'],
            'source_archive': source['url'], 'source_archive_sha256': source['sha256'],
        }
    elif relative.startswith('font-payload/') and path.name in font_records:
        entry=font_records[path.name]
        if digest != entry['sha256'] or row['bytes'] != entry['size']:
            raise SystemExit('The staged default font is inconsistent with the reviewed manifest.')
        row['license_record']={'terms':entry['license'],'references':['font-notices/OFL.txt','font-notices/NOTICE.txt']}
        row['source_ids']=['candidate-font:regular']
        row['installation_scope']='Current Windows user'
    elif relative in {'font-payload/OFL.txt','font-notices/OFL.txt'}:
        row['license_record']={'terms':'Original upstream OFL-1.1 notice','references':['font-notices/OFL.txt']}
    elif relative in {'font-payload/NOTICE.txt','font-notices/NOTICE.txt'}:
        row['license_record']={'terms':'Font attribution and exact source notice','references':['font-notices/OFL.txt']}
    else:
        docs=relative in {'README.txt','SOURCES.md','THIRD_PARTY_NOTICES.md','LICENSE-DOCS'}
        row['license_record']={'terms':'CC-BY-SA-4.0' if docs else 'GPL-3.0-only','references':['licenses/CC-BY-SA-4.0.txt' if docs else 'LICENSE.txt']}
    records.append(row)
report={'format':'stellae-payload-license-index-v2','bundleVersion':provenance['bundleVersion'],
        'frontendVersion':provenance['frontendVersion'],'sourceRef':a.ref,'baseSources':base['sources'],
        'schemeSources':{key:scheme['sources'][key] for key in sorted(active_scheme_ids)},
        'schemeArchivePaths':scheme_archive_paths,
        'sources':{**base['sources'],**{'scheme:'+key:scheme['sources'][key] for key in sorted(active_scheme_ids)},**font_sources},
        'files':records,'installerRuntimeSources':['project-code','nsis'],
        'scope':'Exact package input bytes and installed paths. Nested license records retain their source-index meaning and identify the installed reference root.'}
(root/'package-license-index.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
(root/'package-manifest.json').write_text(json.dumps({'format':'stellae-package-v2',
    'bundleVersion':provenance['bundleVersion'],'frontendVersion':provenance['frontendVersion'],
    'sourceRef':a.ref,'inputSchemesBundled':True,'files':[{k:r[k] for k in ['path','installed_path','bytes','sha256']} for r in records]},ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print(json.dumps({'indexedFiles':len(records),'inheritedSourceNotices':True}))
