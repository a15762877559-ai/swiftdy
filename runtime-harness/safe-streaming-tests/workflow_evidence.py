import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

SHA='362dad3d082e9f63c8efd360acc653ba169d40a2'
def write(folder,name,obj): (folder/name).write_text(json.dumps(obj,indent=2)+'\n',encoding='utf-8')
def command(*args):return subprocess.check_output(args,text=True,stderr=subprocess.DEVNULL).strip()
def main():
    mode=sys.argv[1]
    if mode=='initialize':
        root=Path(tempfile.mkdtemp(prefix='doustudio-safe-streaming-',dir=os.environ['SAFE_TEMP']))
        folder=root/'evidence';folder.mkdir()
        for name in ('build-exit-code.txt','runner-exit-code.txt'): (folder/name).write_text('NOT_RUN\n')
        with open(os.environ['GITHUB_ENV'],'a') as f:f.write(f'SAFE_EVIDENCE_ROOT={folder}\nSAFE_MEDIA_ROOT={root}/media\n')
        with open(os.environ['GITHUB_OUTPUT'],'a') as f:f.write(f'directory={folder}\n')
        return 0
    folder=Path(os.environ['SAFE_EVIDENCE_ROOT'])
    if mode=='environment':
        actual=command('git','-C','upstream','rev-parse','HEAD');assert actual==SHA
        write(folder,'runtime-environment.json',dict(upstream_commit=actual,test_commit=os.environ['GITHUB_SHA'],run_id=os.environ['GITHUB_RUN_ID'],
              macos=command('sw_vers'),swift=command('swift','--version'),xcode=command('xcodebuild','-version'),architecture=command('uname','-m')))
    elif mode=='finalize':
        clean=not command('git','-C','upstream','status','--porcelain','--untracked-files=no')
        actual=command('git','-C','upstream','rev-parse','HEAD')
        write(folder,'source-protection.json',dict(tracked_source_clean=clean,upstream_commit=actual))
        write(folder,'stage-outcomes.json',{k:os.environ.get(k,'unknown') for k in ('BUILD_OUTCOME','TEST_OUTCOME')})
        return 0 if clean and actual==SHA else 1
    return 0
if __name__=='__main__':
    try:code=main()
    except Exception:print('SAFE_STREAMING_EVIDENCE_ERROR');code=1
    raise SystemExit(code)
