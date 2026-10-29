// Module: yolo_demo_protocol
// Description: CRC32-protected stop-and-wait packets; no detector fallback or synthesized detections.
#include "demo_protocol.h"

static uint32_t u32(const uint8_t *p)
{ return (uint32_t)p[0] | (uint32_t)p[1]<<8 | (uint32_t)p[2]<<16 | (uint32_t)p[3]<<24; }
static void set32(uint8_t *p, uint32_t v)
{ for (unsigned i=0; i<4; ++i) p[i]=(uint8_t)(v>>(8*i)); }
uint32_t ydm_crc_update(uint32_t crc, const uint8_t *data, uint32_t bytes)
{
    while (bytes--) {
        crc ^= *data++;
        for (unsigned bit=0; bit<8; ++bit)
            crc=(crc>>1) ^ (0xedb88320u & (0u-(crc&1u)));
    }
    return crc;
}
static void send(struct ydm_demo *d, uint32_t type, uint32_t sequence,
                 const uint8_t *payload, uint32_t bytes)
{
    uint8_t h[24];
    set32(h,YDM_MAGIC); set32(h+4,YDM_VERSION | (type<<16));
    set32(h+8,sequence); set32(h+12,bytes);
    set32(h+16,ydm_crc_update(~0u,payload,bytes)^~0u);
    set32(h+20,ydm_crc_update(~0u,h,20)^~0u);
    for (unsigned i=0; i<sizeof h; ++i) d->io.put(d->io.context,h[i]);
    for (uint32_t i=0; i<bytes; ++i) d->io.put(d->io.context,payload[i]);
}
static void reply(struct ydm_demo *d, uint32_t type, uint32_t sequence,
                  uint32_t error, uint32_t detail)
{
    uint8_t p[8]; set32(p,error); set32(p+4,detail);
    send(d,0x8000u|type,sequence,p,sizeof p);
}
static void status(struct ydm_demo *d, uint32_t type, uint32_t sequence)
{
    /* 模型完整发布后才允许整图执行；HDMI 仍由独立硬件能力决定。 */
    int model_ready=d->network && d->network->ready(d->network->context);
    uint8_t p[44];
    uint32_t values[]={YDM_OK,YDM_CAP_RGB|YDM_CAP_READ|YDM_CAP_SELFTEST|
        (d->network?YDM_CAP_MODEL:0)|(model_ready?YDM_CAP_DETECT:0)|
        (d->network && d->network->capabilities ? d->network->capabilities(d->network->context) : 0),
        d->valid,d->width,d->height,d->bytes,d->frame_id,YDM_FRAME_ADDRESS,
        d->valid ? d->expected_crc : 0,YDM_CHUNK_BYTES,model_ready?YDM_OK:YDM_NOT_READY};
    for (unsigned i=0; i<11; ++i) set32(p+4*i,values[i]);
    send(d,type,sequence,p,sizeof p);
}
void ydm_init(struct ydm_demo *d, struct ydm_io io)
{
    d->io=io;
    d->width=d->height=d->bytes=d->received=d->expected_crc=0;
    d->running_crc=~0u;
    d->valid=d->receiving=d->frame_id=0;
    d->network=0;
    d->model_receiving=d->model_bytes=d->model_received=d->model_crc=0;
    d->model_running_crc=~0u;
}
void ydm_set_network(struct ydm_demo *d,const struct ydm_network *network)
{ d->network=network; }
void ydm_abort(struct ydm_demo *d)
{
    if (d->receiving) d->valid=0;
    if (d->model_receiving && d->network) d->network->invalidate(d->network->context);
    d->receiving=d->model_receiving=0;
}
void ydm_ready(struct ydm_demo *d) { status(d,YDM_READY,0); }

