"""Manual second-hop diagnostics. Reuses the first probe's build, fixture, redaction and source gates."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import live_probe as base
from auth_preflight import write,input_values
from redirect_probe_tests import CASES,POLICY,TARGET,expected

EXTRA=('hop-observations.json','sample-coverage.json','network-target-safety.json',
       'redirect-policy-tests.json','redirect-offline-tests.json','tunnel-tests.json','redirect-offline-exit-code.txt')
ARTIFACTS=base.ARTIFACTS+EXTRA
HOSTS=base.HOSTS|{TARGET}

def seed(folder):
    for name in EXTRA:
        if name.endswith('.json'): write(folder,name,[])
    (folder/'redirect-offline-exit-code.txt').write_text('NOT_RUN\n')
    write(folder,'probe-summary.json',dict(TASK='DOUSTUDIOKIT_MEDIA_REDIRECT_PROBE_02',WWW_INITIAL_RESPONSE='NOT_RUN',
        REDIRECT_TARGET_PROBE='NOT_RUN',SF11_PROBE='NOT_RUN',MEDIA_REQUEST_COUNT=0,MEDIA_RETRIES=0,UNAPPROVED_REDIRECT_FOLLOWED='NO',
        FULL_VIDEO_DOWNLOADED='NO',HOST_SECURITY_REVIEW='BLOCKED',PRODUCTION_ALLOWLIST='EMPTY',NO_WATERMARK='NOT_TESTED',RUST_IMPLEMENTATION='NOT_STARTED',
        MACOS_SWIFT_BUILD='NOT_RUN',OFFLINE_TESTS='NOT_RUN',completed=False))

def offline_gate(folder):
    base.offline_gate(folder)
    assert (folder/'redirect-offline-exit-code.txt').read_text().strip()=='0'
    policy=json.loads((folder/'redirect-policy-tests.json').read_text())
    assert set(policy)==POLICY and all(v is True for v in policy.values())
    result=json.loads((folder/'redirect-offline-tests.json').read_text())
    assert result['scope']=='SYNTHETIC_LOOPBACK_ONLY' and result['status']=='PASS'
    assert result['real_worklist_requests']==result['real_media_requests']==0
    assert len(result['cases'])==len(CASES) and {r['id'] for r in result['cases']}==set(CASES)
    for row in result['cases']:
        assert row['status']=='PASS' and row['swift_exit_code']==0 and row['credential_and_range_check']
        assert expected(row['id'],row['outcome'],row['server_requests'])
    tunnels=json.loads((folder/'tunnel-tests.json').read_text())
    assert tunnels['scope']=='LOOPBACK_ONLY' and tunnels['status']=='PASS' and len(tunnels['cases'])==3
    assert {r['id'] for r in tunnels['cases']}=={'pinnedRelay','wrongAuthority','tlsFailure'}
    assert all(r['status']=='PASS' and r['swift_exit_code']==0 and r['tunnel']['stopped'] and not r['tunnel']['credential_headers_seen'] for r in tunnels['cases'])

def verify(folder):
    base.validate_artifacts(folder)
    for name in EXTRA:
        p=folder/name
        if not p.exists(): continue
        text=p.read_text()
        assert not re.search(r'https?(?::|\\u003[aA])|://|fixture_token|DO_NOT_SERIALIZE|PRIVATE_TITLE|Cookie:|Authorization:|a_bogus|x-bogus|\b[0-9]{17,20}\b',text,re.I)
        if name.endswith('.json'): json.loads(text)
    hops=json.loads((folder/'hop-observations.json').read_text())
    assert len(hops)<=3 and len({h['role'] for h in hops})==len(hops)
    for hop in hops:
        assert hop['role'] in ('www','target','sf11')
        o=hop['observation']
        assert o['host']=={'www':'www.douyin.com','sf11':'sf11-cdn-tos.douyinstatic.com','target':TARGET}[hop['role']]
        assert 0<=o['request_count']<=1 and 0<=o['accepted_bytes']<=1 and o['delegate_received_bytes']>=o['accepted_bytes']
        assert not o['authentication_headers_sent'] and not o['approved']
        if o['request_count']: assert o['completion_callbacks']==1
        assert not o['cancel_requested'] or o['cancel_completed']
        if hop['role']=='target' and o['request_count']:
            first=next(h['observation'] for h in hops if h['role']=='www')
            assert first['http_status']==302 and first['request_count']==1 and first['cancel_completed']
            assert 1<=hop['dns_address_count']<=32
            tunnel=hop['tunnel']
            assert tunnel['public_address_pinned'] and tunnel['stopped'] and not tunnel['credential_headers_seen']
            if hop['network_target_check']=='PASS_PUBLIC_DNS_AND_NUMERIC_ADDRESS_PIN':
                assert tunnel['connect_authority_matched'] and tunnel['outbound_connections']==1
            else:
                assert hop['network_target_check']=='BLOCKED_PINNING_NOT_VERIFIED' and o['result']=='PINNED_TUNNEL_NOT_VERIFIED'
    summary=json.loads((folder/'probe-summary.json').read_text())
    assert summary['PRODUCTION_ALLOWLIST']=='EMPTY' and summary['FULL_VIDEO_DOWNLOADED']=='NO' and summary['MEDIA_RETRIES']==0
    if summary['MEDIA_REQUEST_COUNT'] is None:
        assert not summary.get('completed') and not hops
    else: assert summary['MEDIA_REQUEST_COUNT']==sum(h['observation']['request_count'] for h in hops)<=3
    count=summary.get('worklist',{}).get('request_count',0)
    assert (count is None and not summary.get('completed')) or (count is not None and 0<=count<=1)

def run_probe(env):
    folder=Path(env['REDIRECT_EVIDENCE_DIR'])
    offline_gate(folder)
    consent,profile,valid=input_values(env)
    cookie=env.get('DOUYIN_COOKIE','')
    if not consent or not valid or not cookie.strip() or any(ord(c)<32 or ord(c)==127 for c in cookie): return 2
    child={k:env[k] for k in ('PATH','TMPDIR','SYSTEMROOT') if k in env}
    child.update(DOUYIN_COOKIE=cookie,REDIRECT_PROFILE=profile,REDIRECT_CONSENT='true',REDIRECT_OFFLINE_VERIFIED='true',REDIRECT_EVIDENCE_DIR=str(folder))
    summary=json.loads((folder/'probe-summary.json').read_text())
    summary.update(MEDIA_REQUEST_COUNT=None,worklist={'request_count':None},completed=False,failure_category='CHILD_RESULT_NOT_AVAILABLE')
    write(folder,'probe-summary.json',summary)
    try:
        code=subprocess.run([env['PROBE_BIN'],'--media-redirect-probe'],env=child,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=180,check=False).returncode
    except (OSError,subprocess.TimeoutExpired):
        summary['failure_category']='CHILD_START_OR_TIMEOUT'
        write(folder,'probe-summary.json',summary)
        return 1
    if code==0 and not json.loads((folder/'probe-summary.json').read_text()).get('completed'): return 1
    return code if code>=0 else 1

def main(mode,env):
    if mode=='initialize':
        code=base.main(mode,env)
        folder=Path(env['RUNNER_TEMP'])/'doustudio-live-probe'
        seed(folder)
        with open(env['GITHUB_ENV'],'a',encoding='utf-8') as out: out.write(f'REDIRECT_EVIDENCE_DIR={folder}\n')
        return code
    folder=Path(env['REDIRECT_EVIDENCE_DIR'])
    if mode=='environment': return base.main(mode,env)
    if mode=='offline-seal':
        base.main(mode,env); offline_gate(folder)
    elif mode=='run':
        code=run_probe(env); (folder/'probe-exit-code.txt').write_text(str(code)+'\n'); return code
    elif mode=='finalize':
        base.main(mode,env)
        summary=json.loads((folder/'probe-summary.json').read_text())
        summary['REDIRECT_OFFLINE_TESTS']='NOT_PASSED'
        if (folder/'redirect-offline-exit-code.txt').read_text().strip()=='0':
            offline_gate(folder); summary['REDIRECT_OFFLINE_TESTS']='PASS'
        write(folder,'probe-summary.json',summary)
        verify(folder)
        write(folder,'evidence-index.json',dict(task='DOUSTUDIOKIT_MEDIA_REDIRECT_PROBE_02',run_id=env['GITHUB_RUN_ID'],test_commit=env['GITHUB_SHA'],upstream_commit=base.SHA,
            files={name:hashlib.sha256((folder/name).read_bytes()).hexdigest() for name in ARTIFACTS if name!='evidence-index.json' and (folder/name).exists()}))
    else: return 1
    return 0

if __name__=='__main__':
    try: code=main(sys.argv[1],os.environ)
    except Exception: print('REDIRECT_PROBE_INFRASTRUCTURE_ERROR'); code=1
    raise SystemExit(code)
