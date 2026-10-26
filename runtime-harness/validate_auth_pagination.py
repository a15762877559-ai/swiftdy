"""Windows static checks only; never claims Swift compilation or fixture execution."""
import ast
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

root=Path(__file__).resolve().parent.parent
sys.path.insert(0,str(root/'.git/task-validation/pylibs'))
import yaml
workflow=root/'.github/workflows/doustudio-authenticated-pagination.yml'
text=workflow.read_text(encoding='utf-8')
w=yaml.load(text,Loader=yaml.BaseLoader)
assert w['name']=='DouStudioKit Authenticated Pagination Acceptance'
assert list(w['on'])==['workflow_dispatch'] and w['permissions']=={'contents':'read'}
inputs=w['on']['workflow_dispatch']['inputs']
assert set(inputs)=={'profile_url','authorized_own_session'} and 'default' not in inputs['profile_url']
assert inputs['authorized_own_session']['default']=='false'
job=w['jobs']['pagination']; steps=job['steps']
assert job['runs-on']=='xcode-27' and job['timeout-minutes']=='20' and 'env' not in job
pins={'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1','actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9'}
assert {s['uses'] for s in steps if 'uses' in s}==pins
assert all(s['with']['persist-credentials']=='false' for s in steps if s.get('uses','').startswith('actions/checkout'))
assert next(s for s in steps if s.get('with',{}).get('path')=='upstream')['with']['ref']=='362dad3d082e9f63c8efd360acc653ba169d40a2'
secret=next(s for s in steps if 'DOUYIN_COOKIE' in s.get('env',{}))
assert secret['id']=='pagination' and 'if' not in secret
assert text.count('secrets.')==1 and secret['env']['DOUYIN_COOKIE']=='${{ secrets.DOUYIN_COOKIE }}'
assert 'set +x' in secret['run'] and 'ulimit -c 0' in secret['run']
offline=next(s for s in steps if s.get('id')=='offline')
assert steps.index(offline)<steps.index(secret) and 'deny network*' in offline['run'] and '--pagination-self-test' in offline['run']
assert offline['env']['OFFLINE_ONLY']=='1' and 'continue-on-error' not in text
artifact=steps[-1]['with']
allowed={'input-validation.json','environment.json','source-protection.json','stage-outcomes.json','build.log','build-exit-code.txt','offline.log','offline-exit-code.txt','selftest-results.json','pagination-result.json','pagination-exit-code.txt','pagination-selftest-results.json','final-acceptance.json'}
assert artifact['retention-days']=='3' and '*' not in artifact['path']
assert {p.rsplit('/',1)[1] for p in artifact['path'].splitlines()}==allowed
for s in steps:
    if 'run' in s:
        subprocess.run([r'C:\Program Files\Git\bin\bash.exe','-n'],input=s['run'],text=True,check=True)
        assert 'set -x' not in s['run'] and 'printenv' not in s['run']
for p in (root/'runtime-harness').glob('*pagination*.py'): ast.parse(p.read_text(encoding='utf-8'))
swift=(root/'runtime-harness/Sources/RuntimeAcceptance/AuthenticatedPagination.swift').read_text(encoding='utf-8')
assert 'maxRetry: 0' in swift and swift.count('maxPages: 3')==2 and 'pages.count < 3' in swift
assert 'endpoints.accountTimeline' in swift and 'expectedCursor = next' in swift
assert '.download(' not in swift and 'collectAccountBatched' not in swift and 'print(' not in swift and 'localizedDescription' not in swift
main=(root/'runtime-harness/Sources/RuntimeAcceptance/RuntimeAcceptance.swift').read_text(encoding='utf-8')
assert main.index('--pagination-self-test')<main.index('ONLINE_ENTRY_DISABLED_IN_OFFLINE_MODE')<main.index('--authenticated-pagination')<main.index('try await execute()')
assert 'cookie: ""' in main
fixtures=(root/'runtime-harness/Sources/RuntimeAcceptance/PaginationSelfTest.swift').read_text(encoding='utf-8')
ids=re.findall(r'"(PAG-\d{3})"',fixtures)
assert set(ids)=={f'PAG-{n:03}' for n in range(1,25)} and 'URLSessionTransport(' not in fixtures
snapshot=root/'.git/task-validation/auth-pagination/protected-before.json'
if snapshot.exists():
    protected=json.loads(snapshot.read_text(encoding='utf-8'))
    for path,expected in protected.items():
        if path=='runtime-harness/Sources/RuntimeAcceptance/RuntimeAcceptance.swift': continue
        assert hashlib.sha256((root/path).read_bytes()).hexdigest()==expected,path
    print('Protected baseline hashes PASS:',len(protected)-1)
print('PASS: YAML, manual trigger, pins, secret step isolation, offline gate, bash syntax, 13-file Artifact allowlist, bounded original collector, 24 fixture definitions')
print('Swift compilation/fixture execution: NOT_RUN (no Windows toolchain). actionlint: NOT_RUN (not installed).')
