"""Run only against the reviewed Apache checkout. No network or session input.
Usage: python generate-signing-vectors.py <apache-checkout> <output-json>
This script imports exactly three local files, not the upstream application.
"""
import hashlib
import importlib.util
import json
import pathlib
import subprocess
import sys
import types

root = pathlib.Path(sys.argv[1]).resolve()
assert subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip() == '3d540dbf3783449e638403b65d81c882c4a99575'
for name in ('dtk', 'dtk.signing', 'dtk.signing.native'):
    sys.modules[name] = types.ModuleType(name)
mods = {}
for short in ('sm3', 'abogus', 'websign'):
    name = 'dtk.signing.native.' + short
    path = root / 'src/dtk/signing/native' / (short + '.py')
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    mods[short] = module

class Noise:
    def __init__(self, seed): self.state = seed
    def random(self):
        self.state = (1664525 * self.state + 1013904223) & 0xffffffff
        return self.state / 4294967296

vectors = []
for i, (query, ua, geometry) in enumerate([
    ('aid=6383&sec_user_id=fixture&max_cursor=0&count=18', 'Chrome/146.0.0.0', mods['abogus'].DEFAULT_BROWSER_INFO),
    ('q=%E4%B8%AD%E6%96%87%20%2B%2F%3D&uifid=synthetic', 'Firefox/128', '1|2|3|4|5|6|7|8|中文😀'),
    ('q=' + 'A' * 400, 'Edg/146 Chrome/146', mods['abogus'].DEFAULT_BROWSER_INFO),
    ('a=~%2A%20%2B&b=', 'Safari/18', mods['abogus'].DEFAULT_BROWSER_INFO),
]):
    now = 1793000000123 + i
    seed = 12345 + i
    value = mods['abogus'].ABogus(ua, browser_info=geometry, rng=Noise(seed)).get_value(query, now_ms=now)
    assert mods['abogus'].structure_error(value) is None
    pairs = [('first', '中文 +/~*'), ('uifid', 'synthetic'), ('a_bogus', value)]
    signed, signature, _ = mods['websign'].sign(pairs, 'synthetic', timestamp=now//1000)
    vectors.append(dict(query=query, user_agent=ua, geometry=geometry, now=now, seed=seed, a_bogus=value, web_pairs=pairs, web_query=signed, web_signature=signature))

# Explicit synthetic request contract, independent of Rust source parsing.
# The empty parameter must remain between uifid and sec_user_id in both signatures.
list_vectors = []
ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36'
for token in ['', 'synthetic=token+/==']:
    pairs = [
        ('device_platform', 'webapp'), ('aid', '6383'), ('channel', 'channel_pc_web'),
        ('update_version_code', '170400'), ('pc_client_type', '1'), ('pc_libra_divert', 'Windows'),
        ('support_h265', '1'), ('support_dash', '1'), ('version_code', '290100'),
        ('version_name', '29.1.0'), ('cookie_enabled', 'true'), ('screen_width', '1920'),
        ('screen_height', '1080'), ('browser_language', 'zh-CN'), ('browser_platform', 'Win32'),
        ('browser_name', 'Chrome'), ('browser_version', '146.0.0.0'), ('browser_online', 'true'),
        ('engine_name', 'Blink'), ('engine_version', '146.0.0.0'), ('os_name', 'Windows'),
        ('os_version', '10'), ('cpu_core_num', '8'), ('device_memory', '8'), ('platform', 'PC'),
        ('downlink', '10'), ('effective_type', '4g'), ('round_trip_time', '200'),
        ('uifid', 'synthetic'), ('msToken', token), ('sec_user_id', 'fixture'),
        ('max_cursor', '1234567890123456789'), ('locate_query', 'false'),
        ('show_live_replay_strategy', '1'), ('need_time_list', '1'), ('time_list_query', '0'),
        ('whale_cut_token', ''), ('cut_version', '1'), ('count', '18'),
        ('publish_video_strategy_type', '2'), ('from_user_page', '1'),
    ]
    now, seed = 1793000000123, 12345
    query = mods['websign'].encode_pairs(pairs)
    bogus = mods['abogus'].ABogus(ua, rng=Noise(seed)).get_value(query, now_ms=now)
    signed, signature, _ = mods['websign'].sign(pairs + [('a_bogus', bogus)], 'synthetic', timestamp=now//1000)
    list_vectors.append(dict(ms_token=token, now=now, seed=seed, user='fixture',
        cursor='1234567890123456789', unsigned_query=query, a_bogus=bogus,
        web_signature=signature, signed_query=signed))

output = dict(source_commit='3d540dbf3783449e638403b65d81c882c4a99575', synthetic_only=True,
    source_sha256={n: hashlib.sha256((root/'src/dtk/signing/native'/f'{n}.py').read_bytes()).hexdigest() for n in mods}, vectors=vectors, list_vectors=list_vectors)
pathlib.Path(sys.argv[2]).write_text(json.dumps(output, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
