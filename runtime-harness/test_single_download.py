import json
from pathlib import Path
import tempfile
import unittest
import threading
from http.client import HTTPConnection
from unittest.mock import patch
import single_download as runner
from single_download_tests import DownloadHandler,ThreadingHTTPServer

class SingleDownloadBoundaryTests(unittest.TestCase):
    def setUp(self):
        temp=tempfile.TemporaryDirectory();self.addCleanup(temp.cleanup);self.root=Path(temp.name)
        self.folder=self.root/'evidence';self.folder.mkdir();runner.previous.base.seed(self.folder);runner.previous.seed(self.folder);runner.seed(self.folder)
        self.media=self.root/'doustudio-single-video-media-unit';self.media.mkdir()
        event=self.root/'event.json';event.write_text(json.dumps({'inputs':{'authorized_own_session':'true','authorized_single_video_download':'true','profile_url':'https://www.douyin.com/user/fixture'}}))
        self.env=dict(DOWNLOAD_EVIDENCE_DIR=str(self.folder),DOWNLOAD_MEDIA_ROOT=str(self.media),RUNNER_TEMP=str(self.root),GITHUB_EVENT_PATH=str(event),DOUYIN_COOKIE='synthetic',PROBE_BIN='never-execute')
    def test_original_probe_consent_cannot_authorize_download(self):
        Path(self.env['GITHUB_EVENT_PATH']).write_text(json.dumps({'inputs':{'authorized_own_session':'true','profile_url':'https://www.douyin.com/user/fixture'}}))
        with patch.object(runner,'offline_gate'),patch.object(runner.subprocess,'run') as launch:
            self.assertEqual(runner.run_download(self.env),2);launch.assert_not_called()
    def test_unrun_gate_blocks_process(self):
        with patch.object(runner.subprocess,'run') as launch:
            with self.assertRaises(AssertionError):runner.run_download(self.env)
            launch.assert_not_called()
    def test_redirect_gate_is_required(self):
        with patch.object(runner.previous,'offline_gate',side_effect=ValueError('fixed')) as gate:
            with self.assertRaises(ValueError):runner.offline_gate(self.folder)
            gate.assert_called_once_with(self.folder)
    def test_missing_cookie_no_download(self):
        self.env.pop('DOUYIN_COOKIE')
        with patch.object(runner,'offline_gate'),patch.object(runner.subprocess,'run') as launch:
            self.assertEqual(runner.run_download(self.env),2);launch.assert_not_called()
    def test_cookie_controls_no_download(self):
        self.env['DOUYIN_COOKIE']='synthetic\nvalue'
        with patch.object(runner,'offline_gate'),patch.object(runner.subprocess,'run') as launch:
            self.assertEqual(runner.run_download(self.env),2);launch.assert_not_called()
    def test_child_environment_and_false_success_rejection(self):
        self.env['AWS_SECRET_ACCESS_KEY']='inherited-synthetic'
        def child(args,**kw):
            self.assertEqual(args,['never-execute','--single-video-real-download'])
            self.assertNotIn('AWS_SECRET_ACCESS_KEY',kw['env']);self.assertEqual(kw['env']['REAL_DOWNLOAD_AUTHORIZED'],'true')
            self.assertEqual(kw['stdout'],runner.subprocess.DEVNULL);self.assertEqual(kw['stderr'],runner.subprocess.DEVNULL)
            return type('Exit',(),{'returncode':0})()
        with patch.object(runner,'offline_gate'),patch.object(runner.subprocess,'run',side_effect=child) as launch:
            self.assertEqual(runner.run_download(self.env),1);self.assertEqual(launch.call_count,1)
        self.assertFalse(self.media.exists())
    def test_timeout_cleans_owned_files_and_never_retries(self):
        (self.media/'partial.part').write_bytes(b'synthetic')
        with patch.object(runner,'offline_gate'),patch.object(runner.subprocess,'run',side_effect=runner.subprocess.TimeoutExpired('fixed',420)) as launch:
            self.assertEqual(runner.run_download(self.env),1);self.assertEqual(launch.call_count,1)
        self.assertFalse(self.media.exists())
        cleanup=json.loads((self.folder/'cleanup-results.json').read_text());self.assertEqual(cleanup['wrapper_cleanup'],'PASS');self.assertEqual(cleanup['wrapper_residual_files_before_cleanup'],1)
        counts=json.loads((self.folder/'request-counts.json').read_text());self.assertIsNone(counts['cdn'])
    def test_cleanup_rejects_unowned_directory(self):
        other=self.root/'unrelated';other.mkdir();(other/'keep').write_text('keep')
        self.env['DOWNLOAD_MEDIA_ROOT']=str(other)
        with self.assertRaises(AssertionError):runner.cleanup_media(self.env)
        self.assertTrue((other/'keep').exists())
    def test_cleanup_idempotent_preserves_first_residual_count(self):
        (self.media/'partial.part').touch();runner.cleanup_media(self.env);runner.cleanup_media(self.env)
        self.assertEqual(json.loads((self.folder/'cleanup-results.json').read_text())['wrapper_residual_files_before_cleanup'],1)
    def test_seed_does_not_claim_real_download(self):
        runner.verify(self.folder)
        summary=json.loads((self.folder/'download-summary.json').read_text())
        self.assertEqual(summary['REAL_VIDEO_DOWNLOAD'],'NOT_RUN');self.assertEqual(summary['NO_WATERMARK'],'NOT_VERIFIED')
    def test_no_production_approval(self):
        runner.write(self.folder,'approved-hosts.json',['v5-dy-ov-experiment.zjcdn.com'])
        with self.assertRaises(AssertionError):runner.verify(self.folder)
    def test_sensitive_strings_and_ids_rejected(self):
        for value in ('https://fixture.invalid/a?secret=x','Cookie: synthetic','Authorization: synthetic','fixture_token=x','1234567890123456789','PRIVATE_TITLE_MARKER'):
            with self.subTest(value=value):
                with self.assertRaises(AssertionError):runner.safe_value({'unexpected':value})
    def test_long_decimal_is_not_misclassified_as_work_id(self):runner.safe_value({'cancel_ms':0.00012345678901234567,'sha256':'a'*64})
    def test_explicit_artifact_list_no_media(self):
        self.assertEqual(len(runner.ARTIFACTS),len(set(runner.ARTIFACTS)))
        self.assertFalse(any('*' in x or x.endswith(('.mp4','.part','.png','.jpg','.wav')) for x in runner.ARTIFACTS))
    def test_request_count_above_single_limit_rejected(self):
        runner.write(self.folder,'request-counts.json',dict(worklist=1,entry=1,cdn=2,retries=0))
        with self.assertRaises(AssertionError):runner.verify(self.folder)
    def test_complete_and_partial_range_fixture_headers(self):
        httpd=ThreadingHTTPServer(('127.0.0.1',0),DownloadHandler);httpd.daemon_threads=True
        httpd.guard=threading.Lock();httpd.counts={};httpd.auth_seen=False;httpd.range_seen=False
        httpd.valid=b'\x00\x00\x00\x18ftyp'+b'x'*56;httpd.corrupt=b''
        thread=threading.Thread(target=httpd.serve_forever,daemon=True);thread.start()
        try:
            for case,length in (('full206',64),('partial206',32),('oneByte206',1)):
                connection=HTTPConnection('127.0.0.1',httpd.server_port,timeout=3);connection.request('GET','/'+case)
                response=connection.getresponse();self.assertEqual(response.status,206)
                self.assertEqual(response.getheader('Content-Range'),f'bytes 0-{length-1}/64');self.assertEqual(len(response.read()),length);connection.close()
            self.assertFalse(httpd.auth_seen);self.assertFalse(httpd.range_seen)
        finally:httpd.shutdown();httpd.server_close();thread.join(timeout=2)
    def test_unknown_length_fixture_sends_complete_chunked_body(self):
        httpd=ThreadingHTTPServer(('127.0.0.1',0),DownloadHandler);httpd.daemon_threads=True
        httpd.guard=threading.Lock();httpd.counts={};httpd.auth_seen=False;httpd.range_seen=False;httpd.valid=b'synthetic-fixture';httpd.corrupt=b''
        thread=threading.Thread(target=httpd.serve_forever,daemon=True);thread.start()
        try:
            connection=HTTPConnection('127.0.0.1',httpd.server_port,timeout=3);connection.request('GET','/unknownLength')
            response=connection.getresponse();self.assertEqual(response.status,200);self.assertIsNone(response.getheader('Content-Length'))
            self.assertEqual(response.getheader('Transfer-Encoding'),'chunked');self.assertEqual(response.read(),httpd.valid);connection.close()
        finally:httpd.shutdown();httpd.server_close();thread.join(timeout=2)

if __name__=='__main__':unittest.main()
