from http.client import HTTPConnection
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import redirect_probe as runner
from redirect_probe_tests import server

class RedirectBoundaryTests(unittest.TestCase):
    def setUp(self):
        temp=tempfile.TemporaryDirectory(); self.addCleanup(temp.cleanup)
        self.folder=Path(temp.name); runner.base.seed(self.folder); runner.seed(self.folder)
        event=self.folder/'event.json'; event.write_text(json.dumps({'inputs':{'authorized_own_session':'true','profile_url':'https://www.douyin.com/user/fixture'}}))
        self.env=dict(REDIRECT_EVIDENCE_DIR=str(self.folder),PROBE_BIN='never-execute',GITHUB_EVENT_PATH=str(event),DOUYIN_COOKIE='synthetic')
    def test_unrun_gate_never_starts_child(self):
        with patch.object(runner.subprocess,'run') as child:
            with self.assertRaises(AssertionError): runner.run_probe(self.env)
            child.assert_not_called()
    def test_legacy_gate_is_mandatory(self):
        with patch.object(runner.base,'offline_gate',side_effect=ValueError('fixed')) as gate:
            with self.assertRaises(ValueError): runner.offline_gate(self.folder)
            gate.assert_called_once_with(self.folder)
    def test_new_unrun_gate_rejected(self):
        with patch.object(runner.base,'offline_gate'):
            with self.assertRaises(AssertionError): runner.offline_gate(self.folder)
    def test_partial_policy_rejected(self):
        (self.folder/'redirect-offline-exit-code.txt').write_text('0')
        runner.write(self.folder,'redirect-policy-tests.json',{'exact_target':True})
        with patch.object(runner.base,'offline_gate'):
            with self.assertRaises(AssertionError): runner.offline_gate(self.folder)
    def test_missing_cookie_no_launch(self):
        self.env.pop('DOUYIN_COOKIE')
        with patch.object(runner,'offline_gate'),patch.object(runner.subprocess,'run') as child:
            self.assertEqual(runner.run_probe(self.env),2); child.assert_not_called()
    def test_cookie_control_character_no_launch(self):
        self.env['DOUYIN_COOKIE']='synthetic\rvalue'
        with patch.object(runner,'offline_gate'),patch.object(runner.subprocess,'run') as child:
            self.assertEqual(runner.run_probe(self.env),2); child.assert_not_called()
    def test_child_environment_and_no_success_forgery(self):
        self.env['AWS_SECRET_ACCESS_KEY']='inherited-synthetic'
        def child(args,**kw):
            self.assertEqual(args,['never-execute','--media-redirect-probe'])
            self.assertNotIn('AWS_SECRET_ACCESS_KEY',kw['env'])
            self.assertNotIn('synthetic',' '.join(args))
            self.assertEqual(kw['stdout'],runner.subprocess.DEVNULL); self.assertEqual(kw['stderr'],runner.subprocess.DEVNULL)
            return type('Exit',(),{'returncode':0})()
        with patch.object(runner,'offline_gate'),patch.object(runner.subprocess,'run',side_effect=child) as launch:
            self.assertEqual(runner.run_probe(self.env),1); self.assertEqual(launch.call_count,1)
    def test_timeout_no_retry(self):
        with patch.object(runner,'offline_gate'),patch.object(runner.subprocess,'run',side_effect=runner.subprocess.TimeoutExpired('fixed',180)) as launch:
            self.assertEqual(runner.run_probe(self.env),1); self.assertEqual(launch.call_count,1)
        summary=json.loads((self.folder/'probe-summary.json').read_text())
        self.assertIsNone(summary['MEDIA_REQUEST_COUNT']); self.assertIsNone(summary['worklist']['request_count'])
        runner.verify(self.folder)
    def test_empty_preparation_evidence_valid(self): runner.verify(self.folder)
    def test_no_production_approval(self):
        runner.write(self.folder,'approved-hosts.json',[runner.TARGET])
        with self.assertRaises(AssertionError): runner.verify(self.folder)
    def test_location_and_signature_never_artifacts(self):
        for marker in ('https://fixture.invalid/private','fixture_token=hidden','Cookie: hidden','a_bogus=hidden','1234567890123456789'):
            with self.subTest(marker=marker):
                runner.write(self.folder,'sample-coverage.json',dict(unexpected=marker))
                with self.assertRaises(AssertionError): runner.verify(self.folder)
    def test_artifact_names_explicit_and_no_media(self):
        self.assertEqual(len(runner.ARTIFACTS),32); self.assertEqual(len(set(runner.ARTIFACTS)),32)
        self.assertFalse(any('*' in x or x.endswith(('.mp4','.part')) for x in runner.ARTIFACTS))
    def test_no_reused_host_observation_in_seed(self):
        self.assertEqual(json.loads((self.folder/'hop-observations.json').read_text()),[])
        summary=json.loads((self.folder/'probe-summary.json').read_text())
        self.assertEqual(summary['REDIRECT_TARGET_PROBE'],'NOT_RUN'); self.assertEqual(summary['SF11_PROBE'],'NOT_RUN')
    def test_controlled_first_location_and_no_target_follow(self):
        http,thread=server()
        try:
            c=HTTPConnection('127.0.0.1',http.server_port,timeout=3)
            c.request('GET','/next206/www',headers={'Range':'bytes=0-0'})
            r=c.getresponse(); self.assertEqual(r.status,302)
            self.assertTrue(r.getheader('Location').startswith('https://'+runner.TARGET+'/')); r.read(); c.close()
            self.assertEqual(http.counts,{'www':1}); self.assertFalse(http.auth_seen); self.assertTrue(http.range_ok)
        finally: http.shutdown(); http.server_close(); thread.join(timeout=2)
    def test_controlled_next_range_and_sf11_independent(self):
        http,thread=server()
        try:
            for role in ('target','sf11'):
                c=HTTPConnection('127.0.0.1',http.server_port,timeout=3)
                c.request('GET','/sf11Present/'+role,headers={'Range':'bytes=0-0'})
                r=c.getresponse(); self.assertEqual(r.status,206); self.assertEqual(r.getheader('Content-Range'),'bytes 0-0/20'); self.assertEqual(r.read(),b'x'); c.close()
            self.assertEqual(http.counts,{'target':1,'sf11':1})
        finally: http.shutdown(); http.server_close(); thread.join(timeout=2)

if __name__=='__main__': unittest.main()
