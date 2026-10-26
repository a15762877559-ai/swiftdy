"""Invoke real Swift processes, not a Python model of the integration."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

def main():
    evidence=Path(os.environ['SAFE_EVIDENCE_ROOT']).resolve();root=evidence.parent
    media=Path(os.environ['SAFE_MEDIA_ROOT']).resolve();assert media.parent==root and media.name=='media'
    media.mkdir();control=root/'integration-control';control.mkdir();fixtures=control/'fixtures';fixtures.mkdir()
    child={k:os.environ[k] for k in ('PATH','TMPDIR','HOME') if k in os.environ}
    child.update(INT_FIXTURE_ROOT=str(fixtures),SAFE_MEDIA_ROOT=str(media),SAFE_EVIDENCE_ROOT=str(evidence))
    logs=[];results=[];server=None;counters={};generator_code=None
    try:
        generated=subprocess.run([os.environ['SAFE_BINARY'],'--integration-fixture'],env=child,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,timeout=60)
        generator_code=generated.returncode
        logs += [line for line in generated.stdout.splitlines() if line.startswith('FIXTURE_GENERATION=')]
        if generator_code!=0:raise RuntimeError('FIXTURE_GENERATION_FAILED')
        server=subprocess.Popen([sys.executable,'-B',str(Path(__file__).with_name('integration_server.py')),'--root',str(control)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        for _ in range(100):
            if (control/'ready.json').exists():break
            if server.poll() is not None:raise RuntimeError('SERVER_START_FAILED')
            time.sleep(.05)
        port=json.loads((control/'ready.json').read_text())['port'];assert 1024<=port<=65535
        deadline=time.monotonic()+600
        for number in range(1,29):
            case=f'INT-{number:03}'
            if time.monotonic()>=deadline:raise RuntimeError('SUITE_DEADLINE')
            env=dict(child,INT_CASE=case,INT_PORT=str(port))
            process=subprocess.Popen([os.environ['SAFE_BINARY'],'--integration-case'],env=env,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
            timed_out=False
            try:output,_=process.communicate(timeout=60)
            except subprocess.TimeoutExpired:timed_out=True;process.kill();output,_=process.communicate()
            logs += [line for line in output.splitlines() if line.startswith(case+' ')]
            path=evidence/(case+'.json')
            result=json.loads(path.read_text()) if path.exists() else {'id':case,'status':'FAIL','actual':'NO_SWIFT_RESULT','assertions':[]}
            result['exit_code']=process.returncode;result['process_timed_out']=timed_out
            if process.returncode!=0:result['status']='FAIL'
            results.append(result)
    except Exception:
        logs.append('INTEGRATION_INFRASTRUCTURE_ERROR')
    finally:
        if server is not None:
            server.terminate()
            try:server.wait(timeout=5)
            except subprocess.TimeoutExpired:server.kill();server.wait()
            if (control/'server-counters.json').exists():counters=json.loads((control/'server-counters.json').read_text())
        residual=sum(p.is_file() for p in media.rglob('*'))
        assert media.parent==root and control.parent==root
        shutil.rmtree(media);shutil.rmtree(control)
        cleanup={'residual_download_files_before_wrapper_cleanup':residual,'media_workspace_removed':not media.exists(),'fixture_workspace_removed':not control.exists()}
        (evidence/'integration-cleanup.json').write_text(json.dumps(cleanup,indent=2)+'\n')
    for result in results:
        row=counters.get(result['id'],{});result['server']=row
        checks=result['assertions']
        for kind in ('list','media'):
            if row.get(kind+'_requests',0)!=result.get('expected_'+kind+'_requests',0):checks.append('SERVER_'+kind.upper()+'_COUNT')
        if result.get('expected_list_requests')==1 and not row.get('credential_present'):checks.append('SYNTHETIC_LIST_CREDENTIAL_ABSENT')
        if row.get('media_credential_present') or row.get('media_range_present'):checks.append('MEDIA_HEADERS_NOT_ISOLATED')
        if result.get('STRICT_NETWORK_RECEIVE_LIMIT')!='NOT_PROVEN':checks.append('STRICT_LIMIT_MISREPRESENTED')
        if checks:result['status']='FAIL'
    passed=generator_code==0 and len(results)==28 and all(r['status']=='PASS' for r in results) and residual==0 and not counters.get('INT-029')
    summary={'status':'PASS' if passed else 'FAIL','generator_exit_code':generator_code,'cases':results,'REAL_DOUYIN_DOWNLOAD':'NOT_RUN','STRICT_NETWORK_RECEIVE_LIMIT':'NOT_PROVEN','HOST_ALLOWLIST_AUDIT':'BLOCKED'}
    (evidence/'integration-results.json').write_text(json.dumps(summary,indent=2)+'\n')
    (evidence/'integration-server-counters.json').write_text(json.dumps(counters,indent=2)+'\n')
    (evidence/'integration-process.log').write_text('\n'.join(logs)+'\n')
    print('INTEGRATION_TESTS='+summary['status'])
    return 0 if passed else 1

if __name__=='__main__':raise SystemExit(main())
