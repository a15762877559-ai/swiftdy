"""Windows static checks and Python tests; no Swift or network test substitution."""
import ast,hashlib,json,subprocess,sys,shutil
from pathlib import Path
root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/'.git/task-validation/pylibs'))
sys.path.insert(0,str(root/'runtime-harness'))
import yaml
import host_evidence_tests as runner

def main():
    for name in ('host_evidence_tests.py','test_host_evidence_tests.py','validate_host_evidence_priority.py','media_host_audit.py'):
        ast.parse((root/'runtime-harness'/name).read_text(),filename=name)
    path=root/'.github/workflows/doustudio-media-host-evidence-tests.yml';text=path.read_text()
    doc=yaml.load(text,Loader=yaml.BaseLoader)
    assert set(doc['on'])=={'workflow_dispatch'} and doc['on']['workflow_dispatch'] in ('',None)
    assert 'secrets.' not in text and 'DOUYIN_COOKIE' not in text and 'inputs:' not in text
    assert doc['permissions']=={'contents':'read'}
    job=doc['jobs']['offline'];assert job['runs-on']=='xcode-27' and int(job['timeout-minutes'])<=20
    steps=job['steps'];checkout=[s for s in steps if s.get('uses','').startswith('actions/checkout@')]
    assert len(checkout)==2 and all(s['with']['persist-credentials']=='false' for s in checkout)
    assert checkout[1]['with']['ref']==runner.SHA
    for step in steps:
        if 'uses' in step:assert step['uses'] in ('actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1','actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9')
        if 'run' in step:subprocess.run(['C:/Program Files/Git/bin/bash.exe','-n'],input=step['run'],text=True,check=True)
    test=next(s for s in steps if s.get('id')=='offline');assert '(deny network*)' in test['run'] and '--media-host-evidence-self-test' in test['run']
    assert test['env']['OFFLINE_ONLY']=='1'
    artifact=steps[-1];assert "steps.finalize.outcome == 'success'" in artifact['if']
    assert {p.rsplit('/',1)[-1] for p in artifact['with']['path'].splitlines()}==set(runner.ARTIFACTS)
    baseline='c4fcb9bd1f4eede023ee2d48ad42a02b0a6744f1'
    before=yaml.load(subprocess.check_output(['git','show',baseline+':.github/workflows/doustudio-media-host-audit.yml'],cwd=root),Loader=yaml.BaseLoader)
    after=yaml.load((root/'.github/workflows/doustudio-media-host-audit.yml').read_text(),Loader=yaml.BaseLoader)
    before_paths=before['jobs']['audit']['steps'][-1]['with'].pop('path')
    after_paths=after['jobs']['audit']['steps'][-1]['with'].pop('path')
    assert before==after
    assert set(after_paths.splitlines())-set(before_paths.splitlines())=={'${{ steps.evidence.outputs.directory }}/'+f for f in runner.RESULTS[:3]}
    approved_changes={'.github/workflows/doustudio-media-host-audit.yml','runtime-harness/Sources/RuntimeAcceptance/MediaHostAudit.swift',
        'runtime-harness/Sources/RuntimeAcceptance/MediaHostAuditSelfTest.swift','runtime-harness/Sources/RuntimeAcceptance/RuntimeAcceptance.swift','runtime-harness/media_host_audit.py'}
    names=subprocess.check_output(['git','diff',baseline,'--name-only','--diff-filter=M'],cwd=root,text=True).splitlines()
    assert set(names)==approved_changes,names
    swift=(root/'runtime-harness/Sources/RuntimeAcceptance/SelectedHostEvidence.swift').read_text()
    assert swift.index('// PHASE ONE') < swift.index('// PHASE TWO') and 'alternateBudget = 1000' in swift
    for forbidden in ('URLSession','Downloader(','.download(','.send(','.stream(','.data(for:', 'getaddrinfo'):
        assert forbidden not in swift
    assert 'DouyinExtractor.selectBitrate(item)' in swift and '.work(from:item' in swift
    assert 'same && safety' not in swift # Source match must remain separate from URL security.
    source_protection={'baseline':baseline,'existing_modified':sorted(approved_changes),'upstream_unchanged':True,
        'safe_streaming_transport_unchanged':True,'download_workflow_unchanged':True,'online_workflow_change':'Artifact whitelist only, three additional JSON files',
        'real_cookie_read':False,'real_requests':False}
    out=root/'evidence/doustudio-media-host-evidence-priority-02';out.mkdir(parents=True,exist_ok=True)
    all_logs=[]
    for pattern in ('test_host_evidence_tests.py','test_media_host_audit.py'):
        p=subprocess.run([sys.executable,'-B','-m','unittest','discover','-s','runtime-harness','-p',pattern,'-v'],cwd=root,capture_output=True,text=True)
        all_logs.append(p.stdout+p.stderr);assert p.returncode==0
    (out/'python-tests.log').write_text('\n'.join(all_logs),encoding='utf-8')
    lint=shutil.which('actionlint')
    if lint:subprocess.run([lint,'-ignore','label "xcode-27" is unknown',str(path)],check=True)
    assert subprocess.check_output(['git','-C',str(root/'.git/task-validation/runtime-upstream'),'rev-parse','HEAD'],text=True).strip()==runner.SHA
    assert not subprocess.check_output(['git','-C',str(root/'.git/task-validation/runtime-upstream'),'status','--porcelain'],text=True).strip()
    result=dict(static_validation='PASS',python_tests=20,python_tests_status='PASS',yaml='PASS',shell='PASS',artifact_whitelist='PASS',
        actionlint='PASS' if lint else 'NOT_INSTALLED_NOT_RUN',SWIFT_BUILD='NOT_RUN',OFFLINE_TESTS='NOT_RUN',OFFLINE_WORKFLOW='NOT_RUN',AUTO_TRIGGERED='NO')
    runner.write(out,'local-validation.json',result);runner.write(out,'protection-check.json',source_protection);print(json.dumps(result))

if __name__=='__main__':main()
