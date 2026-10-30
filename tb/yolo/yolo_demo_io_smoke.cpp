/* Module: yolo_demo_io_smoke
 * Description: Actual UART packet bytes, DDR bus read/write, DMA copy, one real NPU convolution and full video scanout.
 */
#include "yolo_demo_io.h"
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
static yolo_demo_io *io;
static void require(bool condition,const char *message){if(!condition){std::fprintf(stderr,"FAIL %s\n",message);std::exit(1);}}
static uint32_t read32(uint32_t address){uint32_t value=0;require(!yolo_demo_io_read32(io,address,&value),"read32 bus response");return value;}
static void write32(uint32_t address,uint32_t value){require(!yolo_demo_io_write32(io,address,value),"write32 bus response");}
static uint32_t crc_byte(uint32_t crc,uint8_t byte){crc^=byte;for(unsigned bit=0;bit<8;bit++)crc=(crc>>1)^(0xedb88320u&-(crc&1u));return crc;}
int main(){
    yolo_demo_io_config config{3000000,0x8f731u};io=yolo_demo_io_open(&config);require(io,"open");
    require(read32(0x10040060)==60000000,"real peripheral clock metadata");
    require(read32(0x10040024)==0,"native CPU has no Dcache");
    require(read32(0x1000000c)==20,"real UART divisor");
    write32(0x80000004,0x7cab9182);write32(0x80000018,0x241309af);
    require(read32(0x80000004)==0x7cab9182&&read32(0x80000018)==0x241309af,"DDR scalar byte lanes");
    auto *memory=static_cast<uint8_t *>(yolo_demo_io_ram_ptr(io,0x80000000,64));
    require(memory&&memory[4]==0x82&&memory[7]==0x7c,"shared DDR contents");
    require(!yolo_demo_io_ram_ptr(io,0x88000000,1),"DDR range boundary");
    for(unsigned i=0;i<64;i++)memory[i]=uint8_t(i^0xa7);
    write32(0x10030000,0x80000000);write32(0x10030004,0x80000100);write32(0x10030008,64);write32(0x1003000c,1);
    uint32_t status=0;for(unsigned poll=0;poll<1000;poll++){status=read32(0x10030010);if(status&6u)break;}
    require((status&7u)==2&&read32(0x10030014)==64,"real DMA completion");
    require(!std::memcmp(memory,yolo_demo_io_ram_ptr(io,0x80000100,64),64),"DMA shared DDR bytes");
    std::vector<uint8_t> packet(1024),received;
    for(size_t i=0;i<packet.size();i++)packet[i]=uint8_t(i*37u+0x35);
    require(!yolo_demo_io_queue_rx(io,packet.data(),packet.size()),"queue serial input");
    for(size_t i=0;i<packet.size();i++){
        unsigned poll=0;
        do{status=read32(0x10000008);require(!(status&12u),"UART RX no overrun/framing error");}while(!(status&2u)&&poll++<10000);
        require(status&2u,"UART RX byte timeout");received.push_back(uint8_t(read32(0x10000004)));
    }
    require(received==packet,"1024 true RX bytes");
    for(uint8_t byte:received){for(unsigned poll=0;!(read32(0x10000008)&1u);poll++)require(poll<10000,"UART TX timeout");write32(0x10000000,byte);}
    require(!yolo_demo_io_step(io,1000),"finish TX stop bit");
    std::vector<uint8_t> output(packet.size()+16);size_t count=yolo_demo_io_take_tx(io,output.data(),output.size());
    require(count==packet.size()&&std::equal(packet.begin(),packet.end(),output.begin()),"1024 true TX bytes");
    require(read32(0x20000000)==0x4e505531,"actual NPU identity");
    write32(0x20000008,2);write32(0x20000028,0);write32(0x20000060,3);write32(0x20000064,0);write32(0x20000038,1);
    write32(0x2000002c,0);for(unsigned word=0;word<32;word++)write32(0x20000100+word*4,word?0:2);write32(0x2000003c,1);
    for(unsigned lane=0;lane<16;lane++)write32(0x20000080+lane*4,0);
    write32(0x20000020,0x00010101);write32(0x20000024,1);write32(0x20000008,1);
    for(unsigned poll=0;poll<1000;poll++){status=read32(0x2000000c);if(status&10u)break;}
    require((status&10u)==2&&read32(0x20000200)==6,"real INT8 NPU 3*2");write32(0x20000044,1);
    require((read32(0x2000000c)&15u)==4,"NPU result drained");
    auto *frame=static_cast<uint32_t *>(yolo_demo_io_ram_ptr(io,0x83000000,1920u*1080u*4u));require(frame,"display frame");
    std::fill(frame,frame+1920u*1080u,0x00123456u);
    uint32_t expected=0xffffffffu;for(unsigned pixel=0;pixel<1920u*1080u;pixel++)for(uint8_t byte:{0x12,0x34,0x56})expected=crc_byte(expected,byte);expected^=0xffffffffu;
    require(read32(0x10070000)==0x56494431,"video routed MMIO identity");write32(0x10070008,0x83000000);write32(0x1007001c,1);write32(0x10070018,1);
    yolo_demo_io_stats stats{};
    for(unsigned poll=0;poll<1000;poll++){
        require(!yolo_demo_io_step(io,10000),"continuous shared clocks");yolo_demo_io_get_stats(io,&stats);
        if(stats.frame_pixels==1920u*1080u&&stats.pixel_crc==expected&&stats.active_buffer==0x83000000u)break;
    }
    require(stats.i2c_done&&!stats.i2c_error&&stats.i2c_writes==49,"real MS7210 init");
    require(stats.frame_pixels==1920u*1080u&&stats.pixel_crc==expected&&stats.active_buffer==0x83000000u,"shared DDR -> real full frame CRC");
    require(!stats.underflow&&!stats.video_bus_errors&&!stats.uart_tx_frame_errors&&!stats.axi_error,"no IO faults");
    std::printf("PASS yolo_demo_io UART_RX=1024 UART_TX=1024 baud=%u DDR_RW=2 DMA=64 NPU=3*2:6 pixels=%u crc=%08x frames=%llu sys_cycles=%llu i2c_writes=%u\n",stats.uart_baud,stats.frame_pixels,stats.pixel_crc,(unsigned long long)stats.frames_complete,(unsigned long long)stats.sys_cycles,stats.i2c_writes);
    std::fflush(stdout);yolo_demo_io_close(io);return 0;
}
