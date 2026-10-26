#!/usr/bin/env python3
"""Export small descriptor-only fixtures for matrix/layer microbenchmarks.

No weights or activations are computed here. Full-model mode still uses imodel_open
and its CPU CRC/payload checks; microbenchmarks use host-validated immutable assets.
"""
import hashlib
import json
import pathlib
import struct
import sys
model, manifest, output = map(pathlib.Path, sys.argv[1:])
meta = json.loads(manifest.read_text())
with model.open('rb') as f:
    header = f.read(128)
    f.seek(-4, 2)
    crc = struct.unpack('<I', f.read(4))[0]
if header[:8] != b'MM3INT01' or model.stat().st_size != meta['bytes']:
    raise SystemExit('invalid integer fixture source')
if hashlib.sha256(model.read_bytes()).hexdigest()!=meta['sha256']:
    raise SystemExit('integer asset SHA256 differs from export manifest')
tok=model.with_name('tokenizer.bin')
base=json.loads(model.with_name('manifest.json').read_text())['files']['tokenizer.bin']
if tok.stat().st_size!=base['bytes'] or hashlib.sha256(tok.read_bytes()).hexdigest()!=base['sha256']:
    raise SystemExit('tokenizer SHA256 differs from export manifest')
tensors = {d['name']: d for d in meta['tensors']}
lines = ['/* Generated descriptor fixture; no model arithmetic or payload bypass in full mode. */',
         'static int mm3_fixture_bind(IModel *m){',
         ' const unsigned char *p=(const unsigned char *)(uintptr_t)UINT32_C(0x81000000);',
         f' if(memcmp(p,"MM3INT01",8)||read_u64(p+16)!={meta["bytes"]}u||read_u32(p+{meta["bytes"]-4}u)!=UINT32_C({crc}))return -1;',
         f' m->blob=(Blob){{p,{meta["bytes"]}u,NULL}};m->capacity={meta["capacity"]}u;']
for field, offset in [('epsilon',104),('invsqrt96',112)]:
    m,e=struct.unpack_from('<Ii',header,offset)
    lines.append(f' m->{field}=(IScale){{UINT32_C({m}),{e}}};')
linear=['self_attn.q_proj','self_attn.k_proj','self_attn.v_proj','self_attn.o_proj','mlp.gate_proj','mlp.up_proj','mlp.down_proj']
norm=['input_layernorm','post_attention_layernorm','self_attn.q_norm','self_attn.k_norm']
def bind(field,name):
    d=tensors[name]; rows,cols=d['shape']; off=d['offset']; so=d.get('scale_offset',0)
    if d['dtype']==2:
        expr=f'(const int8_t *)(p+{off}u),NULL,(const IScale *)(p+{so}u),{rows},{cols}'
    elif d['dtype']==3:
        expr=f'NULL,(const int16_t *)(p+{off}u),(const IScale *)(p+{so}u),{rows},{cols}'
    else: raise SystemExit('unexpected fixture dtype')
    lines.append(f' m->{field}=(ITensor){{{expr}}};')
for layer in range(8):
    for i,name in enumerate(linear):bind(f'linear[{layer*7+i}]',f'model.layers.{layer}.{name}.weight')
    for i,name in enumerate(norm):bind(f'norm[{layer*4+i}]',f'model.layers.{layer}.{name}.weight')
bind('linear[56]','model.embed_tokens.weight');bind('norm[32]','model.norm.weight')
for field,name,typ in [('exp_lut','__exp','uint32_t'),('sig_lut','__sigmoid','uint16_t'),('rope','__rope','int16_t')]:
    lines.append(f' m->{field}=(const {typ} *)(p+{tensors[name]["offset"]}u);')
lines += [' return 0;', '}']
output.write_text('\n'.join(lines)+'\n')
