"""Isolated pagination launcher. No raw exceptions, input URLs, or credentials in output."""
import json
import os
from pathlib import Path
import subprocess
import sys
from auth_preflight import SHA, input_values, write, command

STATUSES = dict(HARNESS_BUILD='NOT_RUN', OFFLINE_SELF_TEST='NOT_RUN', AUTHENTICATED_PROFILE_ACCESS='NOT_RUN',
                FIRST_PAGE_FETCH='NOT_RUN', MULTI_PAGE_FETCH='NOT_RUN', PAGINATION_CURSOR_CHAIN='NOT_VERIFIED',
                PAGINATION_CORRECTNESS='NOT_VERIFIED', VIDEO_DOWNLOAD='NOT_RUN', MEDIA_INTEGRITY='NOT_RUN',
                NO_WATERMARK='NOT_TESTED', RUST_IMPLEMENTATION='NOT_STARTED', UPSTREAM_SOURCE_CHANGED='NO',
                ROOTNETSCOPE_CHANGED='NO', VIDEOFLOW_CHANGED='NO')


def offline_passed(folder):
    try:
        for name, prefix, count in [('selftest-results.json', None, 38), ('pagination-selftest-results.json', 'PAG-', 24)]:
            data = json.loads((folder / name).read_text(encoding='utf-8'))
            cases = data['cases']
            if data['status'] != 'PASS' or data['onlineEntryCalled'] or data['mediaDownloaded']:
                return False
            expected = ({f'OFF-{n:03}' for n in range(1,20)} | {f'AUTH-{n:03}' for n in range(1,20)}) if prefix is None else {f'PAG-{n:03}' for n in range(1,count+1)}
            if len(cases) != count or {c['id'] for c in cases} != expected or any(c['status'] != 'PASS' for c in cases):
                return False
        return (folder / 'build-exit-code.txt').read_text().strip() == '0' and (folder / 'offline-exit-code.txt').read_text().strip() == '0'
    except (OSError, ValueError, KeyError, TypeError):
        return False


def run_pagination(env):
    folder = Path(env['PAGINATION_EVIDENCE_DIR'])
    result = {'statuses':dict(STATUSES), 'request_count':0, 'pages':[], 'pipeline_completed':False}
    # Never start a child unless both exact offline suites passed.
    if not offline_passed(folder):
        result['failure_category'] = 'HARNESS_ERROR'
        result['failure_reason'] = 'OFFLINE_GATE_FAILED'
        write(folder,'pagination-result.json',result)
        return 2
    consent, profile, valid = input_values(env)
    cookie = env.get('DOUYIN_COOKIE','')
    result['credential_present'] = bool(cookie.strip())
    reason = None
    if not consent: reason = 'AUTHORIZATION_REQUIRED'
    elif not result['credential_present']: reason = 'CREDENTIAL_MISSING'
    elif any(ord(c) < 32 or ord(c) == 127 for c in cookie): reason = 'CREDENTIAL_CONFIGURATION_REJECTED'
    elif not valid: reason = 'PROFILE_PARSE_ERROR'
    if reason:
        result['failure_category'] = 'INPUT_REJECTED'
        result['failure_reason'] = reason
        result['statuses']['AUTHENTICATED_PROFILE_ACCESS'] = 'BLOCKED'
        write(folder,'pagination-result.json',result)
        return 2
    child = {k:env[k] for k in ('PATH','TMPDIR','SYSTEMROOT') if k in env}
    child.update(DOUYIN_COOKIE=cookie, AUTH_CONSENT='true', AUTH_PROFILE=profile, PAGINATION_EVIDENCE_DIR=str(folder))
    result.update(request_count=None, failure_category='HARNESS_ERROR', failure_reason='CHILD_DID_NOT_COMPLETE')
    write(folder,'pagination-result.json',result)
    try:
        completed = subprocess.run([env['PAGINATION_BIN'],'--authenticated-pagination'],env=child,
                                   stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=240,check=False)
        final = json.loads((folder/'pagination-result.json').read_text(encoding='utf-8'))
        if completed.returncode != 0: return completed.returncode if completed.returncode > 0 else 1
        if not final.get('pipeline_completed') or final.get('failure_category') or not 1 <= final.get('request_count',0) <= 3:
            return 1
        return 0
    except (OSError, subprocess.TimeoutExpired, ValueError, TypeError):
        return 1


