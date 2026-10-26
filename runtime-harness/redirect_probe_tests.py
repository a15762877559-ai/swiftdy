"""Synthetic redirect-chain and numeric-address tunnel tests; all network is loopback-only."""
from http.client import HTTPConnection, HTTPException
import json
import os
from pathlib import Path
import subprocess
import threading
import time
from auth_preflight import write
from live_probe_tests import Handler, ThreadingHTTPServer, sandbox_command, process_failure

TARGET='v5-dy-ov-experiment.zjcdn.com'
CASES=('next206','nextRedirect','unapproved','httpTarget','userinfo','portTarget','privateDNS','mixedDNS',
       'missingLocation','relativeTarget','schemeRelative','javascript','target200','target403','target429',
       'targetHTML','targetBadRange','www403','www429','sf11Present','sf11Absent','sf11Only','noSamples','www403sf11','nextRedirectsf11')
POLICY={'exact_target'} | {k+'_rejected' for k in ('http','userinfo','port','suffix','scheme_relative','relative','javascript','fragment')} | {
    'private_or_special_'+str(i)+'_rejected' for i in range(9,31)} | {
    'public_ipv4','public_ipv6','mixed_dns_rejected','empty_dns_rejected','target_before_www_rejected',
    'three_slots','no_fourth_or_repeated_slot','original_extractor_last','sf11_missing_explicit','sf11_selected_once'}

class RedirectHandler(Handler):
    def do_GET(self):
        parts=self.path.strip('/').split('/')
        if self.path=='/tunnel-probe': case,role='tunnel','target'
        elif len(parts)==2 and parts[0] in CASES and parts[1] in ('www','target','sf11'): case,role=parts
        else:
            self.send_response(500); self.send_header('Content-Length','0'); self.end_headers(); return
        with self.server.guard:
            self.server.counts[role]=self.server.counts.get(role,0)+1
            self.server.auth_seen |= any(self.headers.get(k) for k in ('Cookie','Authorization','Proxy-Authorization','X-Api-Key'))
            self.server.range_ok &= self.headers.get('Range')=='bytes=0-0'
        status,kind,body,location=206,'video/mp4',b'x',None
        if role=='www':
            status,body,location=302,b'',f'https://{TARGET}/private-fixture?fixture_token=DO_NOT_SERIALIZE'
            location={
                'unapproved':'https://unapproved.fixture-cdn.com/private-fixture',
                'httpTarget':f'http://{TARGET}/private-fixture',
                'userinfo':f'https://u:p@{TARGET}/private-fixture',
                'portTarget':f'https://{TARGET}:444/private-fixture',
                'missingLocation':None,'relativeTarget':'/private-fixture',
                'schemeRelative':f'//{TARGET}/private-fixture','javascript':'javascript:alert(1)'}.get(case,location)
            if case in ('www403','www403sf11'): status,location=403,None
            if case=='www429': status,location=429,None
        if role=='target':
            if case in ('nextRedirect','nextRedirectsf11'): status,body,location=302,b'','https://third.fixture-cdn.com/private-fixture'
            if case=='target200': status=200
            if case=='target403': status=403
            if case=='target429': status=429
            if case=='targetHTML': kind,body='text/html',b'<html>synthetic challenge</html>'
        self.send_response(status); self.send_header('Content-Type',kind)
        self.send_header('Content-Range','bytes 1-1/20' if case=='targetBadRange' and role=='target' else 'bytes 0-0/20')
        self.send_header('Content-Length',str(len(body))); self.send_header('Connection','close')
        if location is not None: self.send_header('Location',location)
        self.end_headers()
        try: self.wfile.write(body); self.wfile.flush()
        except (OSError,BrokenPipeError): pass
        self.close_connection=True

def server():
    value=ThreadingHTTPServer(('127.0.0.1',0),RedirectHandler)
    value.daemon_threads=True; value.guard=threading.Lock(); value.counts={}; value.auth_seen=False; value.range_ok=True
    thread=threading.Thread(target=value.serve_forever,daemon=True); thread.start()
    return value,thread

def expected(case,output,counts):
    blocked={'unapproved','httpTarget','userinfo','portTarget','privateDNS','mixedDNS','missingLocation','relativeTarget','schemeRelative','javascript'}
    sf=case in ('sf11Present','sf11Only','www403sf11','nextRedirectsf11')
    www=case not in ('sf11Only','noSamples')
    target=www and case not in blocked and case not in ('www403','www429','www403sf11')
    wanted={role:1 for role,used in (('www',www),('target',target),('sf11',sf)) if used}
    if counts!=wanted or output['MEDIA_REQUEST_COUNT']!=sum(wanted.values()): return False
    if output['SF11_PROBE']!=('DIRECT_MEDIA' if sf else 'NOT_RUN'): return False
    if not sf and output['samples']['sf11_sample_status']!='NO_ELIGIBLE_SAMPLE': return False
    status='NOT_RUN'
    if case in blocked: status='BLOCKED'
    elif target:
        status={'nextRedirect':'REDIRECT','nextRedirectsf11':'REDIRECT','target200':'INCONCLUSIVE',
                'target403':'BLOCKED','target429':'BLOCKED','targetHTML':'NON_MEDIA','targetBadRange':'INCONCLUSIVE'}.get(case,'DIRECT_MEDIA')
    return output['REDIRECT_TARGET_PROBE']==status and output['MEDIA_RETRIES']==0 and output['UNAPPROVED_REDIRECT_FOLLOWED']=='NO'

