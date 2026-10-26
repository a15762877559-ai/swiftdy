"""Offline workflow evidence; no HTTP client, no platform/user inputs."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
SHA = '362dad3d082e9f63c8efd360acc653ba169d40a2'


def write(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n', encoding='utf-8')


def command(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL).strip()


def main():
    mode = sys.argv[1]
    if mode == 'initialize':
        evidence = Path(os.environ['OFFLINE_TEMP']) / 'doustudio-harness-offline'
        evidence.mkdir(parents=True, exist_ok=True)
        with open(os.environ['GITHUB_ENV'], 'a', encoding='utf-8') as stream:
            stream.write(f'EVIDENCE_DIR={evidence}\nOFFLINE_RESULTS_PATH={evidence}/selftest-results.json\n')
        with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as stream:
            stream.write(f'directory={evidence}\n')
        write(evidence / 'selftest-results.json', {'status':'NOT_RUN','cases':[]})
        for name in ['build-exit-code.txt','selftest-exit-code.txt','entry-guard-exit-code.txt']:
            (evidence / name).write_text('NOT_RUN\n')
        return
    evidence = Path(os.environ['EVIDENCE_DIR'])
    upstream = ROOT / 'upstream'
    if mode == 'environment':
        actual = command('git','-C',str(upstream),'rev-parse','HEAD')
        assert actual == SHA
        assert not command('git','-C',str(upstream),'status','--porcelain','--untracked-files=no')
        write(evidence / 'environment.json', {
            'run_id':os.environ['GITHUB_RUN_ID'], 'test_commit':os.environ['GITHUB_SHA'],
            'upstream_commit':actual,'macos':command('sw_vers'), 'swift':command('swift','--version'),
            'xcode':command('xcodebuild','-version'),'architecture':command('uname','-m'),
            'mode':'OFFLINE_ONLY','runner':'xcode-27',
            'source_hashes':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()
                for p in sorted((ROOT / 'runtime-harness/Sources').rglob('*.swift'))}})
    elif mode == 'finalize':
        write(evidence / 'stage-outcomes.json', {key:os.environ.get(key,'unknown')
            for key in ['BUILD_OUTCOME','SELFTEST_OUTCOME']})
        exists = (upstream / '.git').exists()
        clean = exists and not command('git','-C',str(upstream),'status','--porcelain','--untracked-files=no')
        actual = command('git','-C',str(upstream),'rev-parse','HEAD') if exists else None
        write(evidence / 'source-protection.json', {'upstream_commit':actual, 'tracked_source_clean':clean})
        if exists and (not clean or actual != SHA):
            raise RuntimeError('Upstream protection failed')
    else:
        raise ValueError('Unknown offline evidence mode')


if __name__ == '__main__':
    main()
