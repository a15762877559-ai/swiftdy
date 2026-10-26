"""Static validation of an intentionally blocked, network-free download preflight."""
import ast
import hashlib
import json
from pathlib import Path
import subprocess
import sys

root=Path(__file__).resolve().parent.parent
sys.path.insert(0,str(root/'.git/task-validation/pylibs'))
import yaml
import single_video_preflight as gate

text=(root/'.github/workflows/doustudio-single-video-download.yml').read_text(encoding='utf-8')
w=yaml.load(text,Loader=yaml.BaseLoader)
assert w['name']=='DouStudioKit Single Video Download Acceptance'
assert list(w['on'])==['workflow_dispatch'] and w['permissions']=={'contents':'read'}
inputs=w['on']['workflow_dispatch']['inputs']
assert set(inputs)=={'profile_url','work_index','authorized_own_session'}
assert 'default' not in inputs['profile_url'] and 'default' not in inputs['work_index']
assert inputs['authorized_own_session']['default']=='false'
job=w['jobs']['preflight'];steps=job['steps']
assert job['runs-on']=='xcode-27' and job['timeout-minutes']=='20' and 'env' not in job
assert 'secrets.' not in text and 'DOUYIN_COOKIE' not in text and 'continue-on-error' not in text
assert {s['uses'] for s in steps if 'uses' in s}=={'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1','actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9'}
assert all(s['with']['persist-credentials']=='false' for s in steps if s.get('uses','').startswith('actions/checkout'))
assert next(s for s in steps if s.get('with',{}).get('path')=='upstream')['with']['ref']==gate.SHA
expected={'input-validation.json','source-audit.json','runtime-environment.json','gate-tests.log','gate-tests-exit-code.txt','download-gate.json','stage-outcomes.json','final-acceptance.json'}
artifact=steps[-1]['with'];assert artifact['retention-days']=='3' and '*' not in artifact['path']
assert {line.rsplit('/',1)[1] for line in artifact['path'].splitlines()}==expected
for s in steps:
    if 'run' in s:
        subprocess.run([r'C:\Program Files\Git\bin\bash.exe','-n'],input=s['run'],text=True,check=True)
        assert 'set -x' not in s['run'] and 'printenv' not in s['run']
assert 'deny network*' in next(s for s in steps if s.get('id')=='gate_tests')['run']
assert 'single_video_preflight.py gate' in next(s for s in steps if s.get('id')=='gate')['run']
for p in (root/'runtime-harness').glob('*single_video*.py'): ast.parse(p.read_text(encoding='utf-8'))
manifest=json.loads((root/'runtime-harness/single_video_audit.json').read_text())
assert gate.verify_sources(root/'.git/task-validation/runtime-upstream',manifest)
snapshot=root/'.git/task-validation/single-video/protected-before.json'
if snapshot.exists():
    protected=json.loads(snapshot.read_text())
    for name,digest in protected.items(): assert hashlib.sha256((root/name).read_bytes()).hexdigest()==digest,name
    print('Unchanged baseline files:',len(protected))
print('PASS: workflow YAML, shell syntax, fixed source hashes, 8-file audit-only artifact whitelist, no credential injection, no media execution path')
print('DOWNLOAD_PREFLIGHT=BLOCKED; RECEIVE_BYTE_LIMIT=NOT_ENFORCED; Swift build and media transport regressions NOT_RUN')
