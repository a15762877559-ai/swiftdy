"""Offline preparation validation, with no Swift execution or network requests."""
import ast
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(root / '.git/task-validation/pylibs'))
import yaml

checks = []


def check(name, condition):
    assert condition, name
    checks.append(name)


text = (root / '.github/workflows/doustudio-harness-offline.yml').read_text()
workflow = yaml.load(text, Loader=yaml.BaseLoader)
check('Only manual dispatch and no input', workflow['on'] == {'workflow_dispatch':''})
check('Read-only contents permission', workflow['permissions'] == {'contents':'read'})
job = workflow['jobs']['offline']
check('Requested runner', job['runs-on'] == 'xcode-27')
check('Timeout 20 minutes', job['timeout-minutes'] == '20')
check('Offline-only environment', job['env'] == {'OFFLINE_ONLY':'1'})
steps = job['steps']
pins = {'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1',
        'actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9'}
check('Official pinned actions only', {s['uses'] for s in steps if 'uses' in s} == pins)
for s in steps:
    if s.get('uses','').startswith('actions/checkout'):
        check('No persistent credentials', s['with']['persist-credentials'] == 'false')
upstream = next(s for s in steps if s.get('with',{}).get('repository') == 'qinjian0420/DouStudioKit')
check('Pinned upstream', upstream['with']['ref'] == '362dad3d082e9f63c8efd360acc653ba169d40a2')
upload = next(s for s in steps if s.get('uses','').startswith('actions/upload-artifact'))
check('Retention', upload['with']['retention-days'] == '3')
check('11 explicit artifact paths', len(upload['with']['path'].splitlines()) == 11 and '*' not in upload['with']['path'])
check('No profile input, secrets or online workflow', all(s not in text for s in ['PROFILE_URL','profile_url','secrets.','doustudio-runtime-acceptance.yml']))
seen = set()
for step in steps:
    for value in step.values():
        for exp in re.findall(r'\$\{\{(.*?)\}\}', str(value)):
            roots = set(re.findall(r'(?<![\w.])([a-zA-Z_]\w*)\.',exp))
            check('Step expression context', roots <= {'runner','steps','github'})
            check('Prior step references', all(ref in seen for ref in re.findall(r'steps\.([\w-]+)\.',exp)))
    if 'id' in step: seen.add(step['id'])
    if 'run' in step:
        result = subprocess.run([r'C:\Program Files\Git\bin\bash.exe','-n'], input=step['run'],text=True,capture_output=True)
        check('Bash syntax '+step['name'],result.returncode == 0)
test = (root / 'runtime-harness/Sources/RuntimeAcceptance/SelfTest.swift').read_text()
main = (root / 'runtime-harness/Sources/RuntimeAcceptance/RuntimeAcceptance.swift').read_text()
ids = re.findall(r'await runCase\("(OFF-\d+)"',test)
check('Unique case IDs', len(ids) >= 16 and len(ids) == len(set(ids)))
check('Original seven remain', all(f'OFF-{i:03}' in ids for i in range(1,8)))
check('No network/client/download constructors in selftest', all(s not in test for s in ['URLSessionTransport(', 'DouyinClient(', '.accountTimeline(', '.download(work:', 'execute()']))
check('All observers use injected memory transport', test.count('ObservingTransport(') == test.count('ObservingTransport(base: FixtureTransport('))
check('Offline branch returns before online entry', main.index('return\n        }') < main.index('try await execute()'))
check('Online entry guard exists', 'ONLINE_ENTRY_DISABLED_IN_OFFLINE_MODE' in main and 'exit(64)' in main)
check('Failures control exit', 'if !passed { exit(1) }' in main and 'results.allSatisfy' in test)
check('Structured diagnostic fields', all('let '+field+': String' in test for field in ['id','name','function','status','errorCategory','expected','actual']))
check('No unsafe error descriptions', 'localizedDescription' not in test and 'print(error)' not in test)
for path in (root / 'runtime-harness').glob('*.py'):
    ast.parse(path.read_text()); check('Python syntax '+path.name,True)
base = root / '.git/task-validation/offline-fix-01'
base.mkdir(parents=True,exist_ok=True)
before = json.loads((base / 'protected-before.json').read_text(encoding='utf-8-sig'))
for entry in before:
    check('Protected '+entry['path'], hashlib.sha256((root / entry['path']).read_bytes()).hexdigest().upper() == entry['hash'])
if '--diagnostic' in sys.argv:
    check('No implementation repair before diagnostic run', subprocess.check_output(['git','diff','--','runtime-harness/Sources/RuntimeAcceptance/Observation.swift'],cwd=root) == b'')
with tempfile.TemporaryDirectory(prefix='offline-check-',dir=base) as tmp:
    folder = Path(tmp)
    envfile,output = folder/'env',folder/'output'
    envfile.touch(); output.touch()
    env = dict(os.environ,OFFLINE_TEMP=str(folder),GITHUB_ENV=str(envfile),GITHUB_OUTPUT=str(output))
    proc = subprocess.run([sys.executable,str(root/'runtime-harness/offline_evidence.py'),'initialize'],env=env,capture_output=True,text=True)
    check('Initializer executes without profile',proc.returncode == 0)
    evidence = folder/'doustudio-harness-offline'
    check('No fabricated result',json.loads((evidence/'selftest-results.json').read_text()) == {'status':'NOT_RUN','cases':[]})
    check('Initial exit codes unknown',all((evidence/name).read_text().strip() == 'NOT_RUN' for name in ['build-exit-code.txt','selftest-exit-code.txt','entry-guard-exit-code.txt']))
result = {'result':'PASS','checks':len(checks),'case_ids':ids,'swift_compilation':'NOT_RUN_LOCALLY',
          'actionlint':'NOT_INSTALLED_NOT_RUN','network_tests':'NOT_RUN','protected_files_verified':len(before)}
(base/'local-validation.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result))