static void dispatch(struct ydm_demo *d, uint32_t type, uint32_t seq, uint32_t n)
{
    uint8_t *p=d->payload;
    switch (type) {
    case YDM_STATUS:
        if (n) { reply(d,type,seq,YDM_LENGTH,0); break; }
        status(d,0x8000u|type,seq); break;
    case YDM_BEGIN: {
        if (n!=16) { reply(d,type,seq,YDM_LENGTH,16); break; }
        if (d->model_receiving) { reply(d,type,seq,YDM_STATE,0); break; }
        uint32_t w=u32(p), h=u32(p+4), format=u32(p+8);
        if (!w || !h || w>YDM_MAX_WIDTH || h>YDM_MAX_HEIGHT || format!=YDM_RGB888) {
            reply(d,type,seq,YDM_RANGE,0); break;
        }
        /* 新图替换旧图；只有 END 整帧校验和 cache clean 完成后才对消费者可见。 */
        d->valid=0; d->receiving=1; d->width=w; d->height=h;
        d->bytes=w*h*3u; d->received=0; d->expected_crc=u32(p+12); d->running_crc=~0u;
        reply(d,type,seq,YDM_OK,d->bytes); break;
    }
    case YDM_CHUNK: {
        if (n<=4) { reply(d,type,seq,YDM_LENGTH,0); break; }
        uint32_t offset=u32(p), count=n-4;
        if (!d->receiving) { reply(d,type,seq,YDM_STATE,0); break; }
        if (offset!=d->received || count>d->bytes-d->received) {
            reply(d,type,seq,YDM_RANGE,d->received); break;
        }
        for (uint32_t i=0; i<count; ++i) d->io.store(d->io.context,offset+i,p[4+i]);
        d->running_crc=ydm_crc_update(d->running_crc,p+4,count);
        d->received+=count;
        reply(d,type,seq,YDM_OK,d->received); break;
    }
    case YDM_END:
        if (n) { reply(d,type,seq,YDM_LENGTH,0); break; }
        if (!d->receiving || d->received!=d->bytes) { reply(d,type,seq,YDM_STATE,d->received); break; }
        d->receiving=0;
        if ((d->running_crc^~0u)!=d->expected_crc) { reply(d,type,seq,YDM_CRC,0); break; }
        if (d->io.flush(d->io.context)) { reply(d,type,seq,YDM_MEMORY,0); break; }
        d->valid=1; ++d->frame_id;
        reply(d,type,seq,YDM_OK,d->expected_crc); break;
    case YDM_DETECT:
        if (n) { reply(d,type,seq,YDM_LENGTH,0); break; }
        if (!d->valid || d->receiving || d->model_receiving) reply(d,type,seq,YDM_STATE,0);
        else if (!d->network || !d->network->ready(d->network->context)) reply(d,type,seq,YDM_NOT_READY,0);
        else {
            uint32_t bytes=YDM_MAX_PAYLOAD-4u;
            int error=d->network->detect(d->network->context,d->width,d->height,p+4,&bytes);
            if (error || bytes>YDM_MAX_PAYLOAD-4u)
                reply(d,type,seq,error?YDM_OPERATOR:YDM_LENGTH,error?(uint32_t)error:bytes);
            else if (d->io.flush(d->io.context)) reply(d,type,seq,YDM_MEMORY,0);
            else {
                /* 后端可在原帧画框，读回 CRC 随本次已完成帧更新。 */
                uint32_t crc=~0u;
                for (uint32_t i=0;i<d->bytes;++i) {
                    uint8_t byte=d->io.load(d->io.context,i);
                    crc=ydm_crc_update(crc,&byte,1);
                }
                d->expected_crc=crc^~0u;
                set32(p,YDM_OK); send(d,0x8000u|type,seq,p,bytes+4u);
            }
        }
        ydm_ready(d); break;
    case YDM_READ: {
        if (n!=8) { reply(d,type,seq,YDM_LENGTH,8); break; }
        uint32_t offset=u32(p), count=u32(p+4);
        if (!d->valid) { reply(d,type,seq,YDM_STATE,0); break; }
        if (!count || count>YDM_CHUNK_BYTES || offset>d->bytes || count>d->bytes-offset) {
            reply(d,type,seq,YDM_RANGE,0); break;
        }
        set32(p,YDM_OK);
        for (uint32_t i=0; i<count; ++i) p[4+i]=d->io.load(d->io.context,offset+i);
        send(d,0x8000u|type,seq,p,count+4); break;
    }
    case YDM_SELFTEST: {
        if (n) { reply(d,type,seq,YDM_LENGTH,0); break; }
        if (d->receiving || d->model_receiving) { reply(d,type,seq,YDM_STATE,0); break; }
        int result=d->io.selftest(d->io.context);
        reply(d,type,seq,result ? YDM_OPERATOR : YDM_OK,(uint32_t)result);
        ydm_ready(d); break;
    }
    case YDM_CANCEL:
        if (n) { reply(d,type,seq,YDM_LENGTH,0); break; }
        ydm_abort(d); d->valid=0;
        reply(d,type,seq,YDM_OK,0); ydm_ready(d); break;
    case YDM_MODEL_BEGIN: {
        if (n!=8) { reply(d,type,seq,YDM_LENGTH,8); break; }
        if (!d->network) { reply(d,type,seq,YDM_NOT_READY,0); break; }
        if (d->receiving || d->model_receiving) { reply(d,type,seq,YDM_STATE,0); break; }
        uint32_t bytes=u32(p);
        if (!bytes || bytes>YDM_MODEL_BYTES) { reply(d,type,seq,YDM_RANGE,YDM_MODEL_BYTES); break; }
        d->network->invalidate(d->network->context);
        d->model_bytes=bytes; d->model_crc=u32(p+4); d->model_received=0;
        d->model_running_crc=~0u; d->model_receiving=1;
        reply(d,type,seq,YDM_OK,bytes); break;
    }
    case YDM_MODEL_CHUNK: {
        if (n<=4) { reply(d,type,seq,YDM_LENGTH,0); break; }
        if (!d->model_receiving || !d->network) { reply(d,type,seq,YDM_STATE,0); break; }
        uint32_t offset=u32(p),count=n-4;
        if (offset!=d->model_received || count>d->model_bytes-d->model_received) {
            reply(d,type,seq,YDM_RANGE,d->model_received); break;
        }
        for (uint32_t i=0;i<count;++i) d->network->store(d->network->context,offset+i,p[4+i]);
        d->model_running_crc=ydm_crc_update(d->model_running_crc,p+4,count);
        d->model_received+=count;
        reply(d,type,seq,YDM_OK,d->model_received); break;
    }
    case YDM_MODEL_END:
        if (n) { reply(d,type,seq,YDM_LENGTH,0); break; }
        if (!d->model_receiving || !d->network || d->model_received!=d->model_bytes) {
            reply(d,type,seq,YDM_STATE,d->model_received); break;
        }
        d->model_receiving=0;
        if ((d->model_running_crc^~0u)!=d->model_crc) reply(d,type,seq,YDM_CRC,0);
        else if (d->io.flush(d->io.context)) reply(d,type,seq,YDM_MEMORY,0);
        else {
            int error=d->network->publish(d->network->context,d->model_bytes);
            if (error) reply(d,type,seq,YDM_MODEL_ERROR,(uint32_t)error);
            else reply(d,type,seq,YDM_OK,d->model_crc);
        }
        ydm_ready(d); break;
    default: reply(d,type,seq,YDM_UNKNOWN,0); break;
    }
}

