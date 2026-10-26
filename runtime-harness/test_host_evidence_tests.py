import json
from pathlib import Path
import tempfile
import unittest
import host_evidence_tests as runner

class EvidenceArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup);self.root=Path(self.temp.name)
        for name in runner.RESULTS:runner.write(self.root,name,{'status':'NOT_RUN'})
        runner.write(self.root,'approved-hosts.json',[]);(self.root/'offline-exit-code.txt').write_text('NOT_RUN')
    def test_unrun_evidence_not_marked_pass(self):runner.verify(self.root)
    def test_fake_success_without_swift_results_rejected(self):
        (self.root/'offline-exit-code.txt').write_text('0')
        with self.assertRaises(FileNotFoundError):runner.verify(self.root)
    def test_url_rejected(self):
        runner.write(self.root,runner.RESULTS[0],{'unexpected':'https://fixture.invalid/a'})
        with self.assertRaises(AssertionError):runner.verify(self.root)
    def test_private_marker_rejected(self):
        runner.write(self.root,runner.RESULTS[0],{'unexpected':'PRIVATE_TITLE_MARKER'})
        with self.assertRaises(AssertionError):runner.verify(self.root)
    def test_id_rejected(self):
        runner.write(self.root,runner.RESULTS[0],{'unexpected':'1000000000000000000'})
        with self.assertRaises(AssertionError):runner.verify(self.root)
    def test_approval_rejected(self):
        runner.write(self.root,'approved-hosts.json',['fixture.invalid'])
        with self.assertRaises(AssertionError):runner.verify(self.root)
    def test_artifact_list_explicit(self):
        self.assertEqual(len(runner.ARTIFACTS),len(set(runner.ARTIFACTS)))
        self.assertFalse(any('*' in p or p.endswith(('.mp4','.part')) for p in runner.ARTIFACTS))
    def test_fixture_literal_in_compiler_log_redacted(self):
        path=self.root/'build.log';path.write_text('File.swift:7 error: fixture mismatch\nhttps://fixture.invalid/hidden-media-path?fixture_token=x\n')
        runner.sanitize_fixture_logs(self.root)
        self.assertIn('File.swift:7 error:',path.read_text());self.assertNotIn('://',path.read_text())

if __name__=='__main__':unittest.main()
