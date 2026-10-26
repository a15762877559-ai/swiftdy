"""Offline workflow bookkeeping only. Never invokes an online harness mode."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

SHA='362dad3d082e9f63c8efd360acc653ba169d40a2'
RESULTS=('selected-work-evidence.json','selected-host-summary.json','alternate-host-summary.json',
    'source-association-results.json','quota-integrity-results.json','security-redaction-results.json')
ARTIFACTS=RESULTS+('evidence-index.json','environment.json','build-exit-code.txt','offline-exit-code.txt',
    'build.log','offline.log','selftest-results.json','host-selftest-results.json','priority-selftest-results.json',
    'stage-outcomes.json','source-protection.json','approved-hosts.json')

def write(folder,name,data):
    (folder/name).write_text(json.dumps(data,indent=2)+'\n',encoding='utf-8')
def command(*args):return subprocess.check_output(args,text=True,stderr=subprocess.DEVNULL).strip()

def verify(folder):
    assert json.loads((folder/'approved-hosts.json').read_text())==[]
    for name in RESULTS:
        text=(folder/name).read_text()
        for marker in ('://','https:\\','hidden-media-path','fixture_token','DO_NOT_SERIALIZE','PRIVATE_TITLE_MARKER','1000000000000000000','Cookie:','Authorization:'):
            assert marker not in text
    if (folder/'offline-exit-code.txt').read_text().strip()=='0':
        original=json.loads((folder/'selftest-results.json').read_text())['cases']
        host=json.loads((folder/'host-selftest-results.json').read_text())
        priority=json.loads((folder/'priority-selftest-results.json').read_text())
        assert len(original)==38 and len(host)==20 and len(priority)==25
        assert all(row['status']=='PASS' for row in original+host+priority)
        selected=json.loads((folder/RESULTS[0]).read_text());hosts=json.loads((folder/RESULTS[1]).read_text())
        assert len(selected)==21 and all(s['selection_match'] for s in selected)
        assert len({s['work_ref'] for s in selected})==21
        assert sum(h['selected_work_count'] for h in hosts)==21 and sum(h['matched_work_count'] for h in hosts)==21
        quota=json.loads((folder/'quota-integrity-results.json').read_text())
        assert quota['ALTERNATE_SUMMARY_TRUNCATED']=='true' and quota['primary_complete']=='true'
        assert quota['alternate_urls_examined']=='1000'

def sanitize_fixture_logs(folder):
    # A compiler diagnostic can quote a synthetic URL literal from source. Keep the
    # diagnostic location/category, but exclude literal-bearing lines from artifacts.
    markers=('://','https:\\','hidden-media-path','fixture_token','DO_NOT_SERIALIZE','PRIVATE_TITLE_MARKER','1000000000000000000','Cookie:','Authorization:')
    for name in ('build.log','offline.log'):
        path=folder/name
        if path.is_file():
            lines=path.read_text(errors='replace').splitlines()
            path.write_text('\n'.join('[REDACTED_FIXTURE_LITERAL_LINE]' if any(m in line for m in markers) else line for line in lines)+'\n',encoding='utf-8')

def main(mode,env):
    if mode=='initialize':
        folder=Path(env['HOST_TEMP'])/'doustudio-host-evidence-offline';folder.mkdir(parents=True,exist_ok=False)
        for name in RESULTS:write(folder,name,dict(status='NOT_RUN',fixture='SYNTHETIC_ONLY'))
        write(folder,'approved-hosts.json',[])
        for name in ('build-exit-code.txt','offline-exit-code.txt'):(folder/name).write_text('NOT_RUN\n')
        with open(env['GITHUB_ENV'],'a',encoding='utf-8') as f:
            f.write(f'HOST_EVIDENCE_DIR={folder}\nEVIDENCE_DIR={folder}\nOFFLINE_RESULTS_PATH={folder}/selftest-results.json\n')
        with open(env['GITHUB_OUTPUT'],'a',encoding='utf-8') as f:f.write(f'directory={folder}\n')
        return 0
    folder=Path(env['HOST_EVIDENCE_DIR'])
    if mode=='environment':
        assert command('git','-C','upstream','rev-parse','HEAD')==SHA
        write(folder,'environment.json',dict(upstream_sha=SHA,test_commit=env['GITHUB_SHA'],run_id=env['GITHUB_RUN_ID'],
            macos=command('sw_vers'),swift=command('swift','--version'),xcode=command('xcodebuild','-version'),architecture=command('uname','-m')))
    elif mode=='finalize':
        write(folder,'stage-outcomes.json',{k:env.get(k,'unknown') for k in ('BUILD_OUTCOME','OFFLINE_OUTCOME')})
        clean=not command('git','-C','upstream','status','--porcelain','--untracked-files=no')
        actual=command('git','-C','upstream','rev-parse','HEAD')
        write(folder,'source-protection.json',dict(upstream_sha=actual,clean=clean));assert clean and actual==SHA
        verify(folder)
        sanitize_fixture_logs(folder)
        write(folder,'evidence-index.json',dict(run_id=env['GITHUB_RUN_ID'],test_commit=env['GITHUB_SHA'],
            files={name:hashlib.sha256((folder/name).read_bytes()).hexdigest() for name in ARTIFACTS if name!='evidence-index.json' and (folder/name).is_file()},
            fixture='SYNTHETIC_ONLY',REAL_WORKLIST_REQUEST='NOT_RUN',REAL_MEDIA_REQUEST='NOT_RUN'))
    else:return 1
    return 0

if __name__=='__main__':
    try: code=main(sys.argv[1],os.environ)
    except Exception: print('HOST_EVIDENCE_OFFLINE_INFRASTRUCTURE_ERROR');code=1
    raise SystemExit(code)
