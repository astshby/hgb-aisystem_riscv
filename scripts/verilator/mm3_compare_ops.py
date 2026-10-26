#!/usr/bin/env python3
"""Compare exact integer outputs/scales/KV, preserving a concise failure report."""
import argparse,hashlib,json,pathlib
p=argparse.ArgumentParser();p.add_argument('fixture',type=pathlib.Path);p.add_argument('actual',type=pathlib.Path);p.add_argument('--label',default='RTL');a=p.parse_args()
m=json.loads((a.fixture/'fixture.json').read_text());expected=(a.fixture/'expected.bin').read_bytes();actual=a.actual.read_bytes()
report={'label':a.label,'case':m['case'],'correctness':'pass' if actual==expected else 'fail','expected_bytes':len(expected),'actual_bytes':len(actual),'config':m['config'],'source_model_sha256':m['source_sha256'],'actual_sha256':hashlib.sha256(actual).hexdigest(),'max_abs_error':0 if actual==expected else None,'rmse':0 if actual==expected else None}
if actual!=expected:
 i=next((i for i,(x,y) in enumerate(zip(expected,actual)) if x!=y),min(len(expected),len(actual)));cursor=0
 for region in m['ranges']:
  if i<cursor+region['bytes']:report['first_difference']={'region':region['name'],'byte_offset':i-cursor,'expected_byte':expected[i] if i<len(expected) else None,'actual_byte':actual[i] if i<len(actual) else None};break
  cursor+=region['bytes']
 report['note']='Mismatch: inspect raw outputs and scales; no approximate PASS is substituted.'
if m.get('trace'):
 traces=[]
 for expected_path in sorted(a.fixture.glob('expected-op-*.bin')):
  actual_path=a.fixture/('c-trace' if a.label=='C' else 'trace')/expected_path.name.removeprefix('expected-')
  same=actual_path.exists() and actual_path.read_bytes()==expected_path.read_bytes()
  traces.append({'command':int(expected_path.stem.rsplit('-',1)[1]),'status':'pass' if same else 'fail','expected':expected_path.name,'actual':str(actual_path)})
 report['command_traces']=traces
 if not traces or any(t['status']!='pass' for t in traces):report['correctness']='fail'
path=a.actual.with_suffix('.report.json');path.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(('PASS' if report['correctness']=='pass' else 'FAIL'),'MM3_COMPARE',a.label,m['case'],path)
raise SystemExit(0 if report['correctness']=='pass' else 1)
