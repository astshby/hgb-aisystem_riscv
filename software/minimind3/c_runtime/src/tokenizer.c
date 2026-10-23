#include "mm3.h"
#include <string.h>
#include <stdlib.h>
#include <limits.h>
/* UTF-8 校验和 Unicode 分类均为纯 C；分类范围在首次导出时生成。 */
static int utf8(const unsigned char *p,size_t n,uint32_t *cp) {
    if(!n) return -1;
    unsigned c=p[0]; int k;
    if(c<128) { *cp=c; return 1; }
    if(c>=0xc2 && c<=0xdf) { k=2; c&=31; }
    else if(c>=0xe0 && c<=0xef) { k=3; c&=15; }
    else if(c>=0xf0 && c<=0xf4) { k=4; c&=7; } else return -1;
    if(n<(size_t)k) return -1;
    for(int i=1;i<k;i++) { if((p[i]&0xc0)!=0x80) return -1; c=(c<<6)|(p[i]&63); }
    if((k==3 && c<0x800)||(k==4 && c<0x10000)||c>0x10ffff||(c>=0xd800 && c<=0xdfff)) return -1;
    *cp=c; return k;
}
static unsigned classify(const Tokenizer *t,uint32_t cp) {
    unsigned a=0,b=t->nranges;
    while(a<b) { unsigned m=a+(b-a)/2; if(cp<t->ranges[m].start) b=m; else if(cp>t->ranges[m].end) a=m+1; else return t->ranges[m].kind; }
    return 0;
}
static int push(TokenIds *v,int id) {
    if(v->count==v->capacity) {
        size_t cap=v->capacity?v->capacity*2:64;
        if(cap>SIZE_MAX/sizeof(int)) return -1;
        int *p=platform_alloc(cap*sizeof(int)); if(!p) return -1;
        if(v->count) memcpy(p,v->ids,v->count*sizeof(int));
        platform_free(v->ids); v->ids=p; v->capacity=cap;
    }
    v->ids[v->count++]=id; return 0;
}
void token_ids_free(TokenIds *v) { platform_free(v->ids); memset(v,0,sizeof(*v)); }
int tokenizer_open(Tokenizer *t,const char *path) {
    memset(t,0,sizeof(*t)); if(blob_load(&t->blob,path,1)) return -1;
    if(blob_validate(&t->blob,"MM3TOK01")) goto fail;
    const unsigned char *p=t->blob.data;
    if(read_u32(p+12)!=MM3_VOCAB) goto fail;
    t->nmerges=read_u32(p+24); t->nranges=read_u32(p+28);
    uint32_t to=read_u32(p+32),mo=read_u32(p+36),ro=read_u32(p+40),data=read_u32(p+44);
    if(t->nmerges!=6108 || !t->nranges || t->nranges>20000 || to!=64 || mo%64 || ro%64 || data%64 || (uint64_t)to+6400*16>mo || (uint64_t)mo+t->nmerges*12>ro || (uint64_t)ro+t->nranges*12>data || data>t->blob.size-4) goto fail;
    t->tokens=platform_alloc(6400*sizeof(Token)); t->merges=platform_alloc(t->nmerges*sizeof(Merge)); t->ranges=platform_alloc(t->nranges*sizeof(UnicodeRange));
    if(!t->tokens||!t->merges||!t->ranges) goto fail;
    for(int b=0;b<256;b++) t->byte_ids[b]=-1;
    for(int i=0;i<6400;i++) {
        const unsigned char *d=p+to+i*16; uint64_t off=read_u64(d); uint32_t len=read_u32(d+8),flags=read_u32(d+12);
        if(!len || off<data || off>t->blob.size-4 || len>t->blob.size-4-off || flags>3) goto fail;
        t->tokens[i]=(Token){p+off,len,flags};
        if(!flags && len==1) t->byte_ids[p[off]]=i;
    }
    for(int b=0;b<256;b++) if(t->byte_ids[b]<0) goto fail;
    for(unsigned i=0;i<t->nmerges;i++) {
        const unsigned char *d=p+mo+i*12;
        t->merges[i]=(Merge){read_u32(d),read_u32(d+4),read_u32(d+8)};
        Merge m=t->merges[i]; if(m.left>=6400||m.right>=6400||m.output>=6400) goto fail;
        Token a=t->tokens[m.left],b=t->tokens[m.right],o=t->tokens[m.output];
        if(o.len!=a.len+b.len || memcmp(o.bytes,a.bytes,a.len)||memcmp(o.bytes+a.len,b.bytes,b.len)) goto fail;
    }
    for(unsigned i=0;i<t->nranges;i++) {
        const unsigned char *d=p+ro+i*12; t->ranges[i]=(UnicodeRange){read_u32(d),read_u32(d+4),read_u32(d+8)};
        UnicodeRange r=t->ranges[i]; if(r.start>r.end||r.end>0x10ffff||!(r.kind==1||r.kind==2||r.kind==4)||(i && t->ranges[i-1].end>=r.start)) goto fail;
    }
    return 0;
fail: fprintf(stderr,"Tokenizer load failed\n"); tokenizer_close(t); return -1;
}
void tokenizer_close(Tokenizer *t) { platform_free(t->tokens); platform_free(t->merges); platform_free(t->ranges); blob_release(&t->blob); memset(t,0,sizeof(*t)); }
static int bpe(const Tokenizer *t,const unsigned char *s,size_t n,TokenIds *out) {
    if(n>SIZE_MAX/sizeof(int)) return -1;
    int *ids=platform_alloc(n*sizeof(int)); if(!ids) return -1;
    for(size_t i=0;i<n;i++) ids[i]=t->byte_ids[s[i]];
    size_t count=n;
    while(count>1) {
        unsigned best=UINT_MAX; size_t at=0;
        for(size_t i=0;i+1<count;i++) for(unsigned j=0;j<t->nmerges;j++) {
            if(j>=best) break;
            if(t->merges[j].left==(unsigned)ids[i] && t->merges[j].right==(unsigned)ids[i+1]) { best=j; at=i; break; }
        }
        if(best==UINT_MAX) break;
        ids[at]=(int)t->merges[best].output;
        memmove(ids+at+1,ids+at+2,(count-at-2)*sizeof(int)); count--;
    }
    int rc=0; for(size_t i=0;i<count;i++) if(push(out,ids[i])) { rc=-1; break; }
    platform_free(ids); return rc;
}
static int pieces(const Tokenizer *t,const unsigned char *s,size_t n,TokenIds *out) {
    size_t pos=0;
    const char *suffix[]={"'s","'t","'re","'ve","'m","'ll","'d"};
    while(pos<n) {
        size_t end=pos;
        for(unsigned i=0;i<7;i++) { size_t k=strlen(suffix[i]); if(k<=n-pos && !memcmp(s+pos,suffix[i],k)) { end=pos+k; break; } }
        if(end==pos) {
            uint32_t cp; int k=utf8(s+pos,n-pos,&cp); if(k<0) return -1;
            size_t start=pos;
            if(cp==' ' && pos+1<n) {
                uint32_t next; int nk=utf8(s+pos+1,n-pos-1,&next); if(nk<0) return -1;
                if(!(classify(t,next)&4)) { start++; cp=next; k=nk; }
            }
            unsigned type=classify(t,cp);
            if(type==4) {
                end=pos;
                size_t last=pos;
                while(end<n) { int nk=utf8(s+end,n-end,&cp); if(nk<0) return -1; if(classify(t,cp)!=4) break; last=end; end+=(size_t)nk; }
                /* \s+(?!\S) 优先；非末尾连续空白需保留最后一个给下一段。 */
                if(end<n && last>pos) end=last;
            } else {
                end=start+(size_t)k;
                while(end<n) { int nk=utf8(s+end,n-end,&cp); if(nk<0) return -1; unsigned ct=classify(t,cp); if(ct!=type) break; end+=(size_t)nk; }
            }
        }
        if(end<=pos || bpe(t,s+pos,end-pos,out)) return -1;
        pos=end;
    }
    return 0;
}
static int added_at(const Tokenizer *t,const unsigned char *s,size_t n) {
    int best=-1; unsigned len=0;
    for(int i=0;i<6400;i++) { Token v=t->tokens[i]; if((v.special&1) && v.len<=n && v.len>len && !memcmp(s,v.bytes,v.len)) { best=i; len=v.len; } }
    return best;
}
int tokenizer_encode(const Tokenizer *t,const char *text,TokenIds *out) {
    memset(out,0,sizeof(*out)); const unsigned char *s=(const unsigned char *)text; size_t n=strlen(text),pos=0,start=0;
    while(pos<n) {
        int id=added_at(t,s+pos,n-pos);
        if(id>=0) { if(pos>start && pieces(t,s+start,pos-start,out)) goto fail; if(push(out,id)) goto fail; pos+=t->tokens[id].len; start=pos; }
        else { uint32_t cp; int k=utf8(s+pos,n-pos,&cp); if(k<0) { fprintf(stderr,"Invalid UTF-8 input\n"); goto fail; } pos+=(size_t)k; }
    }
    if(pos>start && pieces(t,s+start,pos-start,out)) goto fail;
    return 0;
fail: token_ids_free(out); return -1;
}
/* 按字节流解码，跨 Token 保留 UTF-8 前缀；非法序列采用 U+FFFD。 */
static void decoded_write(TextDecoder *d,const unsigned char *p,size_t n) {
    if(d->file) { if(fwrite(p,1,n,d->file)!=n)d->failed=1; }
    else platform_write(p,n);
}
static void replacement(TextDecoder *d) {
    static const unsigned char value[]={0xef,0xbf,0xbd};
    decoded_write(d,value,3);
}
static void decoded_byte(TextDecoder *d,unsigned char c) {
    if(d->have) {
        unsigned char first=d->pending[0];
        int valid=(c&0xc0)==0x80;
        if(d->have==1 && ((first==0xe0&&c<0xa0)||(first==0xed&&c>=0xa0)||(first==0xf0&&c<0x90)||(first==0xf4&&c>=0x90)))valid=0;
        if(!valid) { replacement(d);d->have=d->need=0;decoded_byte(d,c);return; }
        d->pending[d->have++]=c;
        if(d->have==d->need) { decoded_write(d,d->pending,d->have);d->have=d->need=0; }
        return;
    }
    if(c<128) { decoded_write(d,&c,1);return; }
    if(c>=0xc2&&c<=0xdf)d->need=2;
    else if(c>=0xe0&&c<=0xef)d->need=3;
    else if(c>=0xf0&&c<=0xf4)d->need=4;
    else {replacement(d);return;}
    d->pending[0]=c;d->have=1;
}
void tokenizer_emit(TextDecoder *d,const Tokenizer *t,int id) {
    if(id<0||id>=6400){d->failed=1;return;}
    Token v=t->tokens[id];
    if(!(v.special&2))for(unsigned i=0;i<v.len;i++)decoded_byte(d,v.bytes[i]);
}
void tokenizer_flush(TextDecoder *d) { if(d->have)replacement(d);d->have=d->need=0; }
int tokenizer_decode(FILE *f,const Tokenizer *t,const int *ids,size_t count) {
    TextDecoder decoder={0};decoder.file=f;
    for(size_t i=0;i<count;i++)tokenizer_emit(&decoder,t,ids[i]);
    tokenizer_flush(&decoder);return decoder.failed?-1:0;
}
char *chat_prompt(const char *user) {
    const char *prefix="<|im_start|>user\n";
    const char *suffix="<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n";
    size_t n=strlen(user),a=strlen(prefix),b=strlen(suffix);
    if(n>SIZE_MAX-a-b-1) return NULL;
    char *p=platform_alloc(a+n+b+1); if(!p) return NULL;
    memcpy(p,prefix,a); memcpy(p+a,user,n); memcpy(p+a+n,suffix,b+1); return p;
}
