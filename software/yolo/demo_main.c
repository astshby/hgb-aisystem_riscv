// Module: yolo_uart_demo
// Description: Persistent bare-metal RGB upload/readback and existing operator-test service.
#include "demo_protocol.h"
#include "../common/soc_clocks.h"
#define REG(a) (*(volatile uint32_t *)(uintptr_t)(a))
#define UART 0x10000000u
#define INFO 0x10040000u
#ifndef YOLO_DEMO_BAUD
#define YOLO_DEMO_BAUD 115200u
#endif
extern int yolo_operator_selftest(void);
static struct ydm_demo demo;
static uint32_t peripheral_hz;

static uint64_t now(void)
{
    uint32_t hi,lo,check;
    do { hi=REG(0x0200bffc); lo=REG(0x0200bff8); check=REG(0x0200bffc); } while (hi!=check);
    return ((uint64_t)hi<<32)|lo;
}
static int get(void *context, uint8_t *byte)
{
    (void)context;
    uint64_t start=now();
    while (now()-start<(uint64_t)peripheral_hz*2u) {
        uint32_t status=REG(UART+8);
        if (status&12u) return 0;
        if (status&2u) { *byte=(uint8_t)REG(UART+4); return 1; }
    }
    return 0;
}
static void put(void *context, uint8_t byte)
{
    (void)context;
    while (!(REG(UART+8)&1u)) { }
    REG(UART)=byte;
}
static void store(void *context, uint32_t offset, uint8_t byte)
{ (void)context; *(volatile uint8_t *)(uintptr_t)(YDM_FRAME_ADDRESS+offset)=byte; }
static uint8_t load(void *context, uint32_t offset)
{ (void)context; return *(volatile uint8_t *)(uintptr_t)(YDM_FRAME_ADDRESS+offset); }
static int flush(void *context)
{
    (void)context;
    __asm__ volatile("fence rw,rw" ::: "memory");
    REG(INFO+0x20)=3; /* clean + invalidate；后续显示/DMA 只能读完成帧。 */
    uint64_t start=now();
    while (REG(INFO+0x30)&1u)
        if (now()-start>(uint64_t)peripheral_hz) return 1;
    return (REG(INFO+0x30)&0x1eu)!=0;
}
static int selftest(void *context)
{
    (void)context;
    return yolo_operator_selftest();
}
static void drain(void)
{
    uint64_t quiet=now();
    while (now()-quiet<peripheral_hz/20u) {
        if (REG(UART+8)&2u) { (void)REG(UART+4); quiet=now(); }
    }
    REG(UART+8)=12;
}
int main(void)
{
    struct hgb_soc_clocks clocks;
    if (hgb_soc_read_clocks(INFO,REG(INFO+0x3c),&clocks)) return 60;
    peripheral_hz=clocks.periph_hz;
    REG(UART+16)=0;
    REG(UART+12)=(peripheral_hz+YOLO_DEMO_BAUD/2u)/YOLO_DEMO_BAUD;
    REG(UART+8)=12;
    /* 只检查预留帧缓冲的两端，上传数据只在完整 CRC 成功后发布。 */
    store(0,0,0x5a); store(0,YDM_FRAME_BYTES-1u,0xa5);
    if (flush(0) || load(0,0)!=0x5a || load(0,YDM_FRAME_BYTES-1u)!=0xa5)
        return 61;
    struct ydm_io io={get,put,store,load,flush,selftest,0};
    ydm_init(&demo,io);
    ydm_ready(&demo);
    for (;;) {
        if (!ydm_receive_one(&demo)) {
            /* 超时/串口错误取消半帧，下一次 BEGIN 可重新上传；不复用不完整图像。 */
            if (demo.receiving) demo.valid=0;
            demo.receiving=0;
            drain();
        }
    }
}
