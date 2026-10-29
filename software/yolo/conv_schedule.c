// Module: yolo_conv_schedule
// Description: Up-to-16 spatial input tiles with explicit halo, 8-channel groups and 16 output lanes.
#include "conv_schedule.h"

static uint32_t smaller(uint32_t a, uint32_t b) { return a < b ? a : b; }
static int valid(const struct yolo_conv *c)
{
    return c && c->input && c->weight && c->output && c->width && c->height &&
        c->width<=416 && c->height<=416 && c->cin && c->cin<=768 &&
        c->cout && c->cout<=768 && (c->kernel==1 || c->kernel==3) &&
        (c->stride==1 || c->stride==2) && c->pad<=c->kernel/2 &&
        c->width+2*c->pad>=c->kernel && c->height+2*c->pad>=c->kernel;
}
static int tile(const struct yolo_conv *c, struct yolo_npu_io io,
                uint32_t ox, uint32_t oy, uint32_t ow, uint32_t oh,
                uint32_t oc, uint32_t lanes, uint32_t output_width, uint32_t output_height)
{
    uint32_t tw=(ow-1)*c->stride+c->kernel, th=(oh-1)*c->stride+c->kernel;
    uint32_t groups=(c->cin+7)/8;
    io.write(io.context,8,2);
    /* 输入块内显式写零填充；NPU pad=0，避免边缘块出现两次 padding。 */
    for (uint32_t y=0; y<th; ++y) for (uint32_t x=0; x<tw; ++x)
        for (uint32_t group=0; group<groups; ++group) {
            uint32_t packed[2]={0,0};
            int32_t sx=(int32_t)(ox*c->stride+x)-(int32_t)c->pad;
            int32_t sy=(int32_t)(oy*c->stride+y)-(int32_t)c->pad;
            for (uint32_t lane=0; lane<8; ++lane) {
                uint32_t ic=group*8+lane; uint8_t value=0;
                if (ic<c->cin && sx>=0 && sy>=0 && sx<(int32_t)c->width && sy<(int32_t)c->height)
                    value=(uint8_t)c->input[(ic*c->height+(uint32_t)sy)*c->width+(uint32_t)sx];
                packed[lane/4]|=(uint32_t)value<<(8*(lane%4));
            }
            io.write(io.context,0x28,(y*tw+x)*groups+group);
            io.write(io.context,0x60,packed[0]); io.write(io.context,0x64,packed[1]);
            io.write(io.context,0x38,1);
        }
    /* 权重地址=(tap*groups+group)，每个地址装16输出x8输入，尾通道补零。 */
    for (uint32_t tap=0; tap<c->kernel*c->kernel; ++tap)
        for (uint32_t group=0; group<groups; ++group) {
            io.write(io.context,0x2c,tap*groups+group);
            for (uint32_t word=0; word<32; ++word) {
                uint32_t packed=0;
                for (uint32_t byte=0; byte<4; ++byte) {
                    uint32_t index=word*4+byte, out=index/8, ic=group*8+index%8;
                    uint8_t value=0;
                    if (out<lanes && ic<c->cin)
                        value=(uint8_t)c->weight[((oc+out)*c->cin+ic)*c->kernel*c->kernel+tap];
                    packed|=(uint32_t)value<<(byte*8);
                }
                io.write(io.context,0x100+word*4,packed);
            }
            io.write(io.context,0x3c,1);
        }
    for (uint32_t lane=0; lane<16; ++lane)
        io.write(io.context,0x80+lane*4,lane<lanes && c->bias ? (uint32_t)c->bias[oc+lane] : 0);
    io.write(io.context,0x20,tw | (th<<8) | (c->cin<<16));
    /* 只取 INT32 原始结果，激活bank0；跨块使用全局 halo，硬件 padding 位为0。 */
    io.write(io.context,0x24,lanes | (c->kernel==3 ? 1u<<5 : 0) | (c->stride==2 ? 1u<<6 : 0));
    io.write(io.context,8,1);
    for (uint32_t y=0; y<oh; ++y) for (uint32_t x=0; x<ow; ++x) {
        uint32_t status=0;
        for (uint32_t poll=0; poll<50000; ++poll) {
            status=io.read(io.context,0x0c);
            if (status&10u) break;
        }
        if (!(status&2u)) return status&8u ? YOLO_CONV_DEVICE : YOLO_CONV_TIMEOUT;
        uint32_t metadata=io.read(io.context,0x58), flags=io.read(io.context,0x5c);
        if (io.read(io.context,0x10) || metadata!=(((1u<<lanes)-1u) | (x<<16) | (y<<24)) ||
            !!(flags&4u)!=(x==ow-1 && y==oh-1)) return YOLO_CONV_RESULT;
        for (uint32_t lane=0; lane<lanes; ++lane)
            c->output[((oc+lane)*output_height+oy+y)*output_width+ox+x]=
                (int32_t)io.read(io.context,0x200+lane*4);
        io.write(io.context,0x44,1);
    }
    if ((io.read(io.context,0x0c)&15u)!=4u || io.read(io.context,0x10) ||
        io.read(io.context,0x1c)!=ow*oh) return YOLO_CONV_RESULT;
    return YOLO_CONV_OK;
}

int yolo_conv_s8(const struct yolo_conv *c, struct yolo_npu_io io)
{
    if (!valid(c) || !io.read || !io.write) return YOLO_CONV_SHAPE;
    if (io.read(io.context,0)!=0x4e505531u || io.read(io.context,4)!=0x10000u ||
        io.read(io.context,0x14)!=24576 || io.read(io.context,0x18)!=864) return YOLO_CONV_DEVICE;
    uint32_t output_width=(c->width+2*c->pad-c->kernel)/c->stride+1;
    uint32_t output_height=(c->height+2*c->pad-c->kernel)/c->stride+1;
    uint32_t side=(16-c->kernel)/c->stride+1;
    for (uint32_t oc=0; oc<c->cout; oc+=16)
        for (uint32_t y=0; y<output_height; y+=side)
            for (uint32_t x=0; x<output_width; x+=side) {
                int error=tile(c,io,x,y,smaller(side,output_width-x),smaller(side,output_height-y),
                               oc,smaller(16,c->cout-oc),output_width,output_height);
                if (error) { io.write(io.context,8,2); return error; }
            }
    return YOLO_CONV_OK;
}
