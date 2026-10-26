"""Audit-only fail-closed entry. Intentionally contains no platform or media client."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

SHA = '362dad3d082e9f63c8efd360acc653ba169d40a2'
BLOCKED_EXIT = 78
STATUSES = dict(DOWNLOAD_IMPLEMENTATION_AUDIT='PASS', DOWNLOAD_PREFLIGHT='BLOCKED', RECEIVE_BYTE_LIMIT='NOT_ENFORCED',
                HARNESS_BUILD='NOT_RUN', OFFLINE_SELF_TEST='NOT_RUN', VIDEO_DOWNLOAD='BLOCKED',
                FILE_INTEGRITY='NOT_VERIFIED', MEDIA_DECODE='NOT_VERIFIED', NO_WATERMARK='NOT_TESTED',
                PAGINATION='PASS', RUST_IMPLEMENTATION='NOT_STARTED', UPSTREAM_SOURCE_CHANGED='NO',
                ROOTNETSCOPE_CHANGED='NO', VIDEOFLOW_CHANGED='NO')


def write(folder,name,data):
    (folder/name).write_text(json.dumps(data,indent=2)+'\n',encoding='utf-8')


def input_validation(event):
    inputs=event.get('inputs',{})
    consent=str(inputs.get('authorized_own_session','false')).lower()=='true'
    profile=inputs.get('profile_url','')
    profile_ok=isinstance(profile,str) and re.fullmatch(r'https://www\.douyin\.com/user/[A-Za-z0-9_-]{1,256}',profile) is not None
    index=str(inputs.get('work_index',''))
    index_ok=re.fullmatch(r'0|[1-9][0-9]?',index) is not None and int(index)<50
    return dict(authorized=consent,profile_format_valid=profile_ok,index_syntax_valid=index_ok,
                index_in_actual_worklist='NOT_VERIFIED',valid=consent and profile_ok and index_ok)


def require_hard_limit():
    # Not configurable by workflow input, environment variable, or audit metadata.
    # No network/client factory can run after this gate in the current entry.
    raise RuntimeError('RECEIVE_HARD_LIMIT_NOT_VERIFIED')


def verify_sources(upstream,manifest):
    if manifest['upstream_commit']!=SHA: return False
    for name,expected in manifest['files'].items():
        path=Path(name)
        if path.is_absolute() or '..' in path.parts or not name.startswith('Sources/DouStudioKit/'): return False
        if hashlib.sha256((upstream/path).read_bytes()).hexdigest()!=expected: return False
    return len(manifest['files'])==9


def command(*args):
    return subprocess.check_output(args,text=True,stderr=subprocess.DEVNULL).strip()


def main(mode,env):
    if mode=='initialize':
        folder=Path(env['VIDEO_TEMP'])/'doustudio-single-video-evidence'
        folder.mkdir(parents=True,exist_ok=True)
        statuses=dict(STATUSES); statuses['DOWNLOAD_IMPLEMENTATION_AUDIT']='FAIL'
        write(folder,'final-acceptance.json',{'statuses':statuses,'reason':'AUDIT_PENDING','worklist_requests':0,'media_requests':0,'credential_read':False})
        event=json.loads(Path(env['GITHUB_EVENT_PATH']).read_text(encoding='utf-8'))
        validation=input_validation(event)
        write(folder,'input-validation.json',validation)
        with open(env['GITHUB_ENV'],'a',encoding='utf-8') as f: f.write(f'VIDEO_EVIDENCE_DIR={folder}\n')
        with open(env['GITHUB_OUTPUT'],'a',encoding='utf-8') as f: f.write(f'directory={folder}\n')
        return 0 if validation['valid'] else 2
    folder=Path(env['VIDEO_EVIDENCE_DIR'])
    if mode=='audit':
        manifest=json.loads((Path(__file__).parent/'single_video_audit.json').read_text(encoding='utf-8'))
        actual=command('git','-C','upstream','rev-parse','HEAD')
        clean=not command('git','-C','upstream','status','--porcelain','--untracked-files=no')
        matched=actual==SHA and clean and verify_sources(Path('upstream'),manifest)
        write(folder,'source-audit.json',dict(commit_matches=actual==SHA,tracked_source_clean=clean,source_hashes_match=matched,
              files=manifest['files'],blocking_reasons=manifest['blocking_reasons'],hard_limit_verified=False))
        statuses=dict(STATUSES)
        statuses['DOWNLOAD_IMPLEMENTATION_AUDIT']='PASS' if matched else 'FAIL'
        statuses['UPSTREAM_SOURCE_CHANGED']='NO' if clean else 'YES'
        write(folder,'final-acceptance.json',dict(statuses=statuses,reason='RECEIVE_HARD_LIMIT_NOT_VERIFIED' if matched else 'SOURCE_AUDIT_MISMATCH',worklist_requests=0,media_requests=0,credential_read=False))
        write(folder,'runtime-environment.json',dict(run_id=env['GITHUB_RUN_ID'],test_commit=env['GITHUB_SHA'],upstream_commit=actual,
              macos=command('sw_vers'),swift=command('swift','--version'),xcode=command('xcodebuild','-version'),architecture=command('uname','-m')))
        return 0 if matched else 1
    if mode=='gate':
        try: require_hard_limit()
        except RuntimeError:
            write(folder,'download-gate.json',dict(status='BLOCKED',reason='RECEIVE_HARD_LIMIT_NOT_VERIFIED',media_requests=0,
                  worklist_requests=0,credential_read=False,media_files_created=0,partial_files_created=0,cleanup='NOT_NEEDED_NO_TRANSFER'))
            print('DOWNLOAD_PREFLIGHT=BLOCKED; RECEIVE_BYTE_LIMIT=NOT_ENFORCED; MEDIA_REQUESTS=0')
            return BLOCKED_EXIT
        return 1
    if mode=='finalize':
        write(folder,'stage-outcomes.json',{key:env.get(key,'unknown') for key in ('INIT_OUTCOME','AUDIT_OUTCOME','GATE_TEST_OUTCOME','GATE_OUTCOME')})
        return 0
    return 1


if __name__=='__main__':
    try: code=main(sys.argv[1],os.environ)
    except Exception:
        print('SINGLE_VIDEO_PREFLIGHT_INFRASTRUCTURE_ERROR')
        code=1
    raise SystemExit(code)
