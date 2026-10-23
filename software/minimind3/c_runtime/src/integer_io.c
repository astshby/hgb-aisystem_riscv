#include "integer.h"
#include <string.h>
#ifdef MODEL_EMBED
extern const unsigned char mm3_model_start[],mm3_model_end[],mm3_tokenizer_start[],mm3_tokenizer_end[];
#endif
_Static_assert(sizeof(IScale)==8,"scale layout");
uint32_t read_u32(const unsigned char *p){return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;}
uint64_t read_u64(const unsigned char *p){return read_u32(p)|(uint64_t)read_u32(p+4)<<32;}
uint32_t crc32_bytes(const unsigned char *p,size_t n){uint32_t table[256];for(unsigned i=0;i<256;i++){uint32_t x=i;for(int j=0;j<8;j++)x=(x>>1)^((x&1)?0xedb88320u:0);table[i]=x;}uint32_t c=0xffffffffu;for(size_t i=0;i<n;i++)c=table[(c^p[i])&255]^(c>>8);return c^0xffffffffu;}
void blob_release(Blob *b){platform_free(b->owned);memset(b,0,sizeof(*b));}
int blob_load(Blob *b,const char *path,int tok){memset(b,0,sizeof(*b));
#ifdef MODEL_EMBED
 if(!path){b->data=tok?mm3_tokenizer_start:mm3_model_start;b->size=(size_t)((tok?mm3_tokenizer_end:mm3_model_end)-b->data);return 0;}
#else
 if(!path)path=tok?"assets/tokenizer.bin":"assets/model_w8a16_int.bin";
#endif
 return platform_read(path,b);}