int ydm_receive_one(struct ydm_demo *d)
{
    uint8_t h[24], b; uint32_t magic=0;
    /* 在空闲/错误恢复后寻找包头；不用任意地址或长度驱动内存写。 */
    do {
        if (!d->io.get(d->io.context,&b)) return 0;
        magic=(magic>>8)|((uint32_t)b<<24);
    } while (magic!=YDM_MAGIC);
    set32(h,YDM_MAGIC);
    for (unsigned i=4; i<sizeof h; ++i)
        if (!d->io.get(d->io.context,h+i)) return 0;
    uint32_t word=u32(h+4), type=word>>16, seq=u32(h+8), n=u32(h+12);
    if ((word&65535u)!=YDM_VERSION || (ydm_crc_update(~0u,h,20)^~0u)!=u32(h+20)) {
        reply(d,0,0,YDM_HEADER,0); return 0;
    }
    if (n>YDM_MAX_PAYLOAD) { reply(d,type,seq,YDM_LENGTH,YDM_MAX_PAYLOAD); return 0; }
    for (uint32_t i=0; i<n; ++i)
        if (!d->io.get(d->io.context,d->payload+i)) return 0;
    if ((ydm_crc_update(~0u,d->payload,n)^~0u)!=u32(h+16)) {
        reply(d,type,seq,YDM_CRC,0); return 1;
    }
    dispatch(d,type,seq,n);
    return 1;
}
