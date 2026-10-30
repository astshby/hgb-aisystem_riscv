/* Module: yolo_service_checks
 * Description: Native allocator, image preprocessing and service-lifecycle checks; no RTL or prediction substitute.
 */
#include "network_service.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(condition) do { if (!(condition)) return __LINE__; } while (0)

int check_pool_alignment(void)
{
    unsigned char memory[4096+32]; struct yolo_network_pool pool;
    memset(memory,0xa5,sizeof(memory)); CHECK(!yolo_network_pool_init(&pool,memory+1,4096));
    void *p=yolo_network_pool_allocate(&pool,1); CHECK(p && !((uintptr_t)p&15u));
    CHECK(pool.live>=1 && pool.peak==pool.live); yolo_network_pool_release(&pool,p);
    CHECK(!pool.live && memory[0]==0xa5 && memory[4097]==0xa5);
    return 0;
}
int check_pool_coalesce(void)
{
    unsigned char memory[4096]; struct yolo_network_pool pool;
    CHECK(!yolo_network_pool_init(&pool,memory,sizeof(memory))); size_t initial=yolo_network_pool_free_bytes(&pool);
    void *a=yolo_network_pool_allocate(&pool,1000),*b=yolo_network_pool_allocate(&pool,1000),*c=yolo_network_pool_allocate(&pool,1000);
    CHECK(a && b && c); yolo_network_pool_release(&pool,b);
    CHECK(!yolo_network_pool_allocate(&pool,2000)); yolo_network_pool_release(&pool,c);
    void *d=yolo_network_pool_allocate(&pool,2000); CHECK(d);
    yolo_network_pool_release(&pool,d); yolo_network_pool_release(&pool,a);
    CHECK(!pool.live && yolo_network_pool_free_bytes(&pool)==initial);
    return 0;
}
int check_pool_repeated(void)
{
    unsigned char memory[65536]; struct yolo_network_pool pool;
    CHECK(!yolo_network_pool_init(&pool,memory,sizeof(memory))); size_t initial=yolo_network_pool_free_bytes(&pool);
    for (unsigned iteration=0;iteration<1000;iteration++) {
        unsigned char *slots[32]; size_t lengths[32];
        for (unsigned i=0;i<32;i++) {
            lengths[i]=(iteration*17u+i*31u)%1024u+1u;
            slots[i]=yolo_network_pool_allocate(&pool,lengths[i]); CHECK(slots[i]);
            slots[i][0]=(unsigned char)i; slots[i][lengths[i]-1]=(unsigned char)i;
        }
        for (unsigned i=0;i<32;i++) CHECK(slots[i][0]==i && slots[i][lengths[i]-1]==i);
        for (unsigned i=0;i<32;i+=2) yolo_network_pool_release(&pool,slots[i]);
        for (unsigned i=1;i<32;i+=2) yolo_network_pool_release(&pool,slots[i]);
        CHECK(!pool.live && yolo_network_pool_free_bytes(&pool)==initial);
    }
    return 0;
}
int check_pool_exhaustion(void)
{
    unsigned char memory[256]; struct yolo_network_pool pool;
    CHECK(!yolo_network_pool_init(&pool,memory,sizeof(memory)));
    CHECK(!yolo_network_pool_allocate(&pool,0) && !yolo_network_pool_allocate(&pool,SIZE_MAX));
    size_t free=yolo_network_pool_free_bytes(&pool); void *p=yolo_network_pool_allocate(&pool,free); CHECK(p);
    size_t live=pool.live; CHECK(!yolo_network_pool_allocate(&pool,1) && pool.live==live);
    yolo_network_pool_release(&pool,p); yolo_network_pool_release(&pool,p);
    CHECK(!pool.live && yolo_network_pool_free_bytes(&pool)==free);
    return 0;
}
int check_preprocess_identity(void)
{
    unsigned char source[48],result[48]; float ratio=0;
    for (unsigned i=0;i<sizeof(source);i++) source[i]=(unsigned char)(i*7u);
    CHECK(!yolo_network_service_preprocess(source,4,4,result,4,&ratio));
    CHECK(ratio==1.0f && !memcmp(source,result,sizeof(source)));
    return 0;
}
int check_preprocess_average(void)
{
    unsigned char source[]={0,0,0,10,20,30,20,40,60,30,60,90},result[3]; float ratio;
    CHECK(!yolo_network_service_preprocess(source,2,2,result,1,&ratio));
    CHECK(result[0]==15 && result[1]==30 && result[2]==45 && ratio==0.5f);
    return 0;
}
int check_preprocess_padding(void)
{
    unsigned char source[24],result[48]; float ratio;
    for (unsigned i=0;i<sizeof(source);i++) source[i]=(unsigned char)i;
    CHECK(!yolo_network_service_preprocess(source,4,2,result,4,&ratio));
    CHECK(!memcmp(source,result,sizeof(source)) && ratio==1.0f);
    for (unsigned i=24;i<48;i++) CHECK(result[i]==114);
    return 0;
}
int check_preprocess_single_pixel(void)
{
    unsigned char source[]={7,29,251},result[27]; float ratio;
    CHECK(!yolo_network_service_preprocess(source,1,1,result,3,&ratio));
    for (unsigned i=0;i<27;i++) CHECK(result[i]==source[i%3]);
    return 0;
}
int check_preprocess_bounds(void)
{
    unsigned char source[3]={0},result[3]={1,2,3}; float ratio;
    CHECK(yolo_network_service_preprocess(source,0,1,result,1,&ratio));
    CHECK(yolo_network_service_preprocess(source,1921,1,result,1,&ratio));
    CHECK(yolo_network_service_preprocess(source,1,1081,result,1,&ratio));
    CHECK(result[0]==1 && result[1]==2 && result[2]==3);
    return 0;
}
int check_draw_clipping(void)
{
    unsigned char memory[8*8*3+2]; memset(memory,0,sizeof(memory)); memory[0]=0xa5; memory[sizeof(memory)-1]=0x5a;
    struct yolo_detection box={-100,-100,100,100,0.9f,1,1,2};
    yolo_network_service_draw(memory+1,8,8,&box,1);
    CHECK(memory[0]==0xa5 && memory[sizeof(memory)-1]==0x5a);
    CHECK(memory[1]==64+2*53%192 && memory[1+((4*8+4)*3)]==0);
    box.x1=7; box.x2=1; unsigned char copy[sizeof(memory)]; memcpy(copy,memory,sizeof(memory));
    yolo_network_service_draw(memory+1,8,8,&box,1); CHECK(!memcmp(copy,memory,sizeof(memory)));
    return 0;
}
static uint32_t reads;
static uint32_t absent_npu(void *context,uint32_t offset) { (void)context;(void)offset;reads++;return 0; }
static void unused_write(void *context,uint32_t offset,uint32_t value) { (void)context;(void)offset;(void)value; }
int check_service_cache(void)
{
    unsigned char model[128]={0},frame[48],arena[4096],response[1024]; struct yolo_network_service service;
    struct yolo_npu_io io={absent_npu,unused_write,0};
    CHECK(!yolo_network_service_configure(&service,model,sizeof(model),frame,arena,sizeof(arena),io));
    CHECK(yolo_network_service_try_preloaded(&service)==0);
    const struct ydm_network *endpoint=yolo_network_service_endpoint(&service);
    CHECK(!endpoint->ready(endpoint->context));
    service.model_valid=service.cached=service.annotated=1; service.cached_width=service.cached_height=4; service.cached_bytes=28;
    for (unsigned i=0;i<28;i++) service.result[i]=(unsigned char)i;
    reads=0; uint32_t bytes=sizeof(response);
    CHECK(!endpoint->detect(endpoint->context,4,4,response,&bytes));
    CHECK(bytes==28 && !memcmp(response,service.result,28) && !reads);
    endpoint->invalidate(endpoint->context); CHECK(!service.model_valid && !service.cached);
    service.model_valid=1; bytes=sizeof(response);
    CHECK(endpoint->detect(endpoint->context,4,4,response,&bytes) && !reads);
    yolo_network_service_frame_changed(&service); CHECK(!service.cached && !service.annotated);
    return 0;
}
int check_service_real_model(const char *path)
{
    FILE *file=fopen(path,"rb"); CHECK(file); CHECK(!fseek(file,0,SEEK_END)); long size=ftell(file); rewind(file); CHECK(size>0);
    unsigned char *model=malloc((size_t)size),*arena=malloc(16u*1024u*1024u),*frame=calloc(416u*416u,3);
    CHECK(model && arena && frame); CHECK(fread(model,1,(size_t)size,file)==(size_t)size); fclose(file);
    struct yolo_network_service service; struct yolo_npu_io io={absent_npu,unused_write,0};
    CHECK(!yolo_network_service_configure(&service,model,(size_t)size,frame,arena,16u*1024u*1024u,io));
    const struct ydm_network *endpoint=yolo_network_service_endpoint(&service);
    CHECK(yolo_network_service_try_preloaded(&service)==1 && endpoint->ready(endpoint->context));
    size_t initial=yolo_network_pool_free_bytes(&service.pool); unsigned char response[1024];
    for (unsigned i=0;i<3;i++) {
        uint32_t bytes=sizeof(response); reads=0;
        CHECK(endpoint->detect(endpoint->context,416,416,response,&bytes));
        CHECK(reads && !service.cached && !service.pool.live && yolo_network_pool_free_bytes(&service.pool)==initial);
    }
    endpoint->invalidate(endpoint->context); CHECK(!endpoint->ready(endpoint->context));
    uint8_t first=model[0]; endpoint->store(endpoint->context,0,first^1u);
    CHECK(endpoint->publish(endpoint->context,(uint32_t)size) && !endpoint->ready(endpoint->context));
    CHECK(yolo_network_service_try_preloaded(&service)==0);
    endpoint->store(endpoint->context,0,first);
    uint8_t saved_length[4]; memcpy(saved_length,model+12,4); memset(model+12,255,4);
    CHECK(yolo_network_service_try_preloaded(&service)==-1 && !endpoint->ready(endpoint->context));
    memcpy(model+12,saved_length,4); model[size-1]^=1;
    CHECK(yolo_network_service_try_preloaded(&service)==-1 && !endpoint->ready(endpoint->context));
    model[size-1]^=1; CHECK(yolo_network_service_try_preloaded(&service)==1);
    free(frame);free(arena);free(model);return 0;
}
