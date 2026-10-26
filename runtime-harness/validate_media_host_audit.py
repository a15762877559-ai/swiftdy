"""Static validation only; never claims a Swift compilation or runtime test."""
import ast
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/'.git/task-validation/pylibs'))
sys.path.insert(0,str(root/'runtime-harness'))
import yaml
import media_host_audit as audit

def main():
    for name in ('media_host_audit.py','test_media_host_audit.py','validate_media_host_audit.py'):
        ast.parse((root/'runtime-harness'/name).read_text(),filename=name)
    path=root/'.github/workflows/doustudio-media-host-audit.yml';text=path.read_text()
    doc=yaml.load(text,Loader=yaml.BaseLoader)
    assert set(doc['on'])=={'workflow_dispatch'} and doc['permissions']=={'contents':'read'}
    inputs=doc['on']['workflow_dispatch']['inputs'];assert set(inputs)=={'profile_url','authorized_own_session'}
    assert 'default' not in inputs['profile_url'] and inputs['authorized_own_session']['default']=='false'
    job=doc['jobs']['audit'];assert job['runs-on']=='xcode-27' and int(job['timeout-minutes'])<=20
    assert 'env' not in job and 'env' not in doc
    steps=job['steps'];uses=[s for s in steps if 'uses' in s]
    allowed={'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1','actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9'}
    assert all(s['uses'] in allowed for s in uses)
    checkouts=[s for s in uses if s['uses'].startswith('actions/checkout@')]
    assert len(checkouts)==2 and all(s['with']['persist-credentials']=='false' for s in checkouts)
    assert checkouts[1]['with']['ref']==audit.SHA
    assert text.count('secrets.')==1 and next(s for s in steps if s.get('id')=='observe')['env']['DOUYIN_COOKIE']=='${{ secrets.DOUYIN_COOKIE }}'
    for step in steps:
        if 'run' in step:subprocess.run(['C:/Program Files/Git/bin/bash.exe','-n'],input=step['run'],text=True,check=True)
    offline=next(s for s in steps if s.get('id')=='offline')
    assert '(deny network*)' in offline['run'] and '--media-host-audit-self-test' in offline['run']
    artifact=steps[-1];assert "steps.finalize.outcome == 'success'" in artifact['if']
    assert {p.rsplit('/',1)[-1] for p in artifact['with']['path'].splitlines()}==set(audit.ARTIFACT_FILES)
    assert artifact['with']['retention-days']=='3'
    swift=(root/'runtime-harness/Sources/RuntimeAcceptance/MediaHostAudit.swift').read_text()
    assert swift.count('endpoints.accountTimeline(')==1 and 'maxRetry:0' in swift and 'maxPages:1' in swift
    assert 'AuthPreflightTransport(input:input,base:URLSessionTransport())' in swift
    for token in ('Downloader(','.download(','.stream(','.data(for:', 'QualityProbe(', 'originalQualityURL('):assert token not in swift
    baseline='ba17ce255ef99fe2c13c6125b05c09f31413ea00'
    original=subprocess.check_output(['git','ls-tree','-r','--name-only',baseline],cwd=root,text=True).splitlines()
    changed=[]
    for name in original:
        prior=subprocess.check_output(['git','show',f'{baseline}:{name}'],cwd=root)
        now=(root/name).read_bytes()
        if now.replace(b'\r\n',b'\n')!=prior.replace(b'\r\n',b'\n'):changed.append(name)
    assert changed==['runtime-harness/Sources/RuntimeAcceptance/RuntimeAcceptance.swift'],changed
    lint=shutil.which('actionlint')
    if lint:subprocess.run([lint,'-ignore','label "xcode-27" is unknown',str(path)],check=True)
    result=dict(local_static_validation='PASS',python_syntax='PASS',yaml_structure='PASS',shell_syntax='PASS',
        credential_isolation='PASS_STATIC_AND_WRAPPER_TESTS',media_request_path='ABSENT_IN_AUDIT_MODE',
        artifact_whitelist='PASS',existing_files_checked=len(original),existing_files_changed=changed,
        existing_workflows_unchanged=True,upstream_sha=audit.SHA,swift_compilation='NOT_RUN',swift_offline_tests='NOT_RUN',
        actionlint='PASS' if lint else 'NOT_INSTALLED_NOT_RUN',auto_triggered=False)
    out=root/'evidence/doustudio-media-host-allowlist-audit-01';out.mkdir(parents=True,exist_ok=True)
    audit.write(out,'local-validation.json',result);print(json.dumps(result))

if __name__=='__main__':main()
