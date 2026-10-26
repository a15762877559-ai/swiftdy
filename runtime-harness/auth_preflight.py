"""Credential is read only by run mode; never serialized or logged."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys

SHA = '362dad3d082e9f63c8efd360acc653ba169d40a2'
STATUSES = dict(AUTH_PREFLIGHT='NOT_RUN', COOKIE_CONFIGURATION='NOT_RUN', PROFILE_RESOLUTION='NOT_RUN',
                WORKLIST_FETCH='NOT_RUN', AUTHENTICATED_ACCESS_ACCEPTED='UNKNOWN', PAGINATION='NOT_RUN',
                VIDEO_DOWNLOAD='NOT_RUN', SIGNATURE_REVERSE_ENGINEERING='NOT_STARTED', RUST_IMPLEMENTATION='NOT_STARTED')


def write(folder, name, data):
    (folder / name).write_text(json.dumps(data, indent=2) + '\n', encoding='utf-8')


def input_values(env):
    event = json.loads(Path(env['GITHUB_EVENT_PATH']).read_text(encoding='utf-8'))
    inputs = event.get('inputs', {})
    consent = str(inputs.get('authorized_own_session', 'false')).lower() == 'true'
    profile = inputs.get('profile_url', '')
    valid = isinstance(profile, str) and re.fullmatch(r'https://www\.douyin\.com/user/[A-Za-z0-9_-]{1,256}', profile) is not None
    return consent, profile, valid


def run_preflight(env):
    folder = Path(env['AUTH_EVIDENCE_DIR'])
    cookie = env.get('DOUYIN_COOKIE', '')
    present = bool(cookie.strip())
    result = {'credential_present': present, 'statuses': dict(STATUSES),
              'observation': {'request_started': False, 'request_count': 0}}
    result['statuses']['COOKIE_CONFIGURATION'] = 'READY' if present else 'MISSING'
    result['statuses']['AUTH_PREFLIGHT'] = 'BLOCKED'
    consent, profile, valid = input_values(env)
    reason = None
    if not consent:
        reason = 'AUTHORIZATION_REQUIRED'
    elif not present:
        reason = 'CREDENTIAL_MISSING'
    elif any(ord(c) < 32 or ord(c) == 127 for c in cookie):
        reason = 'CREDENTIAL_CONFIGURATION_REJECTED'
    elif not valid:
        reason = 'PROFILE_PARSE_ERROR'
        result['statuses']['PROFILE_RESOLUTION'] = 'FAIL'
    if reason:
        result['failure_category'] = reason
        write(folder, 'auth-result.json', result)
        return 2
    # Only this child receives the secret. Never use GITHUB_ENV, argv or a file.
    child = {k: env[k] for k in ('PATH', 'TMPDIR', 'SYSTEMROOT') if k in env}
    child.update(DOUYIN_COOKIE=cookie, AUTH_CONSENT='true', AUTH_PROFILE=profile, AUTH_EVIDENCE_DIR=str(folder))
    # Persist no speculative request state. Swift will overwrite this with real outcomes.
    result['statuses']['AUTH_PREFLIGHT'] = 'FAIL'
    result['failure_category'] = 'HARNESS_ERROR'
    result['observation'] = {'request_started': None, 'request_count': None}
    write(folder, 'auth-result.json', result)
    try:
        completed = subprocess.run([env['AUTH_BIN'], '--authenticated-preflight'], env=child,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=180, check=False)
        code = completed.returncode
    except (OSError, subprocess.TimeoutExpired):
        return 1
    final = json.loads((folder / 'auth-result.json').read_text(encoding='utf-8'))
    if code == 0 and final.get('statuses', {}).get('AUTH_PREFLIGHT') != 'PASS':
        return 1
    return code if code >= 0 else 1


def command(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL).strip()


def main(mode, env):
    if mode == 'initialize':
        folder = Path(env['AUTH_TEMP']) / 'doustudio-auth-preflight'
        folder.mkdir(parents=True, exist_ok=True)
        write(folder, 'auth-result.json', {'statuses': dict(STATUSES)})
        for name in ('build-exit-code.txt', 'offline-exit-code.txt', 'auth-exit-code.txt'):
            (folder / name).write_text('NOT_RUN\n')
        with open(env['GITHUB_ENV'], 'a', encoding='utf-8') as f:
            f.write(f'AUTH_EVIDENCE_DIR={folder}\nEVIDENCE_DIR={folder}\nOFFLINE_RESULTS_PATH={folder}/selftest-results.json\n')
        with open(env['GITHUB_OUTPUT'], 'a', encoding='utf-8') as f:
            f.write(f'directory={folder}\n')
        consent, _, valid = input_values(env)
        if not consent or not valid:
            write(folder, 'input-validation.json', {'authorized':consent, 'profile_format_valid':valid, 'result':'BLOCKED'})
            return 2
        write(folder, 'input-validation.json', {'authorized':True, 'profile_format_valid':True, 'result':'PASS'})
        return 0
    folder = Path(env['AUTH_EVIDENCE_DIR'])
    if mode == 'environment':
        actual = command('git', '-C', 'upstream', 'rev-parse', 'HEAD')
        assert actual == SHA
        assert not command('git', '-C', 'upstream', 'status', '--porcelain', '--untracked-files=no')
        write(folder, 'environment.json', dict(upstream_commit=actual, test_commit=env['GITHUB_SHA'], run_id=env['GITHUB_RUN_ID'],
             macos=command('sw_vers'), swift=command('swift','--version'), xcode=command('xcodebuild','-version'), architecture=command('uname','-m')))
    elif mode == 'run':
        code = run_preflight(env)
        (folder / 'auth-exit-code.txt').write_text(str(code) + '\n')
        return code
    elif mode == 'finalize':
        write(folder, 'stage-outcomes.json', {k:env.get(k,'unknown') for k in ('INIT_OUTCOME','BUILD_OUTCOME','OFFLINE_OUTCOME','AUTH_OUTCOME')})
        if Path('upstream/.git').exists():
            actual = command('git','-C','upstream','rev-parse','HEAD')
            clean = not command('git','-C','upstream','status','--porcelain','--untracked-files=no')
            write(folder, 'source-protection.json', {'upstream_commit':actual, 'tracked_source_clean':clean})
            return 0 if clean and actual == SHA else 1
    else:
        return 1
    return 0


if __name__ == '__main__':
    try:
        exit_code = main(sys.argv[1], os.environ)
    except Exception:
        print('AUTH_PREFLIGHT_INFRASTRUCTURE_ERROR') # Fixed message, never exception text.
        exit_code = 1
    raise SystemExit(exit_code)
