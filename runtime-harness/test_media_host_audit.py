import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import media_host_audit as audit

class AuditBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);self.event=self.root/'event.json'
        self.event.write_text(json.dumps({'inputs':{'authorized_own_session':True,'profile_url':'https://www.douyin.com/user/fixture'}}))
        audit.seed(self.root)
        self.env=dict(HOST_EVIDENCE_DIR=str(self.root),GITHUB_EVENT_PATH=str(self.event),HOST_BIN='fixture-binary',DOUYIN_COOKIE='synthetic=fixture')
    def denied(self,reason):
        with patch.object(audit.subprocess,'run') as call:
            self.assertEqual(audit.run_audit(self.env),2);call.assert_not_called()
        r=json.loads((self.root/'audit-summary.json').read_text());self.assertEqual(r['failure_category'],reason)
        self.assertEqual(r['observation']['request_count'],0)
        self.assertNotIn('synthetic=fixture',json.dumps(r))
    def test_missing_secret(self):
        self.env.pop('DOUYIN_COOKIE');self.denied('CREDENTIAL_MISSING')
    def test_no_consent(self):
        self.event.write_text(json.dumps({'inputs':{'profile_url':'https://www.douyin.com/user/fixture'}}));self.denied('AUTHORIZATION_REQUIRED')
    def test_cookie_control_character(self):
        self.env['DOUYIN_COOKIE']='fixture\r\nx';self.denied('CREDENTIAL_CONFIGURATION_REJECTED')
    def test_invalid_profile(self):
        self.event.write_text(json.dumps({'inputs':{'authorized_own_session':True,'profile_url':'https://www.douyin.com/user/fixture?x=1'}}));self.denied('PROFILE_PARSE_ERROR')
    def test_no_profile_default(self):
        self.event.write_text(json.dumps({'inputs':{'authorized_own_session':True}}));self.denied('PROFILE_PARSE_ERROR')
    def test_child_environment_and_arguments(self):
        self.env['UNRELATED_SECRET']='must-not-inherit'
        def fake(args,**kw):
            self.assertEqual(args,['fixture-binary','--media-host-audit'])
            self.assertNotIn('UNRELATED_SECRET',kw['env']);self.assertEqual(kw['stdout'],subprocess.DEVNULL)
            self.assertEqual(kw['stderr'],subprocess.DEVNULL)
            r=json.loads((self.root/'audit-summary.json').read_text());r['collection_completed']=True;audit.write(self.root,'audit-summary.json',r)
            return subprocess.CompletedProcess(args,0)
        with patch.object(audit.subprocess,'run',side_effect=fake) as call:
            self.assertEqual(audit.run_audit(self.env),0);self.assertEqual(call.call_count,1)
    def test_timeout_no_retry(self):
        with patch.object(audit.subprocess,'run',side_effect=subprocess.TimeoutExpired('fixture',180)) as call:
            self.assertEqual(audit.run_audit(self.env),1);self.assertEqual(call.call_count,1)
    def test_exit_zero_without_result_fails(self):
        with patch.object(audit.subprocess,'run',return_value=subprocess.CompletedProcess([],0)):
            self.assertEqual(audit.run_audit(self.env),1)
    def test_nonzero_exit_propagates(self):
        with patch.object(audit.subprocess,'run',return_value=subprocess.CompletedProcess([],2)):
            self.assertEqual(audit.run_audit(self.env),2)
    def test_auto_approval_rejected(self):
        audit.write(self.root,'approved-hosts.json',['unreviewed.fixture.com'])
        with self.assertRaises(AssertionError):audit.finalize(self.root,{})
    def test_url_in_evidence_rejected(self):
        audit.write(self.root,'candidate-hosts.json',['https://media.fixture.com/path?synthetic=fixture'])
        with self.assertRaises(AssertionError):audit.finalize(self.root,{})
    def test_whitelist_never_includes_media(self):
        audit.finalize(self.root,{})
        self.assertFalse(any('*' in x or x.endswith(('.mp4','.part','.zip')) for x in audit.ARTIFACT_FILES))
        self.assertEqual(json.loads((self.root/'approved-hosts.json').read_text()),[])

if __name__=='__main__':unittest.main()
