"""Manual probe orchestration. No network at import or during offline bookkeeping."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from auth_preflight import input_values, command, write, SHA
from host_evidence_tests import sanitize_fixture_logs
from live_probe_tests import CASES, POLICY

RESULTS = ('probe-summary.json','host-observations.json','response-header-evidence.json','redirect-evidence.json',
           'credential-isolation-results.json','request-count-results.json','redaction-results.json','approved-hosts.json')
ARTIFACTS = RESULTS + ('evidence-index.json','environment.json','source-protection.json','stage-outcomes.json',
    'input-validation.json','build.log','build-exit-code.txt','baseline.log','baseline-exit-code.txt',
    'offline-exit-code.txt','probe-exit-code.txt','offline-tests.json','policy-tests.json',
    'selftest-results.json','host-selftest-results.json','priority-selftest-results.json','offline-source.json')
HOSTS = {'sf11-cdn-tos.douyinstatic.com','www.douyin.com'}

def fingerprint():
    paths = sorted(p for root in ('runtime-harness','.github/workflows') for p in Path(root).rglob('*')
                   if p.is_file() and p.suffix in ('.swift','.py','.yml') and '.build' not in p.parts)
    return hashlib.sha256(''.join(str(p).replace('\\','/') + ':' + hashlib.sha256(p.read_bytes()).hexdigest() + '\n' for p in paths).encode()).hexdigest()

def seed(folder):
    for name in RESULTS: write(folder,name,[] if name != 'probe-summary.json' else dict(
        PREPARATION='IN_PROGRESS',WINDOWS_STATIC='NOT_RUN',MACOS_SWIFT_BUILD='NOT_RUN',OFFLINE_TESTS='NOT_RUN',
        REAL_MEDIA_PROBE='NOT_RUN',REAL_VIDEO_DOWNLOAD='NOT_RUN',PRODUCTION_ALLOWLIST='EMPTY',APPROVED_HOSTS=0,
        STRICT_NETWORK_RECEIVE_LIMIT='NOT_PROVEN'))
    for name in ('build-exit-code.txt','baseline-exit-code.txt','offline-exit-code.txt','probe-exit-code.txt'):
        (folder/name).write_text('NOT_RUN\n')

def offline_gate(folder):
    for name in ('build-exit-code.txt','baseline-exit-code.txt','offline-exit-code.txt'):
        assert (folder/name).read_text().strip() == '0'
    policy = json.loads((folder/'policy-tests.json').read_text())
    assert set(policy) == POLICY and all(v is True for v in policy.values())
    result = json.loads((folder/'offline-tests.json').read_text())
    assert result['scope'] == 'SYNTHETIC_LOOPBACK_ONLY' and result['status'] == 'PASS'
    assert result['real_worklist_requests'] == result['real_media_requests'] == 0
    rows = result['cases']
    assert len(rows) == len(CASES) and {r['id'] for r in rows} == set(CASES)
    for row in rows:
        assert row['status'] == 'PASS' and row['swift_exit_code'] == 0 and row['server_single_request']
        o = row['observation']
        assert o['accepted_bytes'] <= 1 and o['completion_callbacks'] == 1 and not o['authentication_headers_sent']
        assert not o['cancel_requested'] or o['cancel_completed']
    for name, count in (('selftest-results.json',38),('host-selftest-results.json',20),('priority-selftest-results.json',25)):
        result = json.loads((folder/name).read_text())
        if isinstance(result,dict): result = result['cases']
        assert len(result) == count and len({r['id'] for r in result}) == count
        assert all(r['status'] == 'PASS' for r in result)
    assert json.loads((folder/'offline-source.json').read_text())['sha256'] == fingerprint()

def validate_artifacts(folder):
    assert json.loads((folder/'approved-hosts.json').read_text()) == []
    for name in ARTIFACTS:
        path = folder/name
        if not path.exists() or name == 'evidence-index.json': continue
        text = path.read_text(encoding='utf-8')
        assert not re.search(r'https?(?::|\\u003[aA]|\\u002[fF])|://|Cookie:|Authorization:|a_bogus|x-bogus|fixture_token|DO_NOT_SERIALIZE|PRIVATE_TITLE_MARKER|\b[0-9]{17,20}\b',text,re.I)
        assert 'hidden-media-path' not in text
        if name.endswith('.json'): json.loads(text)
    for name in ('host-observations.json','response-header-evidence.json','redirect-evidence.json'):
        observations = json.loads((folder/name).read_text())
        assert isinstance(observations,list)
        assert len(observations) <= 2 and len({o['host'] for o in observations}) == len(observations)
        for o in observations:
            assert o['host'] in HOSTS and o['request_count'] <= 1 and o['accepted_bytes'] <= 1
            assert not o['approved'] and not o['authentication_headers_sent']
            assert not o['cancel_requested'] or o['cancel_completed']
            assert o['completion_callbacks'] == 1
            if o.get('redirect_host'):
                assert re.fullmatch(r'[a-z0-9.-]{1,253}',o['redirect_host'])

def run_probe(env):
    folder = Path(env['PROBE_EVIDENCE_DIR'])
    # This is mandatory before even looking up the secret or launching the online child.
    offline_gate(folder)
    consent, profile, valid = input_values(env)
    cookie = env.get('DOUYIN_COOKIE','')
    reason = None
    if not consent: reason = 'AUTHORIZATION_REQUIRED'
    elif not valid: reason = 'PROFILE_PARSE_ERROR'
    elif not cookie.strip(): reason = 'CREDENTIAL_MISSING'
    elif any(ord(c)<32 or ord(c)==127 for c in cookie): reason = 'CREDENTIAL_CONFIGURATION_REJECTED'
    if reason:
        summary=json.loads((folder/'probe-summary.json').read_text())
        summary.update(failure_category=reason,media_probe_completed=False)
        write(folder,'probe-summary.json',summary)
        return 2
    child = {k:env[k] for k in ('PATH','TMPDIR','SYSTEMROOT') if k in env}
    child.update(DOUYIN_COOKIE=cookie,PROBE_CONSENT='true',PROBE_PROFILE=profile,PROBE_OFFLINE_VERIFIED='true',
                 PROBE_EVIDENCE_DIR=str(folder))
    try:
        code = subprocess.run([env['PROBE_BIN'],'--media-host-live-probe'],env=child,
            stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=150,check=False).returncode
    except (OSError,subprocess.TimeoutExpired): return 1
    summary = json.loads((folder/'probe-summary.json').read_text())
    if code == 0 and (not summary.get('media_probe_completed') or summary.get('REAL_MEDIA_PROBE') != 'OBSERVATION_COMPLETED'):
        return 1
    return code if code >= 0 else 1

def main(mode, env):
    if mode == 'initialize':
        folder = Path(env['RUNNER_TEMP'])/'doustudio-live-probe'
        folder.mkdir(exist_ok=False); seed(folder)
        live = env.get('PROBE_MODE') == 'live'
        consent, valid = False, True
        if live: consent, _, valid = input_values(env)
        write(folder,'input-validation.json',dict(mode='live' if live else 'offline',authorized=consent,profile_format_valid=valid))
        with open(env['GITHUB_ENV'],'a',encoding='utf-8') as f:
            f.write(f'PROBE_EVIDENCE_DIR={folder}\nHOST_EVIDENCE_DIR={folder}\nEVIDENCE_DIR={folder}\nOFFLINE_RESULTS_PATH={folder}/selftest-results.json\n')
        with open(env['GITHUB_OUTPUT'],'a',encoding='utf-8') as f: f.write(f'directory={folder}\n')
        return 0 if not live or (consent and valid) else 2
    folder = Path(env['PROBE_EVIDENCE_DIR'])
    if mode == 'environment':
        assert command('git','-C','upstream','rev-parse','HEAD') == SHA
        assert not command('git','-C','upstream','status','--porcelain','--untracked-files=no')
        write(folder,'environment.json',dict(upstream_commit=SHA,test_commit=env['GITHUB_SHA'],run_id=env['GITHUB_RUN_ID'],
            macos=command('sw_vers'),swift=command('swift','--version'),xcode=command('xcodebuild','-version')))
    elif mode == 'offline-seal':
        write(folder,'offline-source.json',dict(sha256=fingerprint(),test_commit=env['GITHUB_SHA']))
        offline_gate(folder)
    elif mode == 'run':
        code = run_probe(env); (folder/'probe-exit-code.txt').write_text(str(code)+'\n'); return code
    elif mode == 'finalize':
        actual = command('git','-C','upstream','rev-parse','HEAD')
        clean = not command('git','-C','upstream','status','--porcelain','--untracked-files=no')
        write(folder,'source-protection.json',dict(upstream_commit=actual,tracked_source_clean=clean))
        assert clean and actual == SHA
        write(folder,'stage-outcomes.json',{k:env.get(k,'unknown') for k in ('BUILD_OUTCOME','OFFLINE_OUTCOME','PROBE_OUTCOME')})
        # Only credential-free compiler and baseline logs are present. Online stdout/stderr is discarded.
        sanitize_fixture_logs(folder)
        for name in ('baseline.log',):
            p=folder/name
            if p.exists():
                p.write_text('\n'.join('[REDACTED_FIXTURE_LITERAL_LINE]' if any(s in line for s in ('://','fixture_token','DO_NOT_SERIALIZE','PRIVATE_TITLE_MARKER')) else line for line in p.read_text(errors='replace').splitlines())+'\n')
        summary = json.loads((folder/'probe-summary.json').read_text())
        summary['MACOS_SWIFT_BUILD'] = 'PASS' if (folder/'build-exit-code.txt').read_text().strip() == '0' else 'NOT_PASSED'
        summary['OFFLINE_TESTS'] = 'NOT_PASSED'
        if (folder/'offline-exit-code.txt').read_text().strip() == '0':
            offline_gate(folder); summary['OFFLINE_TESTS'] = 'PASS'
        write(folder,'probe-summary.json',summary)
        write(folder,'redaction-results.json',dict(status='PASS',body_persisted=False,media_files_persisted=False,raw_urls_persisted=False))
        validate_artifacts(folder)
        write(folder,'evidence-index.json',dict(run_id=env['GITHUB_RUN_ID'],test_commit=env['GITHUB_SHA'],upstream_commit=SHA,
            files={name:hashlib.sha256((folder/name).read_bytes()).hexdigest() for name in ARTIFACTS if name!='evidence-index.json' and (folder/name).exists()}))
    else: return 1
    return 0

if __name__ == '__main__':
    try: code = main(sys.argv[1],os.environ)
    except Exception: print('LIVE_PROBE_INFRASTRUCTURE_ERROR'); code = 1
    raise SystemExit(code)
