"""Real Swift/Downloader/AVFoundation fixture runs. All sockets are restricted to loopback."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from auth_preflight import write
from live_probe_tests import sandbox_command

CASES=('full200','full206','unknownLength','partial206','oneByte206','redirectCDN','html','json','corruptMdat','brokenBox','empty','disconnect','budgetHeader','budgetChunked','ignoreRange','tlsProxy')
POLICY={'deterministic_first_www','original_last_url','ordinary_video','no_alternate_cdn','empty_rejected'}
SUCCESS={'full200','full206','unknownLength','ignoreRange'}

class DownloadHandler(BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def log_message(self,*args): pass
    def do_GET(self):
        case=self.path.strip('/')
        with self.server.guard:
            self.server.counts[case]=self.server.counts.get(case,0)+1
            self.server.auth_seen |= any(self.headers.get(k) for k in ('Cookie','Authorization','Proxy-Authorization','X-Api-Key'))
            self.server.range_seen |= self.headers.get('Range') is not None
        if case not in CASES: self.send_error(500); return
        body=self.server.valid; status=200; kind='video/mp4'; size=len(body); chunked=case in ('unknownLength','budgetChunked')
        if case=='corruptMdat': body=self.server.corrupt
        if case=='brokenBox': body=body[:-64]
        if case=='empty': body=b''
        if case=='html': body=b'<html>synthetic error</html>';kind='text/html'
        if case=='json': body=b'{"error":"synthetic"}'
        if case in ('partial206','oneByte206','full206'):
            status=206
            if case=='partial206': body=body[:len(body)//2]
            if case=='oneByte206': body=body[:1]
        if case=='redirectCDN': status=302;body=b''
        size=len(body)
        if case in ('budgetHeader','budgetChunked'): size=105906176
        self.send_response(status);self.send_header('Content-Type',kind)
        if chunked: self.send_header('Transfer-Encoding','chunked')
        else: self.send_header('Content-Length',str(size))
        if status==206: self.send_header('Content-Range',f'bytes 0-{len(body)-1}/{len(self.server.valid)}')
        if status==302: self.send_header('Location',f'http://127.0.0.1:{self.server.server_port}/never-follow')
        self.send_header('Connection','close');self.end_headers()
        try:
            if case=='budgetHeader': self.wfile.write(b'x'*65536)
            elif case=='budgetChunked':
                prefix=b'\x00\x00\x00\x18ftypisom\x00\x00\x02\x00isomiso2'
                for offset in range(0,size,65536):
                    count=min(65536,size-offset);piece=((prefix if offset==0 else b'')+b'\0'*count)[:count]
                    self.wfile.write(f'{count:x}\r\n'.encode()+piece+b'\r\n')
                self.wfile.write(b'0\r\n\r\n')
            elif case=='disconnect': self.wfile.write(body[:24])
            elif chunked: self.wfile.write(f'{len(body):x}\r\n'.encode()+body+b'\r\n0\r\n\r\n')
            else: self.wfile.write(body)
            self.wfile.flush()
        except OSError: pass
        self.close_connection=True

def legacy(binary,folder,root,child):
    for name,script,output in (('transport','run_controlled_tests.py','controlled-results.json'),('integration','run_integration_tests.py','integration-results.json')):
        owned=root/('legacy-'+name);owned.mkdir();evidence=owned/'evidence';evidence.mkdir()
        env=dict(child,SAFE_BINARY=binary,SAFE_MEDIA_ROOT=str(owned/'media'),SAFE_EVIDENCE_ROOT=str(evidence))
        policy='(version 1)(allow default)(deny network*)(allow network-inbound (local ip "localhost:*"))(allow network-outbound (remote ip "localhost:*"))(allow network-bind (local ip "localhost:*"))'
        result=subprocess.run(['sandbox-exec','-p',policy,sys.executable,'-B',str(Path(__file__).parent/'safe-streaming-tests'/script)],env=env,
            stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=650,check=False)
        data=json.loads((evidence/output).read_text())
        write(folder,output,data)
        rows=data.get('cases',[])
        if result.returncode!=0 or len(rows)!=28 or any(r['status']!='PASS' for r in rows): raise ValueError('LEGACY_DOWNLOAD_TEST_FAILED')
        if name=='transport': cleanup=json.loads((evidence/'cleanup-summary.json').read_text())
        else: cleanup=json.loads((evidence/'integration-cleanup.json').read_text())
        write(folder,name+'-cleanup.json',cleanup)

def run(binary,safe_binary,folder):
    folder=Path(folder)
    child={k:os.environ[k] for k in ('PATH','TMPDIR','HOME','SYSTEMROOT') if k in os.environ}
    child.update(OFFLINE_ONLY='1',DOWNLOAD_EVIDENCE_DIR=str(folder))
    with tempfile.TemporaryDirectory(prefix='doustudio-download-offline-') as temp:
        root=Path(temp); fixtures=root/'fixtures';fixtures.mkdir()
        legacy(safe_binary,folder,root,child)
        code=subprocess.run(sandbox_command(binary,['--single-download-policy-test'],False),env=child,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=60).returncode
        policy=json.loads((folder/'download-policy-tests.json').read_text())
        if code!=0 or set(policy)!=POLICY or not all(v is True for v in policy.values()): raise ValueError('POLICY_FAILED')
        generated=subprocess.run(sandbox_command(binary,['--single-download-generate-fixture'],False),env=dict(child,DOWNLOAD_FIXTURE_ROOT=str(fixtures)),
            stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=60)
        if generated.returncode: raise ValueError('MEDIA_GENERATION_FAILED')
        valid=(fixtures/'valid.mp4').read_bytes()
        if not 0<len(valid)<1048576: raise ValueError('FIXTURE_SIZE')
        source=Path(__file__).parent/'safe-streaming-tests/integration_server.py'
        spec=importlib.util.spec_from_file_location('owned_integration_fixture',source);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        corrupt=module.corrupt_mdat(valid)
        rows=[]
        def save(): write(folder,'download-offline-tests.json',dict(scope='SYNTHETIC_LOOPBACK_ONLY',cases=rows,status='PASS' if len(rows)==len(CASES) and all(r['status']=='PASS' for r in rows) else 'INCOMPLETE_OR_FAILED',real_worklist_requests=0,real_media_requests=0))
        save()
        for case in CASES:
            diagnostics=root/('case-'+case);diagnostics.mkdir();media=root/('media-'+case);media.mkdir()
            httpd=ThreadingHTTPServer(('127.0.0.1',0),DownloadHandler);httpd.daemon_threads=True
            httpd.valid=valid;httpd.corrupt=corrupt;httpd.guard=threading.Lock();httpd.counts={};httpd.auth_seen=False;httpd.range_seen=False
            thread=threading.Thread(target=httpd.serve_forever,daemon=True);thread.start()
            try:
                result=subprocess.run(sandbox_command(binary,['--single-download-fixture',case,str(httpd.server_port)],True),env=dict(child,DOWNLOAD_MEDIA_ROOT=str(media),PROBE_CASE_DIR=str(diagnostics)),
                    stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=90,check=False)
                receipt=json.loads((diagnostics/'transfer-results.json').read_text())
                metrics=receipt.get('metrics',{})
                with httpd.guard:
                    counts=dict(httpd.counts);server_ok=not httpd.auth_seen and not httpd.range_seen and (counts=={case:1} if case!='tlsProxy' else not counts)
                passed=result.returncode==0 and receipt['success']==(case in SUCCESS) and receipt['TEMP_FILE_CLEANUP']=='PASS' and not list(media.rglob('*')) and server_ok
                passed &= metrics.get('media_requests_started')==1 and metrics.get('stream_calls')==1 and metrics.get('buffered_send_calls')==0 and metrics.get('completion_received') and metrics.get('completion_callbacks')==1
                passed &= metrics['accepted_bytes']<=104857600 and receipt['written_bytes']<=104857600
                if metrics.get('cancel_requested'): passed &= metrics['cancel_completed']
                if case in SUCCESS:
                    proof=receipt['media'];passed &= proof['full_decode_completed'] and proof['decoded_frames']==30 and proof['start_decoded'] and proof['middle_decoded'] and proof['end_decoded'] and proof['repeated_sha256_matches']
                if case in ('partial206','oneByte206'): passed &= receipt['category']=='INCOMPLETE_RANGE_REJECTED' and metrics['accepted_bytes']==0
                if case=='budgetHeader': passed &= receipt['category']=='DECLARED_LENGTH_OVER_BUDGET' and metrics['accepted_bytes']==0
                if case=='budgetChunked': passed &= receipt['category']=='APPLICATION_BYTE_BUDGET_REACHED' and metrics['cancel_completed']
                if case=='tlsProxy':
                    tunnel=json.loads((diagnostics/'tunnel-result.json').read_text());passed &= metrics['pinned_session_proxy'] and tunnel['outbound_connections']==1 and tunnel['connect_authority_matched']
                rows.append(dict(id=case,status='PASS' if passed else 'FAIL',swift_exit_code=result.returncode,server_single_request_and_headers=server_ok,result=receipt))
                save()
                if not passed: raise ValueError('DOWNLOAD_FIXTURE_FAILED')
            finally: httpd.shutdown();httpd.server_close();thread.join(timeout=2)
        write(folder,'offline-media-cleanup.json',dict(media_files_retained=False,fixture_workspace_ephemeral=True))
    return 0

if __name__=='__main__':
    try: code=run(os.environ['PROBE_BIN'],os.environ['SAFE_BINARY'],os.environ['DOWNLOAD_EVIDENCE_DIR'])
    except Exception: print('SINGLE_DOWNLOAD_OFFLINE_FAILED');code=1
    raise SystemExit(code)
