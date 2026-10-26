"""Offline launcher tests with synthetic values and mocked process execution."""
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import auth_preflight as auth


class CredentialIsolation(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.event = self.folder / 'event.json'
        self.secret = 'fixture_only=not_a_real_account'
        self.env = {'AUTH_EVIDENCE_DIR':str(self.folder), 'GITHUB_EVENT_PATH':str(self.event),
                    'DOUYIN_COOKIE':self.secret, 'AUTH_BIN':'fixture-executable', 'PATH':os.environ.get('PATH',''),
                    'UNRELATED_SECRET':'must_not_be_forwarded'}
        self.event.write_text(json.dumps({'inputs':{'authorized_own_session':True,'profile_url':'https://www.douyin.com/user/offline_fixture'}}))

    def result(self):
        return json.loads((self.folder / 'auth-result.json').read_text())

    def assert_no_secret_files(self):
        for p in self.folder.iterdir():
            if p.is_file(): self.assertNotIn(self.secret, p.read_text())

    def blocked(self, category):
        with patch.object(auth.subprocess,'run') as child:
            self.assertEqual(auth.run_preflight(self.env),2)
            child.assert_not_called()
        self.assertEqual(self.result()['failure_category'],category)
        self.assertEqual(self.result()['observation']['request_count'],0)
        self.assert_no_secret_files()

    def test_missing_secret(self):
        self.env.pop('DOUYIN_COOKIE')
        self.blocked('CREDENTIAL_MISSING')
        self.assertIs(self.result()['credential_present'],False)

    def test_blank_secret(self):
        self.env['DOUYIN_COOKIE']='  '
        self.blocked('CREDENTIAL_MISSING')

    def test_no_authorization(self):
        self.event.write_text(json.dumps({'inputs':{'authorized_own_session':False,'profile_url':'https://www.douyin.com/user/offline_fixture'}}))
        self.blocked('AUTHORIZATION_REQUIRED')

    def test_injected_secret(self):
        self.env['DOUYIN_COOKIE']=self.secret+'\nheader:bad'
        self.blocked('CREDENTIAL_CONFIGURATION_REJECTED')

    def test_invalid_profile(self):
        self.event.write_text(json.dumps({'inputs':{'authorized_own_session':True,'profile_url':'https://example.org/user/fixture'}}))
        self.blocked('PROFILE_PARSE_ERROR')

    def test_child_isolation_and_no_secret_serialization(self):
        def child(argv, **kwargs):
            self.assertEqual(argv,['fixture-executable','--authenticated-preflight'])
            self.assertEqual(kwargs['env']['DOUYIN_COOKIE'],self.secret)
            self.assertNotIn('UNRELATED_SECRET',kwargs['env'])
            self.assertEqual(kwargs['stdout'],subprocess.DEVNULL)
            self.assertEqual(kwargs['stderr'],subprocess.DEVNULL)
            self.assertEqual(kwargs['timeout'],180)
            auth.write(self.folder,'auth-result.json',{'credential_present':True,'statuses':{'AUTH_PREFLIGHT':'PASS'}})
            return subprocess.CompletedProcess(argv,0)
        output=io.StringIO()
        with patch.object(auth.subprocess,'run',side_effect=child),contextlib.redirect_stdout(output),contextlib.redirect_stderr(output):
            self.assertEqual(auth.run_preflight(self.env),0)
        self.assertEqual(output.getvalue(),'')
        self.assert_no_secret_files()

    def test_child_failure_is_not_success(self):
        with patch.object(auth.subprocess,'run',return_value=subprocess.CompletedProcess([],2)):
            self.assertEqual(auth.run_preflight(self.env),2)
        self.assert_no_secret_files()

    def test_zero_exit_without_success_result_is_failure(self):
        with patch.object(auth.subprocess,'run',return_value=subprocess.CompletedProcess([],0)):
            self.assertEqual(auth.run_preflight(self.env),1)

    def test_exception_details_suppressed(self):
        output=io.StringIO()
        with patch.object(auth.subprocess,'run',side_effect=OSError(self.secret)),contextlib.redirect_stdout(output),contextlib.redirect_stderr(output):
            self.assertEqual(auth.run_preflight(self.env),1)
        self.assertEqual(output.getvalue(),'')
        self.assert_no_secret_files()

    def test_initializer_does_not_persist_credential(self):
        env=dict(self.env,AUTH_TEMP=str(self.folder),GITHUB_ENV=str(self.folder/'env'),GITHUB_OUTPUT=str(self.folder/'out'))
        self.assertEqual(auth.main('initialize',env),0)
        self.assertNotIn('DOUYIN_COOKIE',(self.folder/'env').read_text())
        for p in self.folder.rglob('*'):
            if p.is_file(): self.assertNotIn(self.secret,p.read_text())


if __name__=='__main__':
    unittest.main()
