"""Real Swift/URLSession offline runner. Network destinations are loopback only."""
import json
import os
from pathlib import Path
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from auth_preflight import write

CASES = ('range206','ignore200','redirect301','redirect302','redirect307','redirect308',
         'html','json','forbidden403','limited429','badRange','tooMany','empty','challenge',
         'second','relativeRedirect','invalidRedirect','encoded','disconnect')
POLICY = {'original_last_address','per_host_one','exact_hosts','http_rejected','suffix_rejected',
          'backup_host_rejected','userinfo_rejected','port_rejected','fragment_rejected',
          'empty_rejected','original_bitrate','no_backup_substitution'}

def sandbox_command(binary, args, network):
    policy = '(version 1)(allow default)(deny network*)'
    if network:
        # Same loopback-only profile as the already validated integration runner.
        # URLSession needs local socket binding as well as outbound loopback access.
        policy += '(allow network-inbound (local ip "localhost:*"))(allow network-outbound (remote ip "localhost:*"))(allow network-bind (local ip "localhost:*"))'
    return ['sandbox-exec','-p',policy,binary] + args

def process_failure(stderr, code):
    # stderr is inspected only in memory. Never publish a crash report, URL or arbitrary exception.
    text = (stderr or b'').decode('utf-8',errors='replace').lower()
    if 'sandbox-exec:' in text and any(word in text for word in ('parse','syntax','invalid','profile')):
        return 'SANDBOX_PROFILE_REJECTED'
    if code is not None and code < 0: return 'SWIFT_PROCESS_SIGNAL'
    if 'operation not permitted' in text or 'sandbox deny' in text: return 'SANDBOX_OPERATION_REJECTED'
    return 'MISSING_SWIFT_OBSERVATION'

def save_results(folder, rows, category=None):
    write(folder,'offline-tests.json',dict(scope='SYNTHETIC_LOOPBACK_ONLY',cases=rows,
        real_worklist_requests=0,real_media_requests=0,
        status='PASS' if len(rows)==len(CASES) and all(r['status']=='PASS' for r in rows) else 'INCOMPLETE_OR_FAILED',
        failure_category=category))

class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args):
        pass  # Never record request URLs or headers.

    def do_GET(self):
        key = self.path.lstrip('/')
        with self.server.guard:
            self.server.counts[key] = self.server.counts.get(key, 0) + 1
            self.server.auth_seen |= any(self.headers.get(k) for k in
                ('Cookie','Authorization','Proxy-Authorization','X-Api-Key'))
            self.server.range_ok &= self.headers.get('Range') == 'bytes=0-0'
        if key not in CASES:
            self.send_response(500); self.send_header('Content-Length','0'); self.end_headers(); return
        status, kind, body = 206, 'video/mp4', b'x'
        if key == 'ignore200': status, body = 200, b'x' * 65536
        if key == 'html': kind, body = 'text/html', b'<html>challenge</html>'
        if key == 'json': kind, body = 'application/json', b'{"challenge":true}'
        if key == 'forbidden403': status = 403
        if key == 'limited429': status = 429
        if key == 'challenge': status = 401
        if key == 'tooMany': body = b'x' * 65536
        if key in ('empty','disconnect'): body = b''
        redirect = key.startswith('redirect') or key in ('relativeRedirect','invalidRedirect')
        if redirect:
            status = int(key[-3:]) if key.startswith('redirect') else 302
            body = b''
        self.send_response(status)
        self.send_header('Content-Type', kind)
        if redirect:
            target = 'https://redirect.fixture-cdn.com/hidden-media-path?fixture_token=DO_NOT_SERIALIZE'
            if key == 'relativeRedirect': target = '/target'
            if key == 'invalidRedirect': target = 'http://localhost/target'
            self.send_header('Location', target)
        if key == 'challenge': self.send_header('WWW-Authenticate','Basic realm="synthetic"')
        if key == 'encoded': self.send_header('Content-Encoding','gzip')
        self.send_header('Content-Range', 'bytes 1-1/20' if key == 'badRange' else 'bytes 0-0/20')
        if key in ('tooMany','empty'):
            self.send_header('Transfer-Encoding','chunked')
        else:
            self.send_header('Content-Length',str(1 if key == 'disconnect' else len(body)))
        self.send_header('Connection','close'); self.end_headers()
        try:
            if key in ('tooMany','empty'):
                if body: self.wfile.write(f'{len(body):x}\r\n'.encode() + body + b'\r\n')
                self.wfile.write(b'0\r\n\r\n')
            else: self.wfile.write(body)
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        self.close_connection = True

