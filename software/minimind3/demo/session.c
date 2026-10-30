/* Module: mm3_demo_session
 * Description: Load once, reset KV per request, execute all eight layers and return to READY.
 */
#include "demo.h"
#include <string.h>
static void reset_runtime(IRuntime *runtime) {
    size_t vectors=(size_t)8*runtime->capacity*384;
    size_t scales=(size_t)8*runtime->capacity*4;
    runtime->pos=0;runtime->trace=NULL;memset(&runtime->stats,0,sizeof(runtime->stats));
    memset(runtime->keys,0,vectors*sizeof(*runtime->keys));
    memset(runtime->values,0,vectors*sizeof(*runtime->values));
    memset(runtime->ks,0,scales*sizeof(*runtime->ks));
    memset(runtime->vs,0,scales*sizeof(*runtime->vs));
}
static uint32_t kv_hash(const IRuntime *runtime) {
    const void *blocks[]={runtime->keys,runtime->values,runtime->ks,runtime->vs};
    size_t sizes[]={(size_t)8*runtime->capacity*384*2,(size_t)8*runtime->capacity*384*2,
                   (size_t)8*runtime->capacity*4*sizeof(IScale),(size_t)8*runtime->capacity*4*sizeof(IScale)};
    uint32_t hash=2166136261u;
    for(unsigned block=0;block<4;block++) {
        const unsigned char *bytes=blocks[block];
        for(size_t i=0;i<sizes[block];i++)hash=(hash^bytes[i])*16777619u;
    }
    return hash;
}
static void done(const char *status,size_t inputs,unsigned generated,unsigned pos,uint32_t hash) {
    mm3_demo_puts("DONE status=");mm3_demo_puts(status);
    mm3_demo_puts(" input_tokens=");mm3_demo_u64(inputs);
    mm3_demo_puts(" generated=");mm3_demo_u64(generated);
    mm3_demo_puts(" position=");mm3_demo_u64(pos);
    mm3_demo_puts(" kv_hash=");mm3_demo_u64(hash);
    mm3_demo_puts(" live_bytes=");mm3_demo_u64(mm3_demo_live_bytes());mm3_demo_puts("\n");
}
int mm3_demo_session(const char *model_path,const char *tokenizer_path,unsigned maximum,int raw,int accelerated) {
    IModel model={0};Tokenizer tokenizer={0};
    IRuntime *runtime=platform_alloc(sizeof(*runtime));
    if(!runtime)return 1;
    memset(runtime,0,sizeof(*runtime));
    if(!maximum||maximum>MAX_SEQ_LEN||tokenizer_open(&tokenizer,tokenizer_path)||
       imodel_open(&model,model_path)||iruntime_init(runtime,&model,MAX_SEQ_LEN)||
       mm3_demo_backend(runtime,accelerated)) {
        mm3_demo_puts("BOOT_ERROR reason=assets_or_runtime\n");
        iruntime_close(runtime);imodel_close(&model);tokenizer_close(&tokenizer);platform_free(runtime);return 2;
    }
    int swallow_lf=0;
    for(;;) {
        mm3_demo_puts("READY app=minimind version=1 layers=8 assets_loaded=1 backend=");
        mm3_demo_puts(accelerated?"accelerator":"cpu");
        mm3_demo_puts(" context=");mm3_demo_u64(runtime->capacity);
        mm3_demo_puts(" max_new_tokens=");mm3_demo_u64(maximum);
        mm3_demo_puts(" prompt_bytes=");mm3_demo_u64(MM3_DEMO_PROMPT_BYTES);
        mm3_demo_puts(" live_bytes=");mm3_demo_u64(mm3_demo_live_bytes());mm3_demo_puts("\n");
        char input[MM3_DEMO_PROMPT_BYTES+1];size_t used=0;int overflow=0,invalid=0,byte;
        for(;;) {
            byte=mm3_demo_getbyte();
            if(byte==-1)goto close;
            if(byte<0){invalid=1;continue;}
            if(swallow_lf&&byte=='\n'){swallow_lf=0;continue;}
            swallow_lf=0;
            if(byte=='\r'||byte=='\n'){swallow_lf=byte=='\r';break;}
            if(byte==0)invalid=1;
            if(used<MM3_DEMO_PROMPT_BYTES)input[used++]=(char)byte;else overflow=1;
        }
        input[used]=0;
        if(invalid||overflow||!used){done(invalid?"uart_error":overflow?"too_long":"empty",0,0,0,0);continue;}
        mm3_demo_request_begin();
        char *rendered=raw?NULL:chat_prompt(input);TokenIds ids={0};
        const char *status="ok";unsigned generated=0;
        reset_runtime(runtime);
        if((!raw&&!rendered)||tokenizer_encode(&tokenizer,raw?input:rendered,&ids))status="tokenize_error";
        else if(!ids.count||ids.count>=runtime->capacity)status="context_exhausted";
        else {
            mm3_demo_puts("BEGIN input_tokens=");mm3_demo_u64(ids.count);mm3_demo_puts("\n");
            for(size_t i=0;i<ids.count;i++)if(iruntime_step(runtime,ids.ids[i])){status="inference_error";break;}
            if(status[0]=='o') {
                TextDecoder decoder={0};
                for(unsigned i=0;i<maximum;i++) {
                    int next=iargmax(runtime->logits,6400);generated++;
                    int stop=next==2||i+1==maximum||ids.count+generated>=runtime->capacity;
                    mm3_demo_capture(next);
                    if(next!=2)tokenizer_emit(&decoder,&tokenizer,next);
                    if(stop)tokenizer_flush(&decoder);
                    if(mm3_demo_emit()||decoder.failed){status="decode_error";break;}
                    if(stop)break;
                    if(iruntime_step(runtime,next)){status="inference_error";break;}
                }
            }
        }
        size_t inputs=ids.count;unsigned position=runtime->pos;uint32_t hash=kv_hash(runtime);
        token_ids_free(&ids);platform_free(rendered);mm3_demo_request_end();
        done(status,inputs,generated,position,hash);
    }
close:
    iruntime_close(runtime);imodel_close(&model);tokenizer_close(&tokenizer);platform_free(runtime);return 0;
}
