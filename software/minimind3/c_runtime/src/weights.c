#include "mm3.h"
#include "model_config.h"
#include <string.h>
#include <float.h>
#include <math.h>
_Static_assert(sizeof(float)==4 && FLT_RADIX==2 && FLT_MANT_DIG==24,"IEEE binary32 required");
#ifdef MODEL_EMBED
extern const unsigned char mm3_model_start[],mm3_model_end[],mm3_tokenizer_start[],mm3_tokenizer_end[];
#endif
uint32_t read_u32(const unsigned char *p) { return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24; }
uint64_t read_u64(const unsigned char *p) { return read_u32(p)|(uint64_t)read_u32(p+4)<<32; }
uint32_t crc32_bytes(const unsigned char *p,size_t n) {
    uint32_t table[256];
    for(unsigned i=0;i<256;i++) { uint32_t x=i; for(int j=0;j<8;j++) x=(x>>1)^((x&1)?0xedb88320u:0); table[i]=x; }
    uint32_t c=0xffffffffu;
    for(size_t i=0;i<n;i++) c=table[(c^p[i])&255]^(c>>8);
    return c^0xffffffffu;
}
void blob_release(Blob *b) { platform_free(b->owned); memset(b,0,sizeof(*b)); }
int blob_load(Blob *b,const char *path,int tokenizer) {
    memset(b,0,sizeof(*b));
#ifdef MODEL_EMBED
    if(!path) { b->data=tokenizer?mm3_tokenizer_start:mm3_model_start; b->size=(size_t)((tokenizer?mm3_tokenizer_end:mm3_model_end)-b->data); return 0; }
#else
    if(!path) {
        path=tokenizer?"assets/tokenizer.bin":"assets/model_fp32.bin";
    }
#endif
    return platform_read(path,b);
}
int blob_validate(const Blob *b,const char *magic) {
    uint32_t one=1;
    if(*(unsigned char *)&one!=1) { fprintf(stderr,"Little-endian platform required\n"); return -1; }
    if(b->size<68 || memcmp(b->data,magic,8) || read_u32(b->data+8)!=1u || read_u64(b->data+16)!=b->size) { fprintf(stderr,"Invalid binary header/length\n"); return -1; }
    if(crc32_bytes(b->data,b->size-4)!=read_u32(b->data+b->size-4)) { fprintf(stderr,"Binary checksum mismatch\n"); return -1; }
    return 0;
}
static Tensor *find_tensor(Model *m,const char *name,uint32_t rows,uint32_t cols) {
    for(unsigned i=0;i<m->ntensors;i++)if(!strcmp(m->tensors[i].name,name)) {
        Tensor *t=&m->tensors[i];if(t->rows==rows&&t->cols==cols)return t;break;
    }
    fprintf(stderr,"Missing tensor/shape: %s\n",name);return NULL;
}
static int get_linear(Model *m,int id,const char *name,uint32_t rows,uint32_t cols) {
    Tensor *t=find_tensor(m,name,rows,cols);if(!t)return -1;
    m->linear[id]=(Linear){t->data,rows,cols,t->name};return 0;
}
int model_open(Model *m,const char *path) {
    memset(m,0,sizeof(*m));if(blob_load(&m->blob,path,0))return -1;
    if(blob_validate(&m->blob,"MM3MOD01"))goto fail;
    const unsigned char *p=m->blob.data;unsigned shape[]={768,2432,8,8,4,96,6400,32768};
    for(unsigned i=0;i<8;i++)if(read_u32(p+24+i*4)!=shape[i])goto fail;
    memcpy(&m->eps,p+56,4);memcpy(&m->theta,p+60,4);
    if(m->eps!=1e-6f||m->theta!=1000000.f)goto fail;
    m->ntensors=read_u32(p+12);
    if(m->ntensors!=MM3_EXPORTED_TENSORS||m->ntensors>90||64+(uint64_t)m->ntensors*128>m->blob.size-4)goto fail;
    uint64_t starts[90],ends[90];
    for(unsigned i=0;i<m->ntensors;i++) {
        const unsigned char *d=p+64+i*128;
        uint64_t off=read_u64(d+96),count=read_u64(d+104);
        uint32_t rows=read_u32(d+112),cols=read_u32(d+116);
        if(!memchr(d,0,96)||!rows||!cols||count!=(uint64_t)rows*cols||off%64||off<64+(uint64_t)m->ntensors*128||off>m->blob.size-4||count>(m->blob.size-4-off)/4)goto fail;
        for(unsigned j=0;j<i;j++)if(!strcmp((const char *)d,m->tensors[j].name))goto fail;
        starts[i]=off;ends[i]=off+count*4;
        m->tensors[i]=(Tensor){(const char *)d,(const float *)(p+off),rows,cols};
        for(uint64_t j=0;j<count;j++)if(!isfinite(m->tensors[i].data[j]))goto fail;
    }
    for(unsigned i=0;i<m->ntensors;i++)for(unsigned j=0;j<i;j++)if(starts[i]<ends[j]&&starts[j]<ends[i])goto fail;
    if(get_linear(m,56,"model.embed_tokens.weight",6400,768))goto fail;
    m->embed=m->linear[56].f32;
    Tensor *norm=find_tensor(m,"model.norm.weight",768,1);if(!norm)goto fail;m->norm=norm->data;
    for(int l=0;l<8;l++) {
        char name[96];Tensor *t;
#define NORM(field,suffix,rows) do{snprintf(name,sizeof(name),"model.layers.%d.%s.weight",l,suffix);t=find_tensor(m,name,rows,1);if(!t)goto fail;m->layer[l].field=t->data;}while(0)
        NORM(in_norm,"input_layernorm",768);NORM(ffn_norm,"post_attention_layernorm",768);NORM(q_norm,"self_attn.q_norm",96);NORM(k_norm,"self_attn.k_norm",96);
#undef NORM
#define LIN(index,suffix,rows,cols) do{snprintf(name,sizeof(name),"model.layers.%d.%s.weight",l,suffix);if(get_linear(m,l*7+index,name,rows,cols))goto fail;}while(0)
        LIN(0,"self_attn.q_proj",768,768);LIN(1,"self_attn.k_proj",384,768);LIN(2,"self_attn.v_proj",384,768);LIN(3,"self_attn.o_proj",768,768);
        LIN(4,"mlp.gate_proj",2432,768);LIN(5,"mlp.up_proj",2432,768);LIN(6,"mlp.down_proj",768,2432);
#undef LIN
    }
    return 0;
fail:fprintf(stderr,"Model load failed\n");model_close(m);return -1;
}
void model_close(Model *m){blob_release(&m->blob);}