def expected(case, observation):
    result = observation['result']
    exact = {'range206':'VIDEO_RANGE_206_ONE_BYTE','second':'VIDEO_RANGE_206_ONE_BYTE',
             'ignore200':'RANGE_IGNORED_200','html':'NON_VIDEO_RESPONSE','json':'NON_VIDEO_RESPONSE',
             'forbidden403':'ACCESS_RESTRICTED','limited429':'RATE_LIMITED',
             'badRange':'INVALID_RANGE_RESPONSE','encoded':'INVALID_RANGE_RESPONSE',
             'empty':'EMPTY_OR_INCOMPLETE_BODY','disconnect':'NETWORK_OR_TIMEOUT_ERROR'}
    if case in exact: return result == exact[case]
    if case == 'tooMany': return result in ('BODY_BUDGET_EXCEEDED','VIDEO_RANGE_206_ONE_BYTE') and observation['cancel_completed']
    if case == 'challenge': return result in ('AUTH_CHALLENGE_REJECTED','HTTP_STATUS_REJECTED')
    if case.startswith('redirect') or case in ('relativeRedirect','invalidRedirect'):
        if result != 'HTTP_REDIRECT_NOT_FOLLOWED': return False
        if case.startswith('redirect'): return observation['redirect_host'] == 'redirect.fixture-cdn.com'
        return observation['redirect_target_rejected'] and observation.get('redirect_host') is None
    return False

def run(binary, folder, sandbox=True):
    folder = Path(folder)
    child = {k:os.environ[k] for k in ('PATH','TMPDIR','HOME','SYSTEMROOT') if k in os.environ}
    child.update(OFFLINE_ONLY='1', PROBE_EVIDENCE_DIR=str(folder))
    def command(args, network):
        if not sandbox: return [binary] + args  # Unit-test hook; CLI always uses sandbox.
        return sandbox_command(binary,args,network)
    result = subprocess.run(command(['--live-probe-policy-test'],False), env=child,
                            stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=60,check=False)
    policy = json.loads((folder/'policy-tests.json').read_text())
    if result.returncode != 0 or set(policy) != POLICY or not all(v is True for v in policy.values()):
        raise ValueError('POLICY_TEST_FAILED')
    rows = []
    save_results(folder,rows)
    # No raw logs. Only fixed case IDs and whitelisted boolean/numeric fields leave this runner.
    for case in CASES:
        case_folder = folder / ('case-' + case); case_folder.mkdir()
        server = ThreadingHTTPServer(('127.0.0.1',0),Handler)
        server.daemon_threads = True
        server.guard = threading.Lock(); server.counts = {}; server.auth_seen = False; server.range_ok = True
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        try:
            case_env = dict(child, PROBE_CASE_DIR=str(case_folder))
            try:
                completed = subprocess.run(command(['--live-probe-fixture',case,str(server.server_port)],True),
                    env=case_env,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,timeout=45,check=False)
            except (OSError,subprocess.TimeoutExpired) as error:
                category = 'SWIFT_PROCESS_TIMEOUT' if isinstance(error,subprocess.TimeoutExpired) else 'SWIFT_PROCESS_START_FAILED'
                rows.append(dict(id=case,status='FAIL',swift_exit_code=None,failure_category=category))
                save_results(folder,rows,category)
                raise ValueError(category) from None
            if not (case_folder/'observation.json').is_file():
                category = process_failure(completed.stderr,completed.returncode)
                with server.guard:
                    count = sum(server.counts.values())
                rows.append(dict(id=case,status='FAIL',swift_exit_code=completed.returncode,
                                 failure_category=category,server_requests=count))
                save_results(folder,rows,category)
                raise ValueError(category)
            observation = json.loads((case_folder/'observation.json').read_text())
            second_ok = case != 'second' or json.loads((case_folder/'second.json').read_text())['request_count'] == 0
            with server.guard:
                server_ok = server.counts == {case:1} and not server.auth_seen and server.range_ok
            body_ok = observation['accepted_bytes'] <= 1 and observation['completion_callbacks'] == 1
            if observation['cancel_requested']: body_ok &= observation['cancel_completed']
            if case in ('ignore200','html','json','badRange','encoded','forbidden403','limited429'):
                body_ok &= observation['accepted_bytes'] == 0 and observation['cancel_completed']
            if case in ('range206','second'): body_ok &= observation['accepted_bytes'] == 1
            passed = completed.returncode == 0 and expected(case,observation) and server_ok and body_ok and second_ok
            rows.append(dict(id=case,status='PASS' if passed else 'FAIL',swift_exit_code=completed.returncode,
                             server_single_request=server_ok,observation=observation))
            save_results(folder,rows,None if passed else 'SWIFT_CASE_ASSERTION_FAILED')
            if not passed: raise ValueError('SWIFT_CASE_FAILED')
        finally:
            server.shutdown(); server.server_close(); thread.join(timeout=2)
    if any(p.suffix in ('.part','.mp4','.mov') for p in folder.rglob('*')):
        raise ValueError('UNEXPECTED_MEDIA_FILE')
    return 0

if __name__ == '__main__':
    import sys
    try: code = run(os.environ['PROBE_BIN'],os.environ['PROBE_EVIDENCE_DIR'])
    except Exception: print('LIVE_PROBE_OFFLINE_FAILED'); code = 1
    raise SystemExit(code)