def main(mode, env):
    if mode == 'initialize':
        folder = Path(env['PAGINATION_TEMP'])/'doustudio-auth-pagination'
        folder.mkdir(parents=True,exist_ok=True)
        write(folder,'pagination-result.json',{'statuses':dict(STATUSES),'request_count':0,'pages':[],'pipeline_completed':False})
        for name in ('build-exit-code.txt','offline-exit-code.txt','pagination-exit-code.txt'):
            (folder/name).write_text('NOT_RUN\n',encoding='utf-8')
        with open(env['GITHUB_ENV'],'a',encoding='utf-8') as f:
            f.write(f'PAGINATION_EVIDENCE_DIR={folder}\nOFFLINE_RESULTS_PATH={folder}/selftest-results.json\n')
        with open(env['GITHUB_OUTPUT'],'a',encoding='utf-8') as f: f.write(f'directory={folder}\n')
        consent, _, valid = input_values(env)
        write(folder,'input-validation.json',{'authorized':consent,'profile_format_valid':valid,'result':'PASS' if consent and valid else 'BLOCKED'})
        return 0 if consent and valid else 2
    folder = Path(env['PAGINATION_EVIDENCE_DIR'])
    if mode == 'environment':
        actual = command('git','-C','upstream','rev-parse','HEAD')
        assert actual == SHA
        assert not command('git','-C','upstream','status','--porcelain','--untracked-files=no')
        write(folder,'environment.json',dict(upstream_commit=actual,test_commit=env['GITHUB_SHA'],run_id=env['GITHUB_RUN_ID'],
              macos=command('sw_vers'),swift=command('swift','--version'),xcode=command('xcodebuild','-version'),architecture=command('uname','-m')))
    elif mode == 'run':
        code = run_pagination(env)
        (folder/'pagination-exit-code.txt').write_text(str(code)+'\n',encoding='utf-8')
        return code
    elif mode == 'finalize':
        outcomes = {k:env.get(k,'unknown') for k in ('INIT_OUTCOME','BUILD_OUTCOME','OFFLINE_OUTCOME','PAGINATION_OUTCOME')}
        write(folder,'stage-outcomes.json',outcomes)
        result = json.loads((folder/'pagination-result.json').read_text(encoding='utf-8'))
        states = dict(STATUSES); states.update(result.get('statuses',{}))
        states['HARNESS_BUILD'] = {'success':'PASS','failure':'FAIL'}.get(outcomes['BUILD_OUTCOME'],'NOT_RUN')
        states['OFFLINE_SELF_TEST'] = {'success':'PASS','failure':'FAIL'}.get(outcomes['OFFLINE_OUTCOME'],'NOT_RUN')
        protection_code = 0
        if Path('upstream/.git').exists():
            actual = command('git','-C','upstream','rev-parse','HEAD')
            clean = not command('git','-C','upstream','status','--porcelain','--untracked-files=no')
            write(folder,'source-protection.json',{'upstream_commit':actual,'tracked_source_clean':clean})
            states['UPSTREAM_SOURCE_CHANGED'] = 'NO' if clean else 'YES'
            protection_code = 0 if clean and actual == SHA else 1
        write(folder,'final-acceptance.json',{'statuses':states,'failure_category':result.get('failure_category'),'stop_reason':result.get('stop_reason')})
        return protection_code
    else: return 1
    return 0


if __name__ == '__main__':
    try: code = main(sys.argv[1],os.environ)
    except Exception:
        print('PAGINATION_INFRASTRUCTURE_ERROR')
        code = 1
    raise SystemExit(code)
