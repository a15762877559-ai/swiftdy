"""Offline structural checks and evidence-initializer integration checks.

Requires an existing PyYAML installation. Does not compile Swift or call Douyin.
"""
import ast
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
if (ROOT / '.git/task-validation/pylibs').exists():
    sys.path.insert(0, str(ROOT / '.git/task-validation/pylibs'))
import yaml


class UniqueLoader(yaml.BaseLoader):
    pass


def mapping(loader, node, deep=False):
    pairs = loader.construct_pairs(node, deep=deep)
    keys = [key for key, _ in pairs]
    assert len(keys) == len(set(keys)), 'Duplicate YAML keys'
    return dict(pairs)


UniqueLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, mapping)
checks = []


def check(name, condition):
    assert condition, name
    checks.append(name)


source = (ROOT / '.github/workflows/doustudio-runtime-acceptance.yml').read_text(encoding='utf-8')
workflow = yaml.load(source, Loader=UniqueLoader)
check('Manual trigger only', set(workflow['on']) == {'workflow_dispatch'})
inputs = workflow['on']['workflow_dispatch']['inputs']
check('No default profile target', 'default' not in inputs['profile_url'])
check('Consent defaults false', inputs['authorized_public_content']['default'] == 'false')
check('Read-only contents permission', workflow['permissions'] == {'contents': 'read'})
job = workflow['jobs']['runtime']
check('Requested runner and timeout', job['runs-on'] == 'xcode-27' and job['timeout-minutes'] == '20')
steps = job['steps']
pins = {'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1',
        'actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9'}
check('Only pinned official actions', {s['uses'] for s in steps if 'uses' in s} == pins)
for s in steps:
    if s.get('uses', '').startswith('actions/checkout@'):
        check('Checkout credentials disabled', s['with']['persist-credentials'] == 'false')
upstream = next(s for s in steps if s.get('with', {}).get('repository') == 'qinjian0420/DouStudioKit')
check('Full upstream pin', upstream['with']['ref'] == '362dad3d082e9f63c8efd360acc653ba169d40a2')
upload = next(s for s in steps if s.get('uses', '').startswith('actions/upload-artifact@'))
check('Three-day retention', upload['with']['retention-days'] == '3')
paths = upload['with']['path'].splitlines()
check('Explicit artifact whitelist', len(paths) == 13 and all(p.startswith('${{ steps.evidence.outputs.directory }}/') for p in paths))
check('No media or wildcard artifact', all('*' not in p and not p.endswith(('.mp4', '.mov')) for p in paths))
check('No secrets or injected input in shell', 'secrets.' not in source and '${{ inputs.' not in source and '${{ github.event.inputs.' not in source)
check('No publication/deployment commands', not re.search(r'git\s+(push|commit)|deploy|schedule:', source))
check('No job runner.temp context', 'runner.' not in str(job.get('env', {})))
seen = set()
for step in steps:
    for key, value in step.items():
        for exp in re.findall(r'\$\{\{(.*?)\}\}', str(value)):
            roots = set(re.findall(r'(?<![\w.])([A-Za-z_]\w*)\.', exp))
            check('Step expression context: ' + step['name'], roots <= {'runner','github','steps'})
            check('Expression uses prior outputs', all(ref in seen for ref in re.findall(r'steps\.([\w-]+)\.', exp)))
    if 'id' in step:
        seen.add(step['id'])
bash = shutil.which('bash')
git_bash = Path(r'C:\Program Files\Git\bin\bash.exe')
if git_bash.exists():
    bash = str(git_bash)
check('Existing Bash available', bool(bash))
for step in steps:
    if 'run' in step:
        result = subprocess.run([bash, '-n'], input=step['run'], text=True, capture_output=True)
        check('Bash syntax: ' + step['name'], result.returncode == 0)
for path in (ROOT / 'runtime-harness').glob('*.py'):
    ast.parse(path.read_text(encoding='utf-8'))
    check('Python syntax: ' + path.name, True)
seeds = ROOT / 'evidence/doustudio-real-runtime-acceptance-01'
for path in seeds.glob('*.json'):
    json.loads(path.read_text(encoding='utf-8'))
    check('JSON parse: ' + path.name, True)
