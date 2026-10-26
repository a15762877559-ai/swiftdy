"""Static preparation validation, never a substitute for macOS compilation/decode tests."""
import ast
import json
from pathlib import Path
import subprocess
import tempfile
import sys
import yaml
import single_download

BASE='ad5c7c55f81a290c58378d7c30a54b6b04aaeaeb'
def validate():
    checks=[]
    for name in ('doustudio-single-video-real-download.yml','doustudio-single-video-real-download-offline.yml'):
        p=Path('.github/workflows')/name;data=yaml.safe_load(p.read_text(encoding='utf-8'));trigger=data.get('on',data.get(True))
        assert set(trigger)=={'workflow_dispatch'} and data['permissions']=={'contents':'read'}
        job=data['jobs']['probe'];assert job['runs-on']=='xcode-27' and job['timeout-minutes']==30
        steps=job['steps'];ids=[s.get('id') for s in steps];offline=name.endswith('-offline.yml')
        assert ids.index('compile')<ids.index('offline')<ids.index('redirect_offline')<ids.index('safe_compile')<ids.index('download_offline')
        assert sum('secrets.' in json.dumps(s) for s in steps)==(0 if offline else 1)
        if not offline:
            assert ids.index('download_offline')<ids.index('live')
            assert trigger['workflow_dispatch']['inputs']['authorized_single_video_download']['default'] is False
        for step in steps:
            if step.get('uses','').startswith('actions/checkout@'):
                assert step['uses']=='actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1' and step['with']['persist-credentials'] is False
                if 'ref' in step['with']:assert step['with']['ref']==single_download.previous.base.SHA
            if 'run' in step:
                with tempfile.TemporaryDirectory() as root:
                    script=Path(root)/'step.sh';script.write_text(step['run'],encoding='utf-8')
                    subprocess.run(['C:/Program Files/Git/bin/bash.exe','-n',str(script)],check=True,capture_output=True)
        upload=steps[-1];assert upload['uses']=='actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9'
        names=[line.rsplit('/',1)[-1] for line in upload['with']['path'].splitlines()]
        assert len(names)==len(single_download.ARTIFACTS) and set(names)==set(single_download.ARTIFACTS) and upload['with']['retention-days']==3
        checks.append(dict(file=str(p).replace('\\','/'),status='PASS',checks='manual_two_consents_secret_after_all_suites_pins_shell_artifact_whitelist'))
    for p in Path('runtime-harness').glob('*single_download*.py'):ast.parse(p.read_text(encoding='utf-8'))
    modified=subprocess.check_output(['git','diff',BASE,'--name-only','--diff-filter=M'],text=True).splitlines()
    expected={'runtime-harness/Package.swift','runtime-harness/Sources/RuntimeAcceptance/RuntimeAcceptance.swift',
        'runtime-harness/safe-streaming-tests/Sources/SafeStreamingTests/ControlledTests.swift',
        'runtime-harness/safe-streaming-tests/Sources/SafeStreamingTests/IntegrationMedia.swift',
        'runtime-harness/safe-streaming-tests/Sources/SafeStreamingTests/SafeStreamingTransport.swift'}
    assert set(modified)==expected and not subprocess.check_output(['git','diff',BASE,'--name-only','--diff-filter=D'],text=True).strip()
    path='runtime-harness/safe-streaming-tests/Sources/SafeStreamingTests/SafeStreamingTransport.swift'
    before=subprocess.check_output(['git','show',BASE+':'+path]).decode();current=Path(path).read_text(encoding='utf-8')
    marker='    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data)'
    assert before[before.index(marker):]==current[current.index(marker):]
    assert 'configuration.connectionProxyDictionary' in current and 'metrics.media_requests_started += 1' in current
    bridge=Path('runtime-harness/safe-streaming-tests/Sources/SafeStreamingTests/SingleVideoDownloadBridge.swift').read_text(encoding='utf-8')
    assert 'downloader.download(work:adapted,progress:' in bridge and 'SessionStore(cookie:"",maxRetry:0)' in bridge
    assert 'IntegrationMedia.verifyBoxes' in bridge and 'reader.status == .completed' in bridge and 'start_decoded' in bridge and 'middle_decoded' in bridge and 'end_decoded' in bridge
    checks.append(dict(status='PASS',checks='safe_transport_data_budget_cancel_terminal_logic_unchanged_reused_original_streaming_downloader'))
    return dict(TASK='DOUSTUDIOKIT_SINGLE_VIDEO_REAL_DOWNLOAD_01',WINDOWS_STATIC='PASS',SWIFT_BUILD='NOT_RUN',OFFLINE_SWIFT_DOWNLOAD_TESTS='NOT_RUN',REAL_VIDEO_DOWNLOAD='NOT_RUN',checks=checks)

if __name__=='__main__':
    result=validate()
    if len(sys.argv)>1:Path(sys.argv[1]).write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    else:print(json.dumps(result,indent=2))
