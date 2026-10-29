#!/usr/bin/env python3
"""Compare native graph traces and detections with a preserved full-image reference report."""
import argparse
import hashlib
import json
from pathlib import Path
import struct


def sha(path):
    result=hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda:stream.read(1024*1024),b''):result.update(block)
    return result.hexdigest()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('reference','native','trace','input-meta','output'):
        parser.add_argument('--'+name,type=Path,required=True)
    args=parser.parse_args();reference=json.loads(args.reference.read_text());actual=json.loads(args.native.read_text());meta=json.loads(args.input_meta.read_text())
    if meta['source_sha256']!=reference['image_sha256']:raise ValueError('reference source image differs')
    layers=[]
    with args.trace.open('rb') as stream:
        if stream.read(8)!=b'YTRC1\0\0\0':raise ValueError('trace header')
        for expected in reference['layers']:
            header=stream.read(40)
            if len(header)!=40:raise ValueError('truncated convolution trace')
            number,w,h,cin,cout,kernel,stride,pad,input_count,output_count=struct.unpack('<10I',header)
            quantized=stream.read(input_count);integers=stream.read(output_count*4)
            if len(quantized)!=input_count or len(integers)!=output_count*4:raise ValueError('truncated tensor data')
            if ([cin,h,w]!=expected['input_chw'] or kernel!=expected['kernel'] or
                    stride!=expected['stride'] or pad!=expected['padding'] or number!=len(layers)+1):
                raise ValueError('trace convolution geometry/order differs')
            qhash=hashlib.sha256(quantized).hexdigest();ihash=hashlib.sha256(integers).hexdigest()
            layers.append(dict(layer=number,name=expected['name'],input_matches=qhash==expected['input_int8_sha256'],
                               output_matches=ihash==expected['output_int32_sha256'],input_sha256=qhash,output_sha256=ihash))
        if stream.read(1):raise ValueError('extra convolutions in trace')
    ratio=meta['ratio'];comparisons=[]
    for old,new in zip(reference['detections'],actual['boxes']):
        original=[coordinate/ratio for coordinate in new['box_xyxy']]
        comparisons.append(dict(class_id=new['class_id'],reference_class_id=old['class_id'],same_class=old['class_id']==new['class_id'],
            score=new['score'],reference_score=old['score'],score_abs_difference=abs(old['score']-new['score']),
            xyxy_original=original,reference_xyxy_original=old['xyxy_original'],
            max_coordinate_difference=max(abs(a-b) for a,b in zip(original,old['xyxy_original']))))
    report=dict(reference=str(args.reference),reference_sha256=sha(args.reference),native_sha256=sha(args.native),
                input_metadata_sha256=sha(args.input_meta),trace_sha256=sha(args.trace),layer_count=len(layers),
                input_exact_count=sum(layer['input_matches'] for layer in layers),output_exact_count=sum(layer['output_matches'] for layer in layers),
                first_input_mismatch=next((layer['layer'] for layer in layers if not layer['input_matches']),None),
                detection_count_equal=len(reference['detections'])==len(actual['boxes']),detections=comparisons,layers=layers,
                numerical_note='Differences begin at the reported quantized input. The exact FP32 operation responsible has not been isolated; no byte-equivalence claim follows for later convolutions.',
                scope='Native scalar INT8 graph compared to a preserved external RTL-convolution/CPU-float reference; this run is not an SoC RTL demonstration.')
    args.output.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({key:value for key,value in report.items() if key not in ('layers','detections')},indent=2))


if __name__=='__main__':main()
