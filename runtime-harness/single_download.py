"""Two-stage acceptance. This module never downloads at import or during local validation."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import uuid
import hashlib
import redirect_probe as previous
from auth_preflight import write,input_values
from single_download_tests import CASES,POLICY,SUCCESS

RESULTS=('download-summary.json','request-counts.json','download-budget.json','redirect-security.json','media-integrity.json','decode-results.json','cleanup-results.json','transfer-results.json')
EXTRA=RESULTS+('download-policy-tests.json','download-offline-tests.json','controlled-results.json','integration-results.json',
    'transport-cleanup.json','integration-cleanup.json','offline-media-cleanup.json','legacy-build.log','legacy-build-exit-code.txt','download-offline-exit-code.txt')
ARTIFACTS=previous.ARTIFACTS+EXTRA
STATUS_KEYS=('SWIFT_BUILD','OFFLINE_TESTS','REAL_WORKLIST','REDIRECT_RESOLUTION','REAL_VIDEO_DOWNLOAD','APPLICATION_BYTE_BUDGET','MEDIA_FILE_INTEGRITY','MEDIA_DECODE','FULL_DECODE','TEMP_FILE_CLEANUP')
MARKERS=('://','https:\\','fixture_token','DO_NOT_SERIALIZE','PRIVATE_TITLE_MARKER','Cookie:','Authorization:','a_bogus','x-bogus','hidden-media-path')

def seed(folder):
    for name in EXTRA:
        if name.endswith('.json'): write(folder,name,dict(status='NOT_RUN'))
    for name in ('legacy-build-exit-code.txt','download-offline-exit-code.txt'): (folder/name).write_text('NOT_RUN\n')
    write(folder,'download-summary.json',dict(TASK='DOUSTUDIOKIT_SINGLE_VIDEO_REAL_DOWNLOAD_01',**{k:'NOT_RUN' for k in STATUS_KEYS},
        NO_WATERMARK='NOT_VERIFIED',PRODUCTION_ALLOWLIST='EMPTY',RUST_IMPLEMENTATION='NOT_STARTED',AUTO_TRIGGERED='NO',completed=False))
    write(folder,'request-counts.json',dict(worklist=0,entry=0,cdn=0,retries=0))

def download_consent(env):
    event=json.loads(Path(env['GITHUB_EVENT_PATH']).read_text(encoding='utf-8'))
    return str(event.get('inputs',{}).get('authorized_single_video_download','false')).lower()=='true'

def offline_gate(folder):
    previous.offline_gate(folder)
    assert (folder/'legacy-build-exit-code.txt').read_text().strip()=='0'
    assert (folder/'download-offline-exit-code.txt').read_text().strip()=='0'
    policy=json.loads((folder/'download-policy-tests.json').read_text())
    assert set(policy)==POLICY and all(v is True for v in policy.values())
    for name in ('controlled-results.json','integration-results.json'):
        data=json.loads((folder/name).read_text()); rows=data['cases']
        assert data['status']=='PASS' and len(rows)==28 and len({r['id'] for r in rows})==28 and all(r['status']=='PASS' for r in rows)
    data=json.loads((folder/'download-offline-tests.json').read_text())
    assert data['scope']=='SYNTHETIC_LOOPBACK_ONLY' and data['status']=='PASS' and data['real_worklist_requests']==data['real_media_requests']==0
    assert len(data['cases'])==len(CASES) and {r['id'] for r in data['cases']}==set(CASES)
    for row in data['cases']:
        result=row['result']; metrics=result['metrics']
        assert row['status']=='PASS' and row['swift_exit_code']==0 and row['server_single_request_and_headers']
        assert result['success']==(row['id'] in SUCCESS) and result['TEMP_FILE_CLEANUP']=='PASS'
        assert metrics['media_requests_started']==1 and metrics['buffered_send_calls']==0 and metrics['completion_received']
        assert metrics['accepted_bytes']<=104857600 and result['written_bytes']<=104857600
        if metrics['cancel_requested']: assert metrics['cancel_completed']

def safe_value(value):
    if isinstance(value,str):
        assert not any(marker.lower() in value.lower() for marker in MARKERS)
        assert not re.fullmatch(r'\d{17,20}',value)
    elif isinstance(value,dict):
        for key,child in value.items(): safe_value(key);safe_value(child)
    elif isinstance(value,list):
        for child in value:safe_value(child)
    elif isinstance(value,int): assert abs(value)<10**16

def verify(folder):
    assert json.loads((folder/'approved-hosts.json').read_text())==[]
    for name in ARTIFACTS:
        path=folder/name
        if not path.exists() or name=='evidence-index.json': continue
        text=path.read_text(encoding='utf-8')
        if name.endswith('.json'): safe_value(json.loads(text))
        else: assert not any(marker.lower() in text.lower() for marker in MARKERS)
    counts=json.loads((folder/'request-counts.json').read_text())
    assert counts['retries']==0 and all(counts[k] is None or 0<=counts[k]<=1 for k in ('worklist','entry','cdn'))
    summary=json.loads((folder/'download-summary.json').read_text())
    assert summary['PRODUCTION_ALLOWLIST']=='EMPTY' and summary['NO_WATERMARK']=='NOT_VERIFIED'
    if summary.get('completed'):
        assert all(summary[k]=='PASS' for k in STATUS_KEYS if k not in ('SWIFT_BUILD','OFFLINE_TESTS'))
        assert counts==dict(worklist=1,entry=1,cdn=1,retries=0)
        transfer=json.loads((folder/'transfer-results.json').read_text())
        assert transfer['success'] and transfer['media']['full_decode_completed']
        assert transfer['media']['start_decoded'] and transfer['media']['middle_decoded'] and transfer['media']['end_decoded']
        assert transfer['media']['repeated_sha256_matches'] and 0<transfer['written_bytes']<=104857600
        assert transfer['written_bytes']==transfer['metrics']['accepted_bytes']==transfer['media']['file_bytes']
        assert summary['target_network_check']=='PASS_PUBLIC_DNS_AND_NUMERIC_ADDRESS_PIN'

def cleanup_media(env):
    folder=Path(env['DOWNLOAD_EVIDENCE_DIR'])
    root=Path(env['DOWNLOAD_MEDIA_ROOT']); parent=Path(env['RUNNER_TEMP']).resolve()
    assert root.parent.resolve()==parent and root.name.startswith('doustudio-single-video-media-') and not root.is_symlink()
    residual=sum(p.is_file() for p in root.rglob('*')) if root.exists() else 0
    if root.exists(): shutil.rmtree(root)
    result=json.loads((folder/'cleanup-results.json').read_text())
    result.update(wrapper_cleanup='PASS' if not root.exists() else 'FAIL',wrapper_residual_files_before_cleanup=max(residual,result.get('wrapper_residual_files_before_cleanup',0)))
    write(folder,'cleanup-results.json',result)
    assert not root.exists()

def run_download(env):
    folder=Path(env['DOWNLOAD_EVIDENCE_DIR']);offline_gate(folder)
    consent,profile,valid=input_values(env)
    cookie=env.get('DOUYIN_COOKIE','')
    if not consent or not valid or not download_consent(env) or not cookie.strip() or any(ord(c)<32 or ord(c)==127 for c in cookie):return 2
    child={k:env[k] for k in ('PATH','TMPDIR','SYSTEMROOT') if k in env}
    child.update(DOUYIN_COOKIE=cookie,DOWNLOAD_PROFILE=profile,DOWNLOAD_CONSENT='true',REAL_DOWNLOAD_AUTHORIZED='true',DOWNLOAD_OFFLINE_VERIFIED='true',
        DOWNLOAD_EVIDENCE_DIR=str(folder),DOWNLOAD_MEDIA_ROOT=env['DOWNLOAD_MEDIA_ROOT'])
    write(folder,'request-counts.json',dict(worklist=None,entry=None,cdn=None,retries=0))
    try:
        try: code=subprocess.run([env['PROBE_BIN'],'--single-video-real-download'],env=child,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=420,check=False).returncode
        except (OSError,subprocess.TimeoutExpired):
            summary=json.loads((folder/'download-summary.json').read_text());summary.update(failure_category='CHILD_START_OR_TIMEOUT',REAL_VIDEO_DOWNLOAD='FAIL',result_evidence_available=False)
            write(folder,'download-summary.json',summary);return 1
        summary=json.loads((folder/'download-summary.json').read_text())
        if code==0 and not summary.get('completed'):return 1
        return code if code>=0 else 1
    finally: cleanup_media(env)

def main(mode,env):
    if mode=='initialize':
        code=previous.main(mode,env);folder=Path(env['RUNNER_TEMP'])/'doustudio-live-probe';seed(folder)
        media=Path(env['RUNNER_TEMP'])/('doustudio-single-video-media-'+uuid.uuid4().hex);media.mkdir()
        with open(env['GITHUB_ENV'],'a',encoding='utf-8') as output:output.write(f'DOWNLOAD_EVIDENCE_DIR={folder}\nDOWNLOAD_MEDIA_ROOT={media}\n')
        if env.get('PROBE_MODE')=='live' and not download_consent(env):return 2
        return code
    folder=Path(env['DOWNLOAD_EVIDENCE_DIR'])
    if mode=='environment':return previous.main(mode,env)
    if mode=='offline-seal':offline_gate(folder)
    elif mode=='run':return run_download(env)
    elif mode=='finalize':
        cleanup_media(env)
        previous.base.main(mode,env)
        for name in ('legacy-build.log',):
            path=folder/name
            if path.exists():path.write_text('\n'.join('[REDACTED_FIXTURE_LITERAL_LINE]' if any(marker in line for marker in MARKERS) else line for line in path.read_text(errors='replace').splitlines())+'\n',encoding='utf-8')
        summary=json.loads((folder/'download-summary.json').read_text())
        build_codes=[(folder/name).read_text().strip() for name in ('build-exit-code.txt','legacy-build-exit-code.txt')]
        summary['SWIFT_BUILD']='PASS' if all(code=='0' for code in build_codes) else ('FAIL' if any(code not in ('0','NOT_RUN') for code in build_codes) else 'NOT_RUN')
        offline_code=(folder/'download-offline-exit-code.txt').read_text().strip()
        if offline_code=='0':offline_gate(folder);summary['OFFLINE_TESTS']='PASS'
        elif offline_code!='NOT_RUN':summary['OFFLINE_TESTS']='FAIL'
        write(folder,'download-summary.json',summary)
        verify(folder)
        write(folder,'evidence-index.json',dict(task='DOUSTUDIOKIT_SINGLE_VIDEO_REAL_DOWNLOAD_01',run_id=env['GITHUB_RUN_ID'],test_commit=env['GITHUB_SHA'],upstream_commit=previous.base.SHA,
            files={name:hashlib.sha256((folder/name).read_bytes()).hexdigest() for name in ARTIFACTS if name!='evidence-index.json' and (folder/name).exists()}))
    else:return 1
    return 0

if __name__=='__main__':
    try:code=main(sys.argv[1],os.environ)
    except Exception:print('SINGLE_VIDEO_ACCEPTANCE_INFRASTRUCTURE_ERROR');code=1
    raise SystemExit(code)
