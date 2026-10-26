"""Windows static checks. This never claims Swift compilation or URLSession execution."""
import ast
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import yaml
import live_probe

BASE = 'a683ce1cd80eb714c453aed79c43de2b0a8b426a'
FILES = ('.github/workflows/doustudio-media-host-live-probe.yml',
         '.github/workflows/doustudio-media-host-live-probe-offline.yml')

def validate():
    checks = []
    for filename in FILES:
        text=Path(filename).read_text(encoding='utf-8')
        wf=yaml.safe_load(text)
        trigger=wf.get('on',wf.get(True))
        assert set(trigger)=={'workflow_dispatch'}
        assert wf['permissions']=={'contents':'read'}
        job=wf['jobs']['probe']
        assert job['runs-on']=='xcode-27' and job['timeout-minutes']==20
        steps=job['steps']
        assert sum('secrets.' in json.dumps(step) for step in steps)==(0 if 'offline.yml' in filename else 1)
        for step in steps:
            if 'uses' in step:
                assert step['uses'] in ('actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1',
                    'actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9')
                if step['uses'].startswith('actions/checkout'):
                    assert step['with']['persist-credentials'] is False
            if step.get('with',{}).get('repository'):
                assert step['with']['ref']==live_probe.SHA
            if 'run' in step:
                bash=Path('C:/Program Files/Git/bin/bash.exe')
                if not bash.exists(): bash=Path('/bin/bash')
                with tempfile.TemporaryDirectory() as temp:
                    source=Path(temp)/'step.sh'; source.write_text(step['run'],encoding='utf-8')
                    # Parse shell only; expressions and commands are never evaluated.
                    subprocess.run([str(bash),'-n',str(source)],check=True,capture_output=True)
        upload=steps[-1]['with']
        artifact=tuple(line.rsplit('/',1)[-1] for line in upload['path'].splitlines())
        assert set(artifact)==set(live_probe.ARTIFACTS) and len(artifact)==len(live_probe.ARTIFACTS)
        assert upload['retention-days']==3 and not upload['include-hidden-files']
        if 'offline.yml' not in filename:
            assert trigger['workflow_dispatch']['inputs']['authorized_own_session']['default'] is False
            assert [s.get('id') for s in steps].index('offline') < [s.get('id') for s in steps].index('live')
        else: assert '--media-host-live-probe' not in text and 'secrets.' not in text
        checks.append(dict(file=filename,status='PASS',checks='manual_only_pinned_versions_secret_isolation_artifact_whitelist_bash_syntax'))
    for path in Path('runtime-harness').glob('*live_probe*.py'):
        ast.parse(path.read_text(encoding='utf-8')); checks.append(dict(file=str(path).replace('\\','/'),status='PASS',checks='python_syntax'))
    modified=subprocess.check_output(['git','diff',BASE,'--name-only','--diff-filter=M'],text=True).splitlines()
    assert not subprocess.check_output(['git','diff',BASE,'--name-only','--diff-filter=D'],text=True).strip()
    assert modified==['runtime-harness/Sources/RuntimeAcceptance/RuntimeAcceptance.swift']
    diff=subprocess.check_output(['git','diff',BASE,'--',modified[0]],text=True)
    assert not any(line.startswith('-') and not line.startswith('---') for line in diff.splitlines())
    source=Path('runtime-harness/Sources/RuntimeAcceptance/MediaHostLiveProbe.swift').read_text()
    assert '"Range":"bytes=0-0"' in source and 'completionHandler(nil)' in source
    assert 'dataTask(with:request)' in source and '.data(for:' not in source
    assert '.download(' not in source and 'task?.cancel()' in source and 'didCompleteWithError' in source
    checks.append(dict(status='PASS',checks='baseline_protected_only_entry_additions_no_downloader_no_buffered_transport'))
    # Compare publication hashes against Git blobs, not autocrlf-converted Windows files.
    prefix='evidence/doustudio-media-host-allowlist-audit-01/run-40299734675/'
    index=json.loads(subprocess.check_output(['git','show',BASE+':'+prefix+'published-evidence-index.json']))
    for name,expected in index['files'].items():
        body=subprocess.check_output(['git','show',BASE+':'+prefix+name])
        assert hashlib.sha256(body).hexdigest()==expected
    checks.append(dict(status='PASS',checks='historical_published_evidence_git_blob_hashes',files=len(index['files'])))
    return dict(WINDOWS_STATIC='PASS',MACOS_SWIFT_BUILD='NOT_RUN',SWIFT_OFFLINE_TESTS='NOT_RUN',REAL_MEDIA_PROBE='NOT_RUN',checks=checks)

if __name__=='__main__':
    value=validate()
    if len(sys.argv)>1: Path(sys.argv[1]).write_text(json.dumps(value,indent=2)+'\n',encoding='utf-8')
    else: print(json.dumps(value,indent=2))
