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

output = dict(source_commit='3d540dbf3783449e638403b65d81c882c4a99575', synthetic_only=True,
    source_sha256={n: hashlib.sha256((root/'src/dtk/signing/native'/f'{n}.py').read_bytes()).hexdigest() for n in mods}, vectors=vectors)
pathlib.Path(sys.argv[2]).write_text(json.dumps(output, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
