#include "mm3.h"
#include <stdlib.h>
#include <string.h>
#include <errno.h>
/* 修改此处即可更换默认提示词；命令行 --prompt 优先。 */
static const char *prompt="hello, how are you?";
#ifdef MM3_INTEGER_RUNTIME
#include "integer_main.inc"
#else
static void usage(const char *p) {
    fprintf(stderr,"Usage: %s [--prompt TEXT] [--max-new-tokens N] [--model BIN] [--tokenizer BIN]\n"
        "  --raw               omit single-turn chat template\n"
        "  --tokenize          print input IDs without loading model\n"
        "  --input-ids FILE    teacher-force whitespace-separated IDs\n"
        "  --trace FILE        dump layer/KV/logit FP32 records for each consumed token\n"
        "  --output-ids FILE   write generated IDs for comparison\n",p);
}
static int number(const char *s,int *n) { char *end; errno=0; long v=strtol(s,&end,10); if(errno||!*s||*end||v<0||v>32768) return -1; *n=(int)v; return 0; }
int main(int argc,char **argv) {
    const char *model_path=NULL,*tok_path=NULL,*ids_path=NULL,*trace_path=NULL,*output_path=NULL;
    int raw=0,tokenize=0,max_new=MAX_NEW_TOKENS,rc=1;
    for(int i=1;i<argc;i++) {
        if(!strcmp(argv[i],"--raw")) raw=1;
        else if(!strcmp(argv[i],"--tokenize")) tokenize=1;
        else if(!strcmp(argv[i],"--help")) { usage(argv[0]); return 0; }
        else {
            if(i+1>=argc) { usage(argv[0]); return 2; }
            const char *opt=argv[i++],*v=argv[i];
            if(!strcmp(opt,"--prompt")) prompt=v;
            else if(!strcmp(opt,"--model")) model_path=v;
            else if(!strcmp(opt,"--tokenizer")) tok_path=v;
            else if(!strcmp(opt,"--input-ids")) ids_path=v;
            else if(!strcmp(opt,"--trace")) trace_path=v;
            else if(!strcmp(opt,"--output-ids")) output_path=v;
            else if(!strcmp(opt,"--max-new-tokens")) { if(number(v,&max_new)) return 2; }
            else { usage(argv[0]); return 2; }
        }
    }
    Model m={0}; Tokenizer t={0}; Runtime r={0}; TokenIds ids={0}; TextDecoder decoder={0};
    char *rendered=NULL; FILE *trace_file=NULL,*idout=NULL;
    if(tokenizer_open(&t,tok_path)) goto done;
    if(ids_path) {
        Blob input={0}; if(platform_read(ids_path,&input)) goto done;
        char *text=platform_alloc(input.size+1); if(!text) { blob_release(&input); goto done; }
        memcpy(text,input.data,input.size);text[input.size]=0;blob_release(&input);
        ids.capacity=MAX_SEQ_LEN; ids.ids=platform_alloc(ids.capacity*sizeof(int));
        if(!ids.ids) { platform_free(text); goto done; }
        char *p=text;
        while(*p) {
            while(*p==' '||*p=='\n'||*p=='\r'||*p=='\t')p++;
            if(!*p)break;
            char *end; errno=0; long v=strtol(p,&end,10);
            if(errno||p==end||v<0||v>=6400||ids.count==ids.capacity||(*end && *end!=' '&&*end!='\n'&&*end!='\r'&&*end!='\t')) { fprintf(stderr,"Invalid token ID or context too long\n");platform_free(text);goto done; }
            ids.ids[ids.count++]=(int)v;p=end;
        }
        platform_free(text);
    } else {
        rendered=raw?NULL:chat_prompt(prompt);
        if(!raw&&!rendered)goto done;
        if(tokenizer_encode(&t,raw?prompt:rendered,&ids))goto done;
    }
    if(tokenize) { for(size_t i=0;i<ids.count;i++)printf("%s%d",i?" ":"",ids.ids[i]);puts("");rc=0;goto done; }
    if(!ids.count||ids.count>MAX_SEQ_LEN||(max_new>0&&ids.count>=MAX_SEQ_LEN)) { fprintf(stderr,"Input empty or context exhausted (input=%zu, capacity=%d)\n",ids.count,MAX_SEQ_LEN);goto done; }
    if(model_open(&m,model_path)||runtime_init(&r,&m,MAX_SEQ_LEN))goto done;
    if(trace_path) {trace_file=fopen(trace_path,"wb");if(!trace_file)goto done;r.trace=trace_file;}
    if(output_path) {idout=fopen(output_path,"w");if(!idout)goto done;}
    double start=platform_seconds();
    for(size_t i=0;i<ids.count;i++)if(runtime_step(&r,ids.ids[i]))goto done;
    double prefill=platform_seconds()-start; int generated=0,consumed=0;
    for(int i=0;i<max_new;i++) {
        int next=argmax(r.logits,6400); generated++;
        if(idout)fprintf(idout,"%d\n",next);
        if(next==2)break;
        tokenizer_emit(&decoder,&t,next);fflush(stdout);
        if(i+1==max_new||ids.count+(size_t)generated==(size_t)r.capacity)break;
        if(runtime_step(&r,next))goto done;
        consumed++;
    }
    tokenizer_flush(&decoder);
    if(max_new)puts("");
    fprintf(stderr,"fp32 CPU: input=%zu generated=%d capacity=%d prefill=%.3fs decode=%.3fs (%d additional steps)\n",ids.count,generated,MAX_SEQ_LEN,prefill,platform_seconds()-start-prefill,consumed);
    rc=(decoder.failed||ferror(stdout))?1:0;
done:
    if(trace_file&&fclose(trace_file))rc=1;
    if(idout&&fclose(idout))rc=1;
    runtime_close(&r);model_close(&m);tokenizer_close(&t);token_ids_free(&ids);platform_free(rendered);
    if(rc)fprintf(stderr,"MiniMind runtime failed\n");
    return rc;
}

#endif
