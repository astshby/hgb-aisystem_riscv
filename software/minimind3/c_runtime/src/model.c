#include "mm3.h"
#include <string.h>
#include <math.h>
static int trace(FILE *f,const float *p,size_t n) { return f && fwrite(p,sizeof(float),n,f)!=n?-1:0; }
int runtime_init(Runtime *r,const Model *m,int capacity) {
    memset(r,0,sizeof(*r)); r->model=m; r->backend=&mm3_cpu_backend; r->capacity=capacity;
    if(capacity<1||capacity>32768) return -1;
    size_t size=(size_t)8*capacity*384*sizeof(float);
    r->keys=platform_alloc(size); r->values=platform_alloc(size); r->scores=platform_alloc((size_t)capacity*sizeof(float));
    if(!r->keys||!r->values||!r->scores) { fprintf(stderr,"KV/scratch allocation failed\n"); runtime_close(r); return -1; }
    return 0;
}
void runtime_close(Runtime *r) { platform_free(r->keys); platform_free(r->values); platform_free(r->scores); r->keys=r->values=r->scores=NULL; }
static int project(Runtime *r,int projection,float *out,const float *x) {
    const Linear *w=&r->model->linear[projection];
    r->backend->gemv(out,w->f32,x,(int)w->rows,(int)w->cols);
    for(unsigned i=0;i<w->rows;i++)if(!isfinite(out[i]))return -1;
    return 0;
}
int runtime_step(Runtime *r,int token) {
    if(token<0||token>=6400) { fprintf(stderr,"Invalid token ID: %d\n",token); return -1; }
    if(r->pos>=r->capacity) { fprintf(stderr,"Context exhausted\n"); return -1; }
    const Model *m=r->model; const Backend *b=r->backend;
    memcpy(r->x,m->embed+(size_t)token*768,768*sizeof(float));
    
    for(int l=0;l<8;l++) {
        b->norm(r->normed,r->x,m->layer[l].in_norm,768,m->eps);
        
        if(project(r,l*7,r->q,r->normed)||project(r,l*7+1,r->k,r->normed)||project(r,l*7+2,r->v,r->normed))return -1;
        for(int h=0;h<8;h++) b->norm(r->q+h*96,r->q+h*96,m->layer[l].q_norm,96,m->eps);
        for(int h=0;h<4;h++) b->norm(r->k+h*96,r->k+h*96,m->layer[l].k_norm,96,m->eps);
        
        b->rope(r->q,8,r->pos,m->theta); b->rope(r->k,4,r->pos,m->theta);
        
        size_t offset=((size_t)l*r->capacity+r->pos)*384;
        memcpy(r->keys+offset,r->k,384*sizeof(float)); memcpy(r->values+offset,r->v,384*sizeof(float));
        for(int h=0;h<8;h++) {
            int kh=h/2;
            for(int t=0;t<=r->pos;t++) {
                const float *key=r->keys+((size_t)l*r->capacity+t)*384+kh*96;
                float sum=0; for(int d=0;d<96;d++) sum+=r->q[h*96+d]*key[d];
                r->scores[t]=sum*(1.f/sqrtf(96.f));
            }
            b->softmax(r->scores,r->pos+1);
            float *out=r->attention+h*96; memset(out,0,96*sizeof(float));
            for(int t=0;t<=r->pos;t++) {
                const float *v=r->values+((size_t)l*r->capacity+t)*384+kh*96;
                for(int d=0;d<96;d++) out[d]+=r->scores[t]*v[d];
            }
        }
        
        if(project(r,l*7+3,r->temp,r->attention))return -1;
        for(int i=0;i<768;i++) r->x[i]+=r->temp[i];
        
        b->norm(r->normed,r->x,m->layer[l].ffn_norm,768,m->eps);
        
        if(project(r,l*7+4,r->gate,r->normed)||project(r,l*7+5,r->up,r->normed))return -1;
        b->swiglu(r->gate,r->up,2432);
        
        if(project(r,l*7+6,r->temp,r->gate))return -1;
        for(int i=0;i<768;i++) r->x[i]+=r->temp[i];
        
        if(trace(r->trace,r->x,768)||trace(r->trace,r->k,384)||trace(r->trace,r->v,384)) return -1;
    }
    b->norm(r->normed,r->x,m->norm,768,m->eps);
    
    if(project(r,56,r->logits,r->normed))return -1;
    for(int i=0;i<6400;i++) if(!isfinite(r->logits[i])) { fprintf(stderr,"Non-finite logits\n"); return -1; }
    if(trace(r->trace,r->logits,6400)) return -1;
    r->pos++; return 0;
}
