"""Local workflow and credential-boundary checks; no network and no real secret."""
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
text=(root/'.github/workflows/doustudio-authenticated-preflight.yml').read_text()
w=yaml.load(text,Loader=yaml.BaseLoader)
assert list(w['on'])==['workflow_dispatch']
inputs=w['on']['workflow_dispatch']['inputs']
assert set(inputs)=={'profile_url','authorized_own_session'}
assert inputs['authorized_own_session']['default']=='false' and inputs['authorized_own_session']['type']=='boolean'
assert 'default' not in inputs['profile_url']
assert w['permissions']=={'contents':'read'}
job=w['jobs']['preflight']
assert job['runs-on']=='xcode-27' and job['timeout-minutes']=='20' and 'env' not in job
steps=job['steps']
assert text.count('secrets.')==1 and text.count('secrets.DOUYIN_COOKIE')==1
secret_step=next(s for s in steps if 'DOUYIN_COOKIE' in s.get('env',{}))
assert secret_step['id']=='auth' and 'set +x' in secret_step['run'] and 'ulimit -c 0' in secret_step['run']
pins={'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1','actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9'}
assert {s['uses'] for s in steps if 'uses' in s}==pins
assert all(s['with']['persist-credentials']=='false' for s in steps if s.get('uses','').startswith('actions/checkout'))
assert next(s for s in steps if s.get('with',{}).get('path')=='upstream')['with']['ref']=='362dad3d082e9f63c8efd360acc653ba169d40a2'
artifact=steps[-1]['with']
assert artifact['retention-days']=='3' and '*' not in artifact['path'] and len(artifact['path'].splitlines())==11
assert 'AUTH_BIN' not in artifact['path'] and 'DOUYIN_COOKIE' not in artifact['path']
for step in steps:
    if 'run' in step:
        subprocess.run([r'C:\Program Files\Git\bin\bash.exe','-n'],input=step['run'],text=True,check=True)
        assert 'set -x' not in step['run'] and 'printenv' not in step['run']
for p in (root/'runtime-harness').glob('*auth*.py'): ast.parse(p.read_text())
swift=(root/'runtime-harness/Sources/RuntimeAcceptance/AuthenticatedPreflight.swift').read_text()
assert 'maxRetry: 0' in swift and swift.count('maxPages: 1')==2
assert 'observed.request_count == 0' in swift and 'bounded.followRedirects = false' in swift
assert '.download(' not in swift and 'collectAccountBatched' not in swift
assert 'print(' not in swift and 'localizedDescription' not in swift and 'digest(' not in swift
main=(root/'runtime-harness/Sources/RuntimeAcceptance/RuntimeAcceptance.swift').read_text()
assert main.index('ONLINE_ENTRY_DISABLED_IN_OFFLINE_MODE')<main.index('--authenticated-preflight')<main.index('try await execute()')
assert 'cookie: ""' in main
tests=(root/'runtime-harness/Sources/RuntimeAcceptance/AuthPreflightSelfTest.swift').read_text()
ids=re.findall(r'await test\("(AUTH-\d+)"',tests)
assert len(ids)==19 and len(set(ids))==19
assert 'URLSessionTransport(' not in tests
protected=json.loads((root/'.git/task-validation/auth-preflight/protected-before.json').read_text(encoding='utf-8-sig'))
for p in protected: assert hashlib.sha256((root/p['path']).read_bytes()).hexdigest().upper()==p['hash'],p['path']
out={'workflow_validation':'PASS','secret_injection':'AUTH_STEP_ONLY','artifact_whitelist':11,'swift_fixture_cases':19,'existing_cases':19,
     'protected_files_verified':len(protected),'swift_local_compilation':'NOT_RUN_NO_TOOLCHAIN','actionlint':'NOT_INSTALLED_NOT_RUN','authenticated_request':'NOT_RUN'}
(root/'.git/task-validation/auth-preflight/local-validation.json').write_text(json.dumps(out,indent=2)+'\n')
print(json.dumps(out))
