"""Static preparation checks only; never claims Swift/URLSession runtime success."""
import ast
import hashlib
import json
from pathlib import Path
import subprocess
import sys

root=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(root/'.git/task-validation/pylibs'))
import yaml

folder=Path(__file__).resolve().parent
for path in folder.glob('*.py'): ast.parse(path.read_text(encoding='utf-8'),filename=path.name)
workflow=root/'.github/workflows/doustudio-safe-streaming-tests.yml'
document=yaml.load(workflow.read_text(),Loader=yaml.BaseLoader)
assert set(document['on'])=={'workflow_dispatch'}
assert document['permissions']=={'contents':'read'}
job=document['jobs']['controlled']
assert job['runs-on']=='xcode-27' and int(job['timeout-minutes'])<=20
steps=job['steps']
checkouts=[s for s in steps if s.get('uses','').startswith('actions/checkout@')]
assert len(checkouts)==2 and all(s['with']['persist-credentials']=='false' for s in checkouts)
assert checkouts[1]['with']['ref']=='362dad3d082e9f63c8efd360acc653ba169d40a2'
assert all(len(s['uses'].split('@')[1])==40 for s in steps if 'uses' in s)
assert 'secrets.' not in workflow.read_text() and 'inputs:' not in workflow.read_text()
artifact=steps[-1]['with']
assert artifact['retention-days']=='3'
allowed={'runtime-environment.json','build.log','build-exit-code.txt','runner-exit-code.txt','controlled-results.json',
         'server-counters.json','test-process.log','cleanup-summary.json','source-protection.json','stage-outcomes.json'}
assert {line.rsplit('/',1)[-1] for line in artifact['path'].splitlines()}==allowed
bash=Path('C:/Program Files/Git/bin/bash.exe')
if not bash.exists(): raise RuntimeError('BASH_SYNTAX_CHECK_UNAVAILABLE')
for step in steps:
    if 'run' in step:
        subprocess.run([str(bash),'-n'],input=step['run'],text=True,check=True)
before=json.loads((root/'.git/task-validation/safe-streaming/protected-before.json').read_text())
changed=[name for name,digest in before.items() if hashlib.sha256((root/name).read_bytes()).hexdigest()!=digest]
assert not changed,changed
result=dict(local_static_validation='PASS',python_syntax='PASS',yaml_structure='PASS',bash_syntax='PASS',
            protected_existing_files=len(before),changed_existing_files=changed,actionlint='NOT_INSTALLED_NOT_RUN',
            swift_build='NOT_RUN_ON_WINDOWS',controlled_urlsession_tests='NOT_RUN_ON_WINDOWS')
out=root/'evidence/doustudio-safe-streaming-transport-01/local-validation.json'
out.parent.mkdir(parents=True,exist_ok=True)
out.write_bytes((json.dumps(result,indent=2)+'\n').encode())
print(json.dumps(result))
