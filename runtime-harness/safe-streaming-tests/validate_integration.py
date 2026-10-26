"""Windows preparation validation; real Swift/network results come only from macOS."""
import ast
import hashlib
import json
from pathlib import Path
import subprocess
import sys

root=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(root/'.git/task-validation/pylibs'))
import yaml
folder=Path(__file__).parent
for name in ('integration_server.py','run_integration_tests.py','validate_integration.py'):ast.parse((folder/name).read_text(),filename=name)
workflow=root/'.github/workflows/doustudio-download-integration.yml'
text=workflow.read_text();data=yaml.load(text,Loader=yaml.BaseLoader)
assert data['name']=='DouStudioKit Download Integration Tests' and set(data['on'])=={'workflow_dispatch'}
assert data['permissions']=={'contents':'read'} and 'secrets.' not in text and 'inputs:' not in text
job=data['jobs']['controlled'];assert job['runs-on']=='xcode-27' and int(job['timeout-minutes'])<=20
steps=job['steps'];checkout=[s for s in steps if s.get('uses','').startswith('actions/checkout@')]
assert len(checkout)==2 and all(s['with']['persist-credentials']=='false' for s in checkout)
assert checkout[1]['with']['ref']=='362dad3d082e9f63c8efd360acc653ba169d40a2'
assert all(len(s['uses'].split('@')[1])==40 for s in steps if 'uses' in s)
for step in steps:
    if 'run' in step:subprocess.run(['C:/Program Files/Git/bin/bash.exe','-n'],input=step['run'],text=True,check=True)
allowed={'runtime-environment.json','build.log','build-exit-code.txt','runner-exit-code.txt','integration-results.json',
         'integration-server-counters.json','integration-process.log','integration-cleanup.json','source-protection.json','stage-outcomes.json'}
artifact=steps[-1]['with'];assert {s.rsplit('/',1)[-1] for s in artifact['path'].splitlines()}==allowed
assert artifact['retention-days']=='3'
transport=folder/'Sources/SafeStreamingTests/SafeStreamingTransport.swift'
assert hashlib.sha256(transport.read_bytes()).hexdigest()=='2456887e7982c92bef429760900f46f37d2663835becf3daa2128b2131202ab1'
before=json.loads((root/'.git/task-validation/download-integration/before.json').read_text())
changed=[p for p,d in before.items() if hashlib.sha256((root/p).read_bytes()).hexdigest()!=d]
entry='runtime-harness/safe-streaming-tests/Sources/SafeStreamingTests/ControlledTests.swift'
assert changed==[entry],changed
result=dict(validation='PASS',python_syntax='PASS',yaml_structure='PASS',shell_syntax='PASS',original_transport_unchanged=True,
            existing_files_checked=len(before),existing_files_changed=changed,existing_workflows_unchanged=True,
            actionlint='NOT_INSTALLED_NOT_RUN',swift_build='NOT_RUN_ON_WINDOWS',real_media_gate='CLOSED')
out=root/'evidence/doustudio-real-download-integration-01/local-validation.json';out.parent.mkdir(parents=True,exist_ok=True)
out.write_bytes((json.dumps(result,indent=2)+'\n').encode());print(json.dumps(result))
