import json
from pathlib import Path
import tempfile
import unittest
import http.client
import threading
from unittest.mock import patch
import live_probe as runner
from live_probe_tests import Handler, ThreadingHTTPServer

class ProbeBoundaryTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(); self.addCleanup(temp.cleanup)
        self.folder = Path(temp.name); runner.seed(self.folder)
        event = self.folder/'event.json'
        event.write_text(json.dumps({'inputs':{'authorized_own_session':'true','profile_url':'https://www.douyin.com/user/fixture'}}))
        self.env = dict(PROBE_EVIDENCE_DIR=str(self.folder),PROBE_BIN='never-execute',
                        GITHUB_EVENT_PATH=str(event),DOUYIN_COOKIE='synthetic-only')

    def ready(self):
        # Synthetic bookkeeping only: never delivered as a macOS execution result.
        for name in ('build-exit-code.txt','baseline-exit-code.txt','offline-exit-code.txt'):
            (self.folder/name).write_text('0\n')
        runner.write(self.folder,'policy-tests.json',{k:True for k in runner.POLICY})
        rows = [dict(id=k,status='PASS',swift_exit_code=0,server_single_request=True,observation=dict(
            accepted_bytes=1,completion_callbacks=1,authentication_headers_sent=False,cancel_requested=True,cancel_completed=True)) for k in runner.CASES]
        runner.write(self.folder,'offline-tests.json',dict(scope='SYNTHETIC_LOOPBACK_ONLY',status='PASS',cases=rows,real_worklist_requests=0,real_media_requests=0))
        for name,count in (('selftest-results.json',38),('host-selftest-results.json',20),('priority-selftest-results.json',25)):
            rows = [dict(id=str(i),status='PASS') for i in range(count)]
            runner.write(self.folder,name,{'cases':rows} if count==38 else rows)
        runner.write(self.folder,'offline-source.json',dict(sha256=runner.fingerprint()))

    def edit(self,name,operation):
        value=json.loads((self.folder/name).read_text()); operation(value); runner.write(self.folder,name,value)

    def test_unrun_gate_rejects_before_process(self):
        with patch.object(runner.subprocess,'run') as child:
            with self.assertRaises(AssertionError): runner.run_probe(self.env)
            child.assert_not_called()

    def test_complete_bookkeeping_gate(self):
        self.ready(); runner.offline_gate(self.folder)

    def test_stale_source_gate(self):
        self.ready(); runner.write(self.folder,'offline-source.json',dict(sha256='stale'))
        with self.assertRaises(AssertionError): runner.offline_gate(self.folder)

    def test_partial_cases_reject(self):
        self.ready(); self.edit('offline-tests.json',lambda x:x['cases'].pop())
        with self.assertRaises(AssertionError): runner.offline_gate(self.folder)

    def test_failing_case_reject(self):
        self.ready(); self.edit('offline-tests.json',lambda x:x['cases'][0].update(status='FAIL'))
        with self.assertRaises(AssertionError): runner.offline_gate(self.folder)

    def test_pending_cancellation_reject(self):
        self.ready(); self.edit('offline-tests.json',lambda x:x['cases'][0]['observation'].update(cancel_completed=False))
        with self.assertRaises(AssertionError): runner.offline_gate(self.folder)

    def test_overbudget_reject(self):
        self.ready(); self.edit('offline-tests.json',lambda x:x['cases'][0]['observation'].update(accepted_bytes=2))
        with self.assertRaises(AssertionError): runner.offline_gate(self.folder)

    def test_server_extra_request_reject(self):
        self.ready(); self.edit('offline-tests.json',lambda x:x['cases'][0].update(server_single_request=False))
        with self.assertRaises(AssertionError): runner.offline_gate(self.folder)

    def test_missing_secret_no_process(self):
        self.ready(); self.env.pop('DOUYIN_COOKIE')
        with patch.object(runner.subprocess,'run') as child:
            self.assertEqual(runner.run_probe(self.env),2); child.assert_not_called()

    def test_control_character_secret_no_process(self):
        self.ready(); self.env['DOUYIN_COOKIE']='synthetic\nvalue'
        with patch.object(runner.subprocess,'run') as child:
            self.assertEqual(runner.run_probe(self.env),2); child.assert_not_called()

    def test_consent_required(self):
        self.ready(); Path(self.env['GITHUB_EVENT_PATH']).write_text(json.dumps({'inputs':{}}))
        with patch.object(runner.subprocess,'run') as child:
            self.assertEqual(runner.run_probe(self.env),2); child.assert_not_called()

    def test_child_environment_isolation(self):
        self.ready(); self.env['AWS_SECRET_ACCESS_KEY']='synthetic-inherited'
        def child(args,**kwargs):
            self.assertEqual(args,['never-execute','--media-host-live-probe'])
            self.assertNotIn('AWS_SECRET_ACCESS_KEY',kwargs['env'])
            self.assertEqual(kwargs['env']['DOUYIN_COOKIE'],'synthetic-only')
            self.assertEqual(kwargs['stdout'],runner.subprocess.DEVNULL)
            self.assertEqual(kwargs['stderr'],runner.subprocess.DEVNULL)
            return type('Exit',(),{'returncode':2})()
        with patch.object(runner.subprocess,'run',side_effect=child) as launch:
            self.assertEqual(runner.run_probe(self.env),2); self.assertEqual(launch.call_count,1)

    def test_timeout_no_retry(self):
        self.ready()
        with patch.object(runner.subprocess,'run',side_effect=runner.subprocess.TimeoutExpired('fixed',150)) as launch:
            self.assertEqual(runner.run_probe(self.env),1); self.assertEqual(launch.call_count,1)

    def test_fake_child_success_reject(self):
        self.ready()
        with patch.object(runner.subprocess,'run',return_value=type('Exit',(),{'returncode':0})()):
            self.assertEqual(runner.run_probe(self.env),1)

    def test_empty_artifact_seed_valid(self):
        runner.validate_artifacts(self.folder)

    def test_production_approval_reject(self):
        runner.write(self.folder,'approved-hosts.json',['www.douyin.com'])
        with self.assertRaises(AssertionError): runner.validate_artifacts(self.folder)

    def test_private_material_reject(self):
        for marker in ('https://private.example/a','Cookie: synthetic','Authorization: synthetic','a_bogus=synthetic','1234567890123456789','DO_NOT_SERIALIZE'):
            with self.subTest(marker=marker):
                runner.write(self.folder,'probe-summary.json',{'unexpected':marker})
                with self.assertRaises(AssertionError): runner.validate_artifacts(self.folder)

    def test_escaped_url_reject(self):
        (self.folder/'probe-summary.json').write_text('{"x":"https\\u003a\\u002f\\u002fprivate.example"}')
        with self.assertRaises(AssertionError): runner.validate_artifacts(self.folder)

    def test_artifact_whitelist_no_media(self):
        self.assertEqual(len(runner.ARTIFACTS),len(set(runner.ARTIFACTS)))
        self.assertFalse(any('*' in x or x.endswith(('.mp4','.part','.mov')) for x in runner.ARTIFACTS))

    def test_seed_never_claims_execution(self):
        summary=json.loads((self.folder/'probe-summary.json').read_text())
        self.assertEqual(summary['REAL_MEDIA_PROBE'],'NOT_RUN')
        self.assertEqual(summary['MACOS_SWIFT_BUILD'],'NOT_RUN')
        self.assertEqual(summary['OFFLINE_TESTS'],'NOT_RUN')

    def test_controlled_server_range_and_headers(self):
        server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
        server.daemon_threads=True; server.guard=threading.Lock(); server.counts={}; server.auth_seen=False; server.range_ok=True
        thread=threading.Thread(target=server.serve_forever,daemon=True); thread.start()
        try:
            connection=http.client.HTTPConnection('127.0.0.1',server.server_port,timeout=3)
            connection.request('GET','/range206',headers={'Range':'bytes=0-0'})
            response=connection.getresponse()
            self.assertEqual(response.status,206); self.assertEqual(response.getheader('Content-Range'),'bytes 0-0/20')
            self.assertEqual(response.read(),b'x'); connection.close()
            self.assertEqual(server.counts,{'range206':1}); self.assertFalse(server.auth_seen); self.assertTrue(server.range_ok)
        finally: server.shutdown(); server.server_close(); thread.join(timeout=2)

    def test_controlled_redirect_response_has_no_target_request(self):
        server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
        server.daemon_threads=True; server.guard=threading.Lock(); server.counts={}; server.auth_seen=False; server.range_ok=True
        thread=threading.Thread(target=server.serve_forever,daemon=True); thread.start()
        try:
            connection=http.client.HTTPConnection('127.0.0.1',server.server_port,timeout=3)
            connection.request('GET','/redirect308',headers={'Range':'bytes=0-0'})
            response=connection.getresponse(); self.assertEqual(response.status,308)
            self.assertIsNotNone(response.getheader('Location')); response.read(); connection.close()
            self.assertEqual(server.counts,{'redirect308':1})
        finally: server.shutdown(); server.server_close(); thread.join(timeout=2)

if __name__ == '__main__': unittest.main()
