#!/usr/bin/env python3
"""One-time lossless FP16 -> FP32 export. Normal C builds never invoke Python."""
import argparse
import hashlib
import json
import struct
import zlib
from pathlib import Path
import numpy as np
import regex
from safetensors import safe_open

ROOT = Path(__file__).resolve().parents[1]

def sha(p):
    h=hashlib.sha256()
    with p.open('rb') as f:
        for part in iter(lambda:f.read(1024*1024),b''): h.update(part)
    return h.hexdigest()

def align(blob):
    blob.extend(b'\0'*((-len(blob))%64))

def finish(blob):
    struct.pack_into('<Q',blob,16,len(blob)+4)
    blob.extend(struct.pack('<I',zlib.crc32(blob)))
    return blob

def dump_json(p,obj): p.write_text(json.dumps(obj,ensure_ascii=False,indent=2)+'\n')

def export(source):
    assets=ROOT/'assets'
    assets.mkdir(exist_ok=True)
    source=source.resolve()
    source_hash=json.loads((source.parent/'model_sha256.json').read_text())
    for name,expected in source_hash.items():
        if sha(source/name)!=expected: raise ValueError(f'Source checksum mismatch: {name}')
    cfg=json.loads((source/'config.json').read_text())
    dims=[cfg[k] for k in ['hidden_size','intermediate_size','num_hidden_layers','num_attention_heads','num_key_value_heads','head_dim','vocab_size','max_position_embeddings']]
    assert dims==[768,2432,8,8,4,96,6400,32768]
    assert cfg['tie_word_embeddings'] and cfg['model_type']=='qwen3' and cfg['rope_scaling'] is None
    tensors={}
    with safe_open(str(source/'model.safetensors'),framework='np',device='cpu') as f:
        for name in sorted(f.keys()):
            tensor=f.get_tensor(name)
            assert tensor.dtype==np.dtype('float16'), (name,tensor.dtype)
            a=tensor.astype('<f4')
            if not np.isfinite(a).all(): raise ValueError(f'Nonfinite weight: {name}')
            tensors[name]=a
    assert len(tensors)==90 and 'lm_head.weight' not in tensors
    model=bytearray(struct.pack('<8sIIQ8I2f',b'MM3MOD01',1,len(tensors),0,*dims,cfg['rms_norm_eps'],cfg['rope_theta']))
    model.extend(b'\0'*(128*len(tensors)))
    index=[]
    for i,(name,a) in enumerate(tensors.items()):
        align(model); offset=len(model); model.extend(a.tobytes())
        rows,cols=(a.shape[0],1) if a.ndim==1 else a.shape
        assert len(name.encode())<96
        struct.pack_into('<96sQQIIII',model,64+128*i,name.encode(),offset,a.size,rows,cols,0,0)
        assert np.array_equal(a.reshape(-1),np.frombuffer(model,dtype='<f4',count=a.size,offset=offset))
        index.append(dict(name=name,shape=list(a.shape),offset=offset,count=a.size,dtype='fp32'))
    align(model); finish(model); (assets/'model_fp32.bin').write_bytes(model)
    # Also verify the actual file after writing, one tensor at a time.
    mapped=np.memmap(assets/'model_fp32.bin',mode='r',dtype='u1')
    for entry in index:
        view=np.ndarray((entry['count'],),dtype='<f4',buffer=mapped,offset=entry['offset'])
        assert np.array_equal(view,tensors[entry['name']].reshape(-1))
    del view,mapped,model,tensors
    tok=json.loads((source/'tokenizer.json').read_text())
    assert tok['model']['type']=='BPE' and tok['normalizer'] is None
    assert tok['pre_tokenizer']==dict(type='ByteLevel',add_prefix_space=False,trim_offsets=True,use_regex=True)
    vocab=tok['model']['vocab']; added={x['id']:x for x in tok['added_tokens']}
    bs=list(range(33,127))+list(range(161,173))+list(range(174,256)); cs=bs.copy()
    for b in range(256):
        if b not in bs: bs.append(b); cs.append(256+sum(c>=256 for c in cs))
    inverse={chr(c):b for b,c in zip(bs,cs)}
    tokens=[None]*6400
    for word,i in vocab.items():
        a=added.get(i)
        data=word.encode() if a else bytes(inverse[c] for c in word)
        tokens[i]=(data,(1+2*int(a['special'])) if a else 0)
    assert all(tokens)
    merges=[]
    for pair in tok['model']['merges']:
        left,right=pair if isinstance(pair,list) else pair.split(' ')
        merges.append((vocab[left],vocab[right],vocab[left+right]))
    # UTF-8 ByteLevel's GPT-2 regex needs only L/N/whitespace properties.
    universe=''.join(map(chr,range(0x110000)))
    intervals=[]
    for pattern,kind in [(r'\p{L}+',1),(r'\p{N}+',2),(r'\s+',4)]:
        intervals.extend((m.start(),m.end()-1,kind) for m in regex.finditer(pattern,universe))
    intervals.sort()
    b=bytearray(64+6400*16); align(b); merge_off=len(b)
    for m in merges:b.extend(struct.pack('<III',*m))
    align(b); range_off=len(b)
    for item in intervals:b.extend(struct.pack('<III',*item))
    align(b); data_off=len(b)
    for i,(data,flags) in enumerate(tokens):
        struct.pack_into('<QII',b,64+i*16,len(b),len(data),flags); b.extend(data)
    align(b)
    struct.pack_into('<8sIIQ6I',b,0,b'MM3TOK01',1,6400,0,len(merges),len(intervals),64,merge_off,range_off,data_off)
    finish(b); (assets/'tokenizer.bin').write_bytes(b)
    (assets/'model_config.h').write_text('/* Generated; FP32 payload, no quantization. */\n#ifndef MM3_EXPORTED_CONFIG_H\n#define MM3_EXPORTED_CONFIG_H\n#define MM3_EXPORTED_TENSORS 90\n#define MM3_EXPORTED_MODEL_BYTES '+str((assets/'model_fp32.bin').stat().st_size)+'ULL\n#endif\n')
    lock=json.loads((source.parent/'model_lock.json').read_text())
    manifest=dict(format_version=1,source=lock,config=cfg,storage_dtype='fp32',compute_dtype='fp32',quantization='none',
                  tensor_count=len(index),tensors=index,lm_head_alias='model.embed_tokens.weight',
                  tokenizer=dict(vocab=6400,merges=len(merges),unicode_ranges=len(intervals),regex_version=regex.__version__),
                  files={name:dict(bytes=(assets/name).stat().st_size,sha256=sha(assets/name)) for name in ['model_fp32.bin','tokenizer.bin']},export_check='all tensors equal source FP16 converted to FP32')
    dump_json(assets/'manifest.json',manifest)
    print(f'EXPORT_PASS: {len(index)} tensors; model bytes={manifest["files"]["model_fp32.bin"]["bytes"]}',flush=True)

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__); parser.add_argument('--source',type=Path,default=ROOT.parent/'model')
    export(parser.parse_args().source)
