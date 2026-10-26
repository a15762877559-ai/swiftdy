"""Static checks only; never reports macOS Swift compilation as executed."""
import ast
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import sys
import yaml
import redirect_probe

BASE='f2ed64f8eefa3e5b7a24a701b3220d35b3b2066e'
def validate():
    checks=[]
    for filename in ('doustudio-media-redirect-probe.yml','doustudio-media-redirect-probe-offline.yml'):
        p=Path('.github/workflows')/filename; text=p.read_text(); wf=yaml.safe_load(text)
        trigger=wf.get('on',wf.get(True)); assert set(trigger)=={'workflow_dispatch'}
        assert wf['permissions']=={'contents':'read'}
        job=wf['jobs']['probe']; assert job['runs-on']=='xcode-27' and job['timeout-minutes']==20
        steps=job['steps']; offline=filename.endswith('-offline.yml')
        assert sum('secrets.' in json.dumps(x) for x in steps)==(0 if offline else 1)
        ids=[s.get('id') for s in steps]
        assert ids.index('compile')<ids.index('offline')<ids.index('redirect_offline')
        if not offline:
            assert ids.index('redirect_offline')<ids.index('live')
            assert trigger['workflow_dispatch']['inputs']['authorized_own_session']['default'] is False
        for step in steps:
            if step.get('uses','').startswith('actions/checkout@'):
                assert step['uses']=='actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1' and step['with']['persist-credentials'] is False
                if 'repository' in step['with']: assert step['with']['ref']==redirect_probe.base.SHA
            if 'run' in step:
                with tempfile.TemporaryDirectory() as directory:
                    script=Path(directory)/'step.sh'; script.write_text(step['run'])
                    subprocess.run(['C:/Program Files/Git/bin/bash.exe','-n',str(script)],check=True,capture_output=True)
        upload=steps[-1]; assert upload['uses']=='actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9'
        names=[line.rsplit('/',1)[-1] for line in upload['with']['path'].splitlines()]
        assert set(names)==set(redirect_probe.ARTIFACTS) and len(names)==32 and upload['with']['retention-days']==3
        checks.append(dict(file=str(p).replace('\\','/'),status='PASS',checks='manual_only_secret_gate_pins_bash_syntax_explicit_artifacts'))
    for p in Path('runtime-harness').glob('*redirect_probe*.py'): ast.parse(p.read_text())
    changed=subprocess.check_output(['git','diff',BASE,'--name-only','--diff-filter=M'],text=True).splitlines()
    assert set(changed)=={'runtime-harness/Sources/RuntimeAcceptance/MediaHostLiveProbe.swift','runtime-harness/Sources/RuntimeAcceptance/RuntimeAcceptance.swift'}
    assert not subprocess.check_output(['git','diff',BASE,'--name-only','--diff-filter=D'],text=True).strip()
    # Confirm all preexisting workflows, transport, reports and evidence are untouched, including the last live run.
    checks.append(dict(status='PASS',checks='only_existing_task_and_entry_files_modified_historical_and_transport_protected'))
    tree=Path('runtime-harness/Sources/RuntimeAcceptance')
    network=(tree/'RedirectNetworkSafety.swift').read_text()
    assert 'publicAddress(destination.address)' in network and 'NWEndpoint.Host(self.address)' in network
    assert 'maximumLength:16384' in network and 'outbound_connections = 1' in network and 'self.used' in network
    assert 'NWParameters.tcp' in network and 'requiredLocalEndpoint' in network
    controller=(tree/'MediaRedirectProbe.swift').read_text()
    assert 'observation.http_status == 302' in controller and 'budget.reserve(.target)' in controller
    assert 'targetAllowed(location)' in controller and 'AuthPreflightTransport(input:input,base:URLSessionTransport())' in controller
    assert 'maxPages:1' in controller and 'maxRetry:0' in controller
    checks.append(dict(status='PASS',checks='dns_numeric_pin_single_connect_three_roles_original_extractor_no_detail'))
    return dict(TASK='DOUSTUDIOKIT_MEDIA_REDIRECT_PROBE_02',WINDOWS_STATIC='PASS',MACOS_SWIFT_BUILD='NOT_RUN',SWIFT_REDIRECT_OFFLINE_TESTS='NOT_RUN',REAL_REDIRECT_PROBE='NOT_RUN',checks=checks)

if __name__=='__main__':
    result=validate()
    if len(sys.argv)>1: Path(sys.argv[1]).write_text(json.dumps(result,indent=2)+'\n')
    else: print(json.dumps(result,indent=2))