check('Preparation results honest', json.loads((seeds / 'final-acceptance.json').read_text())['statuses']['VIDEO_DOWNLOAD'] == 'NOT_RUN')
swift = '\n'.join(p.read_text(encoding='utf-8') for p in (ROOT / 'runtime-harness/Sources').rglob('*.swift'))
check('Original public calls present', all(x in swift for x in ('LinkParser().parse', 'endpoints.accountTimeline', '.work(from:', 'downloader.download(work:')))
check('No guessed batch cursor API', 'collectAccountBatched(' not in swift)
check('Explicit anonymous session and no retries', 'cookie: ""' in swift and 'maxRetry: 0' in swift)
check('Three page cap and single download', 'maxPages: 3' in swift and 'mediaRequests == 0' in swift)
check('No direct network reimplementation', 'URLSession.shared' not in swift and 'data(for:' not in swift)
check('No raw error logging', 'localizedDescription' not in swift and 'print(error)' not in swift)
check('Decode full track', 'copyNextSampleBuffer()' in swift and 'reader.status == .completed' in swift)
check('Original build workflow unchanged', hashlib.sha256((ROOT / '.github/workflows/doustudio-macos-build.yml').read_bytes()).hexdigest() == '2451d682512c8b94f5bcd9ae48f9273405387dc4c7b4841b5c66e8712fab9b94')

# Execute only Python preparation against in-repository .git fixtures. Synthetic
# profile string is never persisted as a real target and never requested.
fixture_root = ROOT / '.git/task-validation'
fixture_root.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='runtime offline ', dir=fixture_root) as fixture:
    fixture = Path(fixture)
    for case, profile, consent, expected in [
        ('valid', 'https://www.douyin.com/user/offline_fixture', 'true', 0),
        ('no_consent', 'https://www.douyin.com/user/offline_fixture', 'false', 2),
        ('query', 'https://www.douyin.com/user/offline_fixture?secret=fixture', 'true', 2),
        ('injection', 'https://www.douyin.com/user/x\nINJECTED=value', 'true', 2),
        ('wrong_host', 'https://example.org/user/offline_fixture', 'true', 2),
    ]:
        case_root = fixture / case
        case_root.mkdir()
        event = case_root / 'event.json'
        event.write_text(json.dumps({'inputs': {'profile_url':profile,'authorized_public_content':consent}}))
        env_file, outputs = case_root / 'env', case_root / 'outputs'
        env_file.touch(); outputs.touch()
        env = dict(os.environ, RUNTIME_TEMP=str(case_root), GITHUB_EVENT_PATH=str(event),
                   GITHUB_ENV=str(env_file), GITHUB_OUTPUT=str(outputs))
        result = subprocess.run([sys.executable, str(ROOT / 'runtime-harness/prepare_evidence.py')], env=env, capture_output=True, text=True)
        check('Input integration: ' + case, result.returncode == expected)
        check('Evidence survives input validation: ' + case, (case_root / 'doustudio-runtime-evidence/final-acceptance.json').exists())
        if expected:
            check('Rejected input never exported or logged: ' + case, 'PROFILE_URL=' not in env_file.read_text() and profile not in result.stdout)
        else:
            check('Valid profile masked', '::add-mask::' in result.stdout)
actionlint = shutil.which('actionlint')
if actionlint:
    result = subprocess.run([actionlint, str(ROOT / '.github/workflows/doustudio-runtime-acceptance.yml')], capture_output=True, text=True)
    check('actionlint', result.returncode == 0)
result = {'result':'PASS','check_count':len(checks),'checks':checks,
          'actionlint':'PASS' if actionlint else 'NOT_INSTALLED_NOT_RUN',
          'swift_compilation':'NOT_RUN', 'swift_offline_self_tests':'NOT_RUN', 'douyin_network_tests':'NOT_RUN'}
(fixture_root / 'runtime-local-validation.json').write_text(json.dumps(result, indent=2)+'\n')
print(json.dumps({k:v for k,v in result.items() if k != 'checks'}))
