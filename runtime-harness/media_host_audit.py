"""Manual one-list-request host observation; never opens any media address."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
from auth_preflight import input_values, command, write, SHA

AUDIT_FILES = ('candidate-hosts.json','host-provenance.json','host-security-review.json','approved-hosts.json','audit-summary.json')
ARTIFACT_FILES = AUDIT_FILES + ('evidence-index.json','input-validation.json','environment.json','source-protection.json',
    'stage-outcomes.json','build.log','build-exit-code.txt','offline.log','offline-exit-code.txt',
    'selftest-results.json','host-selftest-results.json','audit-exit-code.txt')

def seed(folder):
    for name in AUDIT_FILES[:4]: write(folder,name,[])
    write(folder,'audit-summary.json',dict(collection_completed=False,HOST_SECURITY_REVIEW='BLOCKED',
        PRODUCTION_ALLOWLIST='EMPTY',APPROVED_HOSTS=0,REAL_MEDIA_REQUEST='NOT_RUN',REAL_VIDEO_DOWNLOAD='NOT_RUN',
        APPLICATION_BYTE_BUDGET='PASS',byte_budget_evidence_run='40289436585',STRICT_NETWORK_RECEIVE_LIMIT='NOT_PROVEN'))

def run_audit(env):
    folder=Path(env['HOST_EVIDENCE_DIR']);cookie=env.get('DOUYIN_COOKIE','')
    consent,profile,valid=input_values(env);present=bool(cookie.strip())
    reason=None
    if not consent:reason='AUTHORIZATION_REQUIRED'
    elif not present:reason='CREDENTIAL_MISSING'
    elif any(ord(c)<32 or ord(c)==127 for c in cookie):reason='CREDENTIAL_CONFIGURATION_REJECTED'
    elif not valid:reason='PROFILE_PARSE_ERROR'
    summary=json.loads((folder/'audit-summary.json').read_text())
    summary.update(credential_present=present,failure_category=reason or 'HARNESS_ERROR',
        observation={'request_started':False if reason else None,'request_count':0 if reason else None})
    write(folder,'audit-summary.json',summary)
    if reason:return 2
    # No inherited credential providers, stdout/stderr capture, raw URL, or credential file.
    child={k:env[k] for k in ('PATH','TMPDIR','SYSTEMROOT') if k in env}
    child.update(DOUYIN_COOKIE=cookie,HOST_CONSENT='true',HOST_PROFILE=profile,HOST_EVIDENCE_DIR=str(folder))
    try:
        code=subprocess.run([env['HOST_BIN'],'--media-host-audit'],env=child,stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,timeout=180,check=False).returncode
    except (OSError,subprocess.TimeoutExpired):return 1
    final=json.loads((folder/'audit-summary.json').read_text())
    if code==0 and not final.get('collection_completed'):return 1
    return code if code>=0 else 1

def finalize(folder,env):
    write(folder,'stage-outcomes.json',{k:env.get(k,'unknown') for k in ('BUILD_OUTCOME','OFFLINE_OUTCOME','AUDIT_OUTCOME')})
    if Path('upstream/.git').exists():
        sha=command('git','-C','upstream','rev-parse','HEAD')
        clean=not command('git','-C','upstream','status','--porcelain','--untracked-files=no')
        write(folder,'source-protection.json',dict(upstream_commit=sha,tracked_source_clean=clean))
        assert clean and sha==SHA
    # Audit JSON is a one-way, host-only boundary. Refuse artifact upload on a broken serializer.
    assert json.loads((folder/'approved-hosts.json').read_text())==[]
    for name in AUDIT_FILES:
        text=(folder/name).read_text()
        assert '://' not in text and 'Cookie:' not in text and 'Authorization:' not in text
        assert 'a_bogus' not in text.lower() and 'x-bogus' not in text.lower()
    files={name:hashlib.sha256((folder/name).read_bytes()).hexdigest() for name in ARTIFACT_FILES if name!='evidence-index.json' and (folder/name).is_file()}
    write(folder,'evidence-index.json',dict(run_id=env.get('GITHUB_RUN_ID','NOT_RUN'),test_commit=env.get('GITHUB_SHA','NOT_RUN'),
        upstream_commit=SHA,files=files,automatic_host_approval=False,media_requests=0))

def main(mode,env):
    if mode=='initialize':
        folder=Path(env['HOST_TEMP'])/'doustudio-media-host-audit';folder.mkdir(parents=True,exist_ok=False)
        seed(folder)
        for name in ('build-exit-code.txt','offline-exit-code.txt','audit-exit-code.txt'):(folder/name).write_text('NOT_RUN\n')
        with open(env['GITHUB_ENV'],'a',encoding='utf-8') as f:
            f.write(f'HOST_EVIDENCE_DIR={folder}\nEVIDENCE_DIR={folder}\nOFFLINE_RESULTS_PATH={folder}/selftest-results.json\n')
        with open(env['GITHUB_OUTPUT'],'a',encoding='utf-8') as f:f.write(f'directory={folder}\n')
        consent,_,valid=input_values(env)
        write(folder,'input-validation.json',dict(authorized=consent,profile_format_valid=valid))
        return 0 if consent and valid else 2
    folder=Path(env['HOST_EVIDENCE_DIR'])
    if mode=='environment':
        actual=command('git','-C','upstream','rev-parse','HEAD');assert actual==SHA
        assert not command('git','-C','upstream','status','--porcelain','--untracked-files=no')
        write(folder,'environment.json',dict(upstream_commit=actual,test_commit=env['GITHUB_SHA'],run_id=env['GITHUB_RUN_ID'],
            macos=command('sw_vers'),swift=command('swift','--version'),xcode=command('xcodebuild','-version'),architecture=command('uname','-m')))
    elif mode=='run':
        code=run_audit(env);(folder/'audit-exit-code.txt').write_text(str(code)+'\n');return code
    elif mode=='finalize':finalize(folder,env)
    else:return 1
    return 0

if __name__=='__main__':
    try: code=main(sys.argv[1],os.environ)
    except Exception: print('HOST_AUDIT_INFRASTRUCTURE_ERROR');code=1
    raise SystemExit(code)