def run(binary,folder):
    folder=Path(folder)
    child={k:os.environ[k] for k in ('PATH','TMPDIR','HOME','SYSTEMROOT') if k in os.environ}
    child.update(OFFLINE_ONLY='1',REDIRECT_EVIDENCE_DIR=str(folder))
    result=subprocess.run(sandbox_command(binary,['--redirect-probe-policy-test'],False),env=child,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=60)
    policy=json.loads((folder/'redirect-policy-tests.json').read_text())
    if result.returncode!=0 or set(policy)!=POLICY or not all(v is True for v in policy.values()): raise ValueError('REDIRECT_POLICY_FAILED')
    rows=[]
    def save(): write(folder,'redirect-offline-tests.json',dict(scope='SYNTHETIC_LOOPBACK_ONLY',cases=rows,status='PASS' if len(rows)==len(CASES) and all(r['status']=='PASS' for r in rows) else 'INCOMPLETE_OR_FAILED',real_worklist_requests=0,real_media_requests=0))
    save()
    for case in CASES:
        destination=folder/('redirect-case-'+case); destination.mkdir()
        http,thread=server()
        try:
            environment=dict(child,PROBE_CASE_DIR=str(destination))
            try:
                process=subprocess.run(sandbox_command(binary,['--redirect-probe-fixture',case,str(http.server_port)],True),env=environment,
                    stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,timeout=80,check=False)
            except (OSError,subprocess.TimeoutExpired):
                rows.append(dict(id=case,status='FAIL',failure_category='CHILD_START_OR_TIMEOUT')); save(); raise ValueError('CHILD_START_OR_TIMEOUT') from None
            if not (destination/'probe-summary.json').is_file():
                rows.append(dict(id=case,status='FAIL',swift_exit_code=process.returncode,failure_category=process_failure(process.stderr,process.returncode))); save(); raise ValueError('NO_REDIRECT_RESULT')
            output=json.loads((destination/'probe-summary.json').read_text())
            with http.guard: counts=dict(http.counts); clean=not http.auth_seen and http.range_ok
            passed=process.returncode==0 and clean and expected(case,output,counts)
            for hop in output['hops']:
                o=hop['observation']
                passed &= o['request_count']<=1 and o['accepted_bytes']<=1 and not o['authentication_headers_sent']
                passed &= not o['cancel_requested'] or o['cancel_completed']
            rows.append(dict(id=case,status='PASS' if passed else 'FAIL',swift_exit_code=process.returncode,server_requests=counts,credential_and_range_check=clean,outcome=output))
            save()
            if not passed: raise ValueError('REDIRECT_CASE_FAILED')
        finally: http.shutdown(); http.server_close(); thread.join(timeout=2)
    tunnel_rows=[]
    for case in ('pinnedRelay','wrongAuthority','tlsFailure'):
        destination=folder/('tunnel-case-'+case); destination.mkdir()
        http,thread=server()
        process=None
        try:
            flag='--redirect-tunnel-tls-fixture' if case=='tlsFailure' else '--redirect-tunnel-fixture'
            process=subprocess.Popen(sandbox_command(binary,[flag,str(http.server_port)],True),env=dict(child,PROBE_CASE_DIR=str(destination)),
                stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            if case!='tlsFailure':
                deadline=time.monotonic()+12
                while not (destination/'tunnel-ready.json').exists() and time.monotonic()<deadline and process.poll() is None: time.sleep(0.1)
                port=json.loads((destination/'tunnel-ready.json').read_text())['port']
                connection=HTTPConnection('127.0.0.1',port,timeout=3)
                connection.set_tunnel(TARGET if case=='pinnedRelay' else 'unapproved.fixture-cdn.com',443)
                denied=False
                try:
                    connection.request('GET','/tunnel-probe',headers={'Range':'bytes=0-0'})
                    response=connection.getresponse(); data=response.read()
                    if case!='pinnedRelay' or response.status!=206 or data!=b'x': raise ValueError('TUNNEL_RESPONSE_INVALID')
                except (OSError,HTTPException): denied=True
                finally: connection.close()
                if denied!=(case=='wrongAuthority'): raise ValueError('TUNNEL_AUTHORITY_MISMATCH')
                (destination/'tunnel-finish').touch()
            code=process.wait(timeout=40)
            value=json.loads((destination/'tunnel-result.json').read_text())
            passed=code==0 and value['stopped'] and not value['credential_headers_seen'] and value['outbound_connections']==(0 if case=='wrongAuthority' else 1)
            with http.guard:
                passed &= not http.auth_seen
                if case=='pinnedRelay': passed &= http.counts=={'target':1} and http.range_ok
                if case=='wrongAuthority': passed &= not http.counts
            tunnel_rows.append(dict(id=case,status='PASS' if passed else 'FAIL',swift_exit_code=code,tunnel=value))
            write(folder,'tunnel-tests.json',dict(scope='LOOPBACK_ONLY',cases=tunnel_rows,status='PASS' if len(tunnel_rows)==3 and all(r['status']=='PASS' for r in tunnel_rows) else 'INCOMPLETE_OR_FAILED'))
            if not passed: raise ValueError('TUNNEL_CASE_FAILED')
        finally:
            if process is not None and process.poll() is None: process.kill(); process.wait()
            http.shutdown(); http.server_close(); thread.join(timeout=2)
    if any(p.suffix in ('.mp4','.part','.mov') for p in folder.rglob('*')): raise ValueError('MEDIA_FILE_FOUND')
    return 0

if __name__=='__main__':
    try: code=run(os.environ['PROBE_BIN'],os.environ['REDIRECT_EVIDENCE_DIR'])
    except Exception: print('REDIRECT_OFFLINE_FAILED'); code=1
    raise SystemExit(code)
