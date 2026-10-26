"""Synthetic offline tests; no real credentials or network."""
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import auth_pagination as pagination


class PaginationLauncherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.secret = 'offline_fixture=synthetic_only'
        self.event = self.folder/'event.json'
        self.event.write_text(json.dumps({'inputs':{'authorized_own_session':True,'profile_url':'https://www.douyin.com/user/offline_fixture'}}))
        self.env = dict(PAGINATION_EVIDENCE_DIR=str(self.folder), GITHUB_EVENT_PATH=str(self.event),
                        DOUYIN_COOKIE=self.secret,PAGINATION_BIN='fixture-bin',PATH=os.environ.get('PATH',''),UNRELATED_SECRET='not_forwarded')
        for name,ids in [('selftest-results.json',[f'{prefix}-{n:03}' for prefix in ('OFF','AUTH') for n in range(1,20)]),
                         ('pagination-selftest-results.json',[f'PAG-{n:03}' for n in range(1,25)])]:
            pagination.write(self.folder,name,{'status':'PASS','onlineEntryCalled':False,'mediaDownloaded':False,'cases':[{'id':i,'status':'PASS'} for i in ids]})
        for name in ('build-exit-code.txt','offline-exit-code.txt'): (self.folder/name).write_text('0\n')

    def result(self): return json.loads((self.folder/'pagination-result.json').read_text())
    def no_leak(self):
        for p in self.folder.rglob('*'):
            if p.is_file(): self.assertNotIn(self.secret,p.read_text())
    def blocked(self,reason):
        with patch.object(pagination.subprocess,'run') as child:
            self.assertEqual(pagination.run_pagination(self.env),2)
            child.assert_not_called()
        self.assertEqual(self.result()['failure_reason'],reason)
        self.assertEqual(self.result()['request_count'],0)
        self.no_leak()
    def test_missing_cookie(self):
        self.env.pop('DOUYIN_COOKIE'); self.blocked('CREDENTIAL_MISSING')
        self.assertIs(self.result()['credential_present'],False)
    def test_missing_consent(self):
        self.event.write_text(json.dumps({'inputs':{'profile_url':'https://www.douyin.com/user/offline_fixture'}}))
        self.blocked('AUTHORIZATION_REQUIRED')
    def test_cookie_control_characters(self):
        self.env['DOUYIN_COOKIE']+='\n'; self.blocked('CREDENTIAL_CONFIGURATION_REJECTED')
    def test_invalid_profile(self):
        self.event.write_text(json.dumps({'inputs':{'authorized_own_session':True,'profile_url':'https://example.org/user/x'}}))
        self.blocked('PROFILE_PARSE_ERROR')
    def test_missing_offline_suite(self):
        (self.folder/'pagination-selftest-results.json').unlink(); self.blocked('OFFLINE_GATE_FAILED')
    def test_failed_offline_case(self):
        p=self.folder/'pagination-selftest-results.json'; data=json.loads(p.read_text()); data['cases'][0]['status']='FAIL'
        pagination.write(self.folder,p.name,data); self.blocked('OFFLINE_GATE_FAILED')
    def test_missing_offline_case(self):
        p=self.folder/'pagination-selftest-results.json'; data=json.loads(p.read_text()); data['cases'].pop()
        pagination.write(self.folder,p.name,data); self.blocked('OFFLINE_GATE_FAILED')
    def test_duplicate_offline_id(self):
        p=self.folder/'pagination-selftest-results.json'; data=json.loads(p.read_text()); data['cases'][1]['id']='PAG-001'
        pagination.write(self.folder,p.name,data); self.blocked('OFFLINE_GATE_FAILED')
    def test_failed_build(self):
        (self.folder/'build-exit-code.txt').write_text('1'); self.blocked('OFFLINE_GATE_FAILED')
    def test_child_isolation(self):
        def child(argv,**kw):
            self.assertEqual(argv,['fixture-bin','--authenticated-pagination'])
            self.assertNotIn('UNRELATED_SECRET',kw['env'])
            self.assertEqual(kw['env']['DOUYIN_COOKIE'],self.secret)
            self.assertEqual(kw['stdout'],subprocess.DEVNULL); self.assertEqual(kw['stderr'],subprocess.DEVNULL)
            self.assertEqual(kw['timeout'],240)
            pagination.write(self.folder,'pagination-result.json',{'pipeline_completed':True,'request_count':3,'statuses':{'PAGINATION_CORRECTNESS':'PASS'}})
            return subprocess.CompletedProcess(argv,0)
        output=io.StringIO()
        with patch.object(pagination.subprocess,'run',side_effect=child),contextlib.redirect_stdout(output),contextlib.redirect_stderr(output):
            self.assertEqual(pagination.run_pagination(self.env),0)
        self.assertEqual(output.getvalue(),''); self.no_leak()
    def test_zero_exit_without_result_fails(self):
        with patch.object(pagination.subprocess,'run',return_value=subprocess.CompletedProcess([],0)):
            self.assertEqual(pagination.run_pagination(self.env),1)
    def test_nonzero_exit_propagates(self):
        with patch.object(pagination.subprocess,'run',return_value=subprocess.CompletedProcess([],2)):
            self.assertEqual(pagination.run_pagination(self.env),2)
    def test_exception_suppressed_no_retry(self):
        output=io.StringIO()
        with patch.object(pagination.subprocess,'run',side_effect=OSError(self.secret)) as child,contextlib.redirect_stdout(output),contextlib.redirect_stderr(output):
            self.assertEqual(pagination.run_pagination(self.env),1)
            self.assertEqual(child.call_count,1)
        self.assertEqual(output.getvalue(),''); self.no_leak()
    def test_exhaustion_inconclusive_is_not_error(self):
        def child(argv,**kw):
            pagination.write(self.folder,'pagination-result.json',{'pipeline_completed':True,'request_count':1,'stop_reason':'SERVER_EXHAUSTED','statuses':{'PAGINATION_CORRECTNESS':'NOT_VERIFIED'}})
            return subprocess.CompletedProcess(argv,0)
        with patch.object(pagination.subprocess,'run',side_effect=child): self.assertEqual(pagination.run_pagination(self.env),0)
        self.assertEqual(self.result()['statuses']['PAGINATION_CORRECTNESS'],'NOT_VERIFIED')
    def test_excess_request_result_rejected(self):
        def child(argv,**kw):
            pagination.write(self.folder,'pagination-result.json',{'pipeline_completed':True,'request_count':4})
            return subprocess.CompletedProcess(argv,0)
        with patch.object(pagination.subprocess,'run',side_effect=child): self.assertEqual(pagination.run_pagination(self.env),1)
    def test_initialize_does_not_persist_secret_or_profile(self):
        env=dict(self.env,PAGINATION_TEMP=str(self.folder),GITHUB_ENV=str(self.folder/'env'),GITHUB_OUTPUT=str(self.folder/'out'))
        self.assertEqual(pagination.main('initialize',env),0)
        self.assertNotIn('DOUYIN_COOKIE',(self.folder/'env').read_text())
        for p in (self.folder/'doustudio-auth-pagination').iterdir(): self.assertNotIn('offline_fixture',p.read_text())
        self.no_leak()
    def test_finalizer_reports_upstream_protection_failure(self):
        pagination.write(self.folder,'pagination-result.json',{'statuses':{},'pipeline_completed':False})
        env=dict(self.env,INIT_OUTCOME='success',BUILD_OUTCOME='success',OFFLINE_OUTCOME='failure',PAGINATION_OUTCOME='skipped')
        with patch.object(pagination.Path,'exists',return_value=True),patch.object(pagination,'command',side_effect=[pagination.SHA,' M fixture.swift']):
            self.assertEqual(pagination.main('finalize',env),1)
        result=json.loads((self.folder/'final-acceptance.json').read_text())
        self.assertEqual(result['statuses']['UPSTREAM_SOURCE_CHANGED'],'YES')
        self.assertEqual(result['statuses']['OFFLINE_SELF_TEST'],'FAIL')
        self.assertEqual(result['statuses']['HARNESS_BUILD'],'PASS')
        self.assertEqual(result['statuses']['MULTI_PAGE_FETCH'],'NOT_RUN')
        self.no_leak()


if __name__=='__main__': unittest.main()