int blob_validate(const Blob *b,const char *magic){uint32_t one=1;if(*(const unsigned char *)&one!=1||b->size<68||memcmp(b->data,magic,8)||read_u32(b->data+8)!=1||read_u64(b->data+16)!=b->size||crc32_bytes(b->data,b->size-4)!=read_u32(b->data+b->size-4)){fprintf(stderr,"Invalid integer/tokenizer binary or checksum\n");return -1;}return 0;}
typedef struct {const char *name;uint64_t off,count,so;unsigned rows,cols,dtype,ns;} Desc;
static int valid_scale(IScale s){return s.m>=(UINT32_C(1)<<30)&&s.m<(UINT32_C(1)<<31)&&s.e>=-256&&s.e<=256;}
static int bind_tensor(ITensor *out,Desc *ds,unsigned count,const unsigned char *p,const char *name,unsigned rows,unsigned cols,unsigned dtype){for(unsigned i=0;i<count;i++)if(!strcmp(ds[i].name,name)){Desc *d=&ds[i];if(d->rows!=rows||d->cols!=cols||d->dtype!=dtype||d->ns!=(dtype==2?rows:1))return -1;*out=(ITensor){dtype==2?(const int8_t *)(p+d->off):NULL,dtype==3?(const int16_t *)(p+d->off):NULL,(const IScale *)(p+d->so),rows,cols};return 0;}return -1;}
int imodel_open(IModel *m,const char *path){memset(m,0,sizeof(*m));if(blob_load(&m->blob,path,0))return -1;const unsigned char *p=m->blob.data;Desc ds[93];uint64_t starts[186],ends[186];unsigned ranges=0;
 if(blob_validate(&m->blob,"MM3INT01")||m->blob.size<128+93*160+4||read_u32(p+12)!=93)goto fail;
 unsigned shape[]={768,2432,8,8,4,96,6400,32768};for(unsigned i=0;i<8;i++)if(read_u32(p+24+i*4)!=shape[i])goto fail;
 m->capacity=read_u32(p+56);if(!m->capacity||m->capacity>32768||read_u32(p+60)!=0)goto fail;memcpy(&m->epsilon,p+104,8);memcpy(&m->invsqrt96,p+112,8);if(!valid_scale(m->epsilon)||!valid_scale(m->invsqrt96))goto fail;
 for(unsigned i=0;i<93;i++){const unsigned char *d=p+128+i*160;if(!memchr(d,0,96))goto fail;Desc *v=&ds[i];*v=(Desc){(const char *)d,read_u64(d+96),read_u64(d+104),read_u64(d+128),read_u32(d+112),read_u32(d+116),read_u32(d+120),read_u32(d+124)};unsigned unit=v->dtype==2?1:v->dtype==3||v->dtype==5?2:v->dtype==4?4:0;if(!unit||!v->rows||!v->cols||v->count!=(uint64_t)v->rows*v->cols||v->off%64||v->off<128+93*160||v->off>m->blob.size-4||v->count>(m->blob.size-4-v->off)/unit)goto fail;for(unsigned j=0;j<i;j++)if(!strcmp(ds[j].name,v->name))goto fail;starts[ranges]=v->off;ends[ranges++]=v->off+v->count*unit;
 if(v->ns){if(v->ns!=(v->dtype==2?v->rows:1)||v->so%64||v->so<128+93*160||v->so>m->blob.size-4||v->ns>(m->blob.size-4-v->so)/8)goto fail;starts[ranges]=v->so;ends[ranges++]=v->so+(uint64_t)v->ns*8;for(unsigned j=0;j<v->ns;j++){IScale s;memcpy(&s,p+v->so+j*8,8);if(!valid_scale(s))goto fail;}}else if(v->so)goto fail;
 if(v->dtype==2){const int8_t *q=(const int8_t *)(p+v->off);for(uint64_t j=0;j<v->count;j++)if(q[j]==-128)goto fail;}if(v->dtype==3){const int16_t *q=(const int16_t *)(p+v->off);for(uint64_t j=0;j<v->count;j++)if(q[j]==INT16_MIN)goto fail;}
 }
 for(unsigned i=0;i<ranges;i++)for(unsigned j=0;j<i;j++)if(starts[i]<ends[j]&&starts[j]<ends[i])goto fail;
 if(bind_tensor(&m->linear[56],ds,93,p,"model.embed_tokens.weight",6400,768,2)||bind_tensor(&m->norm[32],ds,93,p,"model.norm.weight",768,1,3))goto fail;
 const char *ln[]={"self_attn.q_proj","self_attn.k_proj","self_attn.v_proj","self_attn.o_proj","mlp.gate_proj","mlp.up_proj","mlp.down_proj"},*nn[]={"input_layernorm","post_attention_layernorm","self_attn.q_norm","self_attn.k_norm"};unsigned rows[]={768,384,384,768,2432,2432,768};
 for(unsigned l=0;l<8;l++){char name[96];for(unsigned i=0;i<7;i++){snprintf(name,sizeof(name),"model.layers.%u.%s.weight",l,ln[i]);if(bind_tensor(&m->linear[l*7+i],ds,93,p,name,rows[i],i==6?2432:768,2))goto fail;}for(unsigned i=0;i<4;i++){snprintf(name,sizeof(name),"model.layers.%u.%s.weight",l,nn[i]);if(bind_tensor(&m->norm[l*4+i],ds,93,p,name,i<2?768:96,1,3))goto fail;}}
 for(unsigned i=0;i<93;i++){Desc *d=&ds[i];if(!strcmp(d->name,"__exp")){if(d->count!=4097||d->dtype!=4||d->ns)goto fail;m->exp_lut=(const uint32_t *)(p+d->off);}if(!strcmp(d->name,"__sigmoid")){if(d->count!=8193||d->dtype!=5||d->ns)goto fail;m->sig_lut=(const uint16_t *)(p+d->off);}if(!strcmp(d->name,"__rope")){if(d->rows!=m->capacity||d->cols!=96||d->dtype!=3||d->ns)goto fail;m->rope=(const int16_t *)(p+d->off);}}
 if(!m->exp_lut||!m->sig_lut||!m->rope||m->exp_lut[0]!=(UINT32_C(1)<<31))goto fail;
 for(unsigned i=1;i<4097;i++)if(m->exp_lut[i]>m->exp_lut[i-1])goto fail;
 for(unsigned i=1;i<8193;i++)if(m->sig_lut[i]<m->sig_lut[i-1])goto fail;
 return 0;
fail:fprintf(stderr,"Integer model load failed\n");imodel_close(m);return -1;
}
void imodel_close(IModel *m){blob_release(&m->blob);}
