"""Runs each real Swift case in its own process against an owned loopback server."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time


def main():
    evidence=Path(os.environ['SAFE_EVIDENCE_ROOT']).resolve()
    task_root=evidence.parent
    media=Path(os.environ['SAFE_MEDIA_ROOT']).resolve()
    control=task_root/'control';control.mkdir()
    assert media.parent==task_root and media.name=='media' and evidence.name=='evidence'
    media.mkdir()
    server=subprocess.Popen([sys.executable,'-B',str(Path(__file__).with_name('controlled_server.py')),'--directory',str(control)],
                            stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    results=[];server_stats={};process_log=[]
    try:
        for _ in range(100):
            if (control/'server-ready.json').exists():break
            if server.poll() is not None:raise RuntimeError('SERVER_START_FAILED')
            time.sleep(.05)
        port=json.loads((control/'server-ready.json').read_text())['port']
        assert isinstance(port,int) and 1024<=port<=65535
        # No inherited account/session secrets, GitHub event or unneeded variables.
        child={k:os.environ[k] for k in ('PATH','TMPDIR','HOME') if k in os.environ}
        child.update(SAFE_PORT=str(port),SAFE_MEDIA_ROOT=str(media),SAFE_EVIDENCE_ROOT=str(evidence))
        deadline=time.monotonic()+600
        for number in range(1,29):
            case=f'ST-{number:03}'
            env=dict(child,SAFE_CASE=case)
            timed_out=False
            if time.monotonic()>=deadline:
                results.append(dict(id=case,status='NOT_RUN',reason='SUITE_DEADLINE'));continue
            process=subprocess.Popen([os.environ['SAFE_BINARY']],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
            try: output,_=process.communicate(timeout=60)
            except subprocess.TimeoutExpired:
                timed_out=True;process.kill();output,_=process.communicate()
            process_log.append(output)
            path=evidence/(case+'.json')
            result=json.loads(path.read_text()) if path.exists() else dict(id=case,status='FAIL',reason='NO_SWIFT_RESULT')
            result['process_exit_code']=process.returncode;result['process_timed_out']=timed_out
            if process.returncode!=0:result['status']='FAIL'
            results.append(result)
    finally:
        server.terminate()
        try:server.wait(timeout=5)
        except subprocess.TimeoutExpired:server.kill();server.wait()
        if (control/'server-counters.json').exists():server_stats=json.loads((control/'server-counters.json').read_text())
        leftovers=[p for p in media.rglob('*') if p.is_file()]
        cleanup=dict(residual_files_before_runner_cleanup=len(leftovers),runner_cleanup_succeeded=False)
        assert media.resolve().parent==task_root and media.name=='media'
        shutil.rmtree(media)
        cleanup['runner_cleanup_succeeded']=not media.exists()
        (evidence/'cleanup-summary.json').write_text(json.dumps(cleanup,indent=2)+'\n')
        (evidence/'server-counters.json').write_text(json.dumps(server_stats,indent=2)+'\n')
        (evidence/'test-process.log').write_text(''.join(process_log),encoding='utf-8')
    for result in results:
        row=server_stats.get(result['id'],{})
        result['server_payload_bytes_written']=row.get('payload_bytes_written',0)
        result['server_requests']=row.get('requests',0)
        checks=result.setdefault('failed_assertions',[])
        if row.get('requests',0)!=result.get('expected_requests',1):checks.append('SERVER_REQUEST_COUNT')
        if any(row.get(k,False) for k in ('cookie_seen','authorization_seen','range_seen')):checks.append('SERVER_HEADER_BOUNDARY')
        if checks:result['status']='FAIL'
    if server_stats.get('ST-099',{}).get('requests',0):
        for result in results:
            if result['id'] in ('ST-009','ST-010'):result['status']='FAIL';result['failed_assertions'].append('REDIRECT_TARGET_REACHED')
    passed=len(results)==28 and all(r['status']=='PASS' for r in results) and cleanup['runner_cleanup_succeeded'] and not leftovers
    summary={'status':'PASS' if passed else 'FAIL','cases':results,'actual_process_count':sum('process_exit_code' in r for r in results),
             'strict_network_receive_limit':'NOT_PROVEN','real_douyin_download':'NOT_RUN',
             'server_byte_definition':'Bytes in successful server payload write calls; excludes HTTP framing and is not a packet-level delivery count.',
             'delegate_byte_definition':'Actual bytes received in URLSession delegate data callbacks, including callbacks after cancellation.',
             'buffer_scope':'2 MiB application channel plus at most one consumer chunk; excludes OS/URLSession internal buffering.'}
    (evidence/'controlled-results.json').write_text(json.dumps(summary,indent=2)+'\n')
    print('CONTROLLED_SERVER_TESTS='+summary['status']+'; cases='+str(len(results)))
    return 0 if passed else 1


if __name__=='__main__':
    try:code=main()
    except Exception:
        print('CONTROLLED_TEST_INFRASTRUCTURE_ERROR');code=2
    raise SystemExit(code)
