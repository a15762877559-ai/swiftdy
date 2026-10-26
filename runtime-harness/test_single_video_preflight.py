"""Tests the closed gate, not an unimplemented media transport or byte limiter."""
import ast
import contextlib
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import single_video_preflight as gate


class ClosedDownloadGate(unittest.TestCase):
    def event(self,**values):
        return {'inputs':dict(profile_url='https://www.douyin.com/user/offline_fixture',work_index='0',authorized_own_session=True,**values)}
    def test_valid_input_remains_range_unverified(self):
        result=gate.input_validation(self.event())
        self.assertTrue(result['valid']); self.assertEqual(result['index_in_actual_worklist'],'NOT_VERIFIED')
    def test_index_syntax_bounds(self):
        for index in ('-1','50','0.5','1e2','00','', '100000'):
            e=self.event(); e['inputs']['work_index']=index
            self.assertFalse(gate.input_validation(e)['valid'])
    def test_authorization_required(self):
        e=self.event(); e['inputs']['authorized_own_session']=False
        self.assertFalse(gate.input_validation(e)['valid'])
    def test_foreign_short_or_query_profile_rejected(self):
        for profile in ('https://example.org/user/a','https://v.douyin.com/a','https://www.douyin.com/user/a?x=1'):
            e=self.event();e['inputs']['profile_url']=profile
            self.assertFalse(gate.input_validation(e)['valid'])
    def test_gate_cannot_be_enabled_by_environment(self):
        with patch.dict(os.environ,{'RECEIVE_BYTE_LIMIT':'ENFORCED','ALLOW_DOWNLOAD':'true'}):
            with self.assertRaisesRegex(RuntimeError,'^RECEIVE_HARD_LIMIT_NOT_VERIFIED$'): gate.require_hard_limit()
    def test_repeated_gate_calls_never_download(self):
        for _ in range(2):
            with self.assertRaises(RuntimeError): gate.require_hard_limit()
    def test_gate_no_process_network_or_media_files(self):
        with tempfile.TemporaryDirectory() as tmp,patch.object(gate.subprocess,'check_output') as process:
            output=io.StringIO()
            with contextlib.redirect_stdout(output): self.assertEqual(gate.main('gate',{'VIDEO_EVIDENCE_DIR':tmp}),78)
            process.assert_not_called()
            files=list(Path(tmp).iterdir());self.assertEqual([p.name for p in files],['download-gate.json'])
            result=json.loads(files[0].read_text());self.assertEqual(result['media_requests'],0)
            self.assertFalse(result['credential_read']);self.assertEqual(result['partial_files_created'],0)
    def test_secret_is_never_read(self):
        class GuardedEnvironment(dict):
            def __getitem__(self,key):
                if 'COOKIE' in key or 'TOKEN' in key: raise AssertionError('Credential accessed')
                return super().__getitem__(key)
            def get(self,key,default=None):
                if 'COOKIE' in key or 'TOKEN' in key: raise AssertionError('Credential accessed')
                return super().get(key,default)
        with tempfile.TemporaryDirectory() as tmp,contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(gate.main('gate',GuardedEnvironment(VIDEO_EVIDENCE_DIR=tmp)),78)
    def test_initialize_does_not_persist_inputs(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder=Path(tmp); (folder/'event.json').write_text(json.dumps(self.event()))
            env=dict(VIDEO_TEMP=tmp,GITHUB_EVENT_PATH=str(folder/'event.json'),GITHUB_ENV=str(folder/'env'),GITHUB_OUTPUT=str(folder/'output'))
            self.assertEqual(gate.main('initialize',env),0)
            for p in (folder/'doustudio-single-video-evidence').iterdir(): self.assertNotIn('offline_fixture',p.read_text())
    def test_audit_metadata_cannot_unlock_gate(self):
        with self.assertRaises(RuntimeError): gate.require_hard_limit()
        self.assertEqual(gate.STATUSES['RECEIVE_BYTE_LIMIT'],'NOT_ENFORCED')
        self.assertEqual(gate.STATUSES['OFFLINE_SELF_TEST'],'NOT_RUN')
    def test_source_has_no_network_dependencies(self):
        tree=ast.parse(Path(gate.__file__).read_text(encoding='utf-8'))
        imports={n.name.split('.')[0] for node in ast.walk(tree) if isinstance(node,ast.Import) for n in node.names}
        self.assertTrue(imports<={'hashlib','json','os','re','subprocess','sys'})
        source=Path(gate.__file__).read_text(encoding='utf-8')
        self.assertNotIn('DOUYIN_COOKIE',source)
        self.assertNotIn('RuntimeAcceptance',source)


if __name__=='__main__': unittest.main()
