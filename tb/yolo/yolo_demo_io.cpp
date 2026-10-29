/* Module: yolo_demo_io_driver
 * Description: C API for the real I/O RTL, rational independent clocks, UART wire sampling and shared lazy DDR.
 */
#include "Vyolo_demo_io.h"
#include "verilated.h"
#include "svdpi.h"
#include "yolo_demo_io.h"
#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <memory>
#include <new>
#include <stdexcept>

struct yolo_demo_io;
static yolo_demo_io *active_io;
static constexpr uint32_t ram_base=0x80000000u;
static constexpr size_t ram_bytes=128u*1024u*1024u;
struct clock_edge {
    uint64_t next,whole,remainder,denominator,fraction=0;
    clock_edge(uint64_t hz,uint64_t phase):next(phase),whole(1000000000000ull/(2*hz)),
        remainder(1000000000000ull%(2*hz)),denominator(2*hz) { advance(); }
    void advance(){next+=whole;fraction+=remainder;if(fraction>=denominator){next++;fraction-=denominator;}}
};
struct cpu_edge {bool request=false,response=false;uint32_t value=0,error=0;};
struct yolo_demo_io {
    std::unique_ptr<VerilatedContext> context;
    std::unique_ptr<Vyolo_demo_io> top;
    uint8_t *ram=nullptr;
    std::array<clock_edge,5> clocks{{{100000000,0},{125000000,1000},{60000000,1700},
                                  {100000000,3700},{148500000,2300}}};
    std::deque<uint8_t> receive,transmit;
    yolo_demo_io_stats stats{};
    uint32_t divisor=521,random=1;
    int sticky=0;
    bool host_sending=false,device_sending=false,previous_tx=true,previous_vs=false;
    uint8_t host_byte=0,device_byte=0;
    unsigned host_bit=0,device_bit=0,host_ticks=0,device_ticks=0;
    uint32_t crc=0xffffffffu,pixels=0,scan_base=0;
    uint32_t crc_table[256];
    uint64_t tiles=0;
    void (*progress)(void *,uint64_t,uint64_t)=nullptr;
    void *progress_context=nullptr;
    explicit yolo_demo_io(const yolo_demo_io_config &config):context(new VerilatedContext),random(config.random_seed?config.random_seed:1) {
        ram=static_cast<uint8_t *>(std::calloc(ram_bytes,1));
        if(!ram)throw std::bad_alloc();
        active_io=this;
        context->threads(1);
        top.reset(new Vyolo_demo_io(context.get()));
        for(uint32_t value=0;value<256;value++){
            uint32_t c=value;for(unsigned bit=0;bit<8;bit++)c=(c>>1)^(0xedb88320u&-(c&1u));crc_table[value]=c;
        }
        top->clk_sys=0;top->clk_ddr=0;top->clk_periph=0;top->clk_npu=0;top->clk_pixel=0;
        top->reset_async=1;top->cfg_valid=0;top->cfg_rsp_ready=0;top->cfg_write=0;
        top->cfg_addr=0;top->cfg_wdata=0;top->uart_rxd=1;top->eval();
        for(unsigned i=0;i<32;i++)tick();
        top->reset_async=0;
        for(unsigned i=0;i<32;i++)tick();
        if(set_baud(config.uart_baud?config.uart_baud:115200))throw std::runtime_error("UART divisor setup failed");
    }
    ~yolo_demo_io(){if(top)top->final();std::free(ram);if(active_io==this)active_io=nullptr;}
    uint32_t number(){random^=random<<13;random^=random>>17;random^=random<<5;return random;}
    uint8_t *pointer(uint32_t address,size_t bytes){
        if(address<ram_base||uint64_t(address)-ram_base>ram_bytes||bytes>ram_bytes-(uint64_t(address)-ram_base))return nullptr;
        return ram+(address-ram_base);
    }
    void serial_negative_edge(){
        // Host changes its output only at peripheral falling edges; RTL samples at rising edges.
        if(!host_sending&&!receive.empty()){
            host_byte=receive.front();receive.pop_front();host_sending=true;host_bit=0;host_ticks=divisor;
            top->uart_rxd=0;
        }else if(host_sending&&!--host_ticks){
            host_ticks=divisor;host_bit++;
            if(host_bit<=8)top->uart_rxd=(host_byte>>(host_bit-1))&1u;
            else if(host_bit==9)top->uart_rxd=1;
            else {host_sending=false;stats.uart_rx_bytes++;}
        }
        bool tx=top->uart_txd;
        if(!device_sending&&previous_tx&&!tx){
            device_sending=true;device_bit=0;device_byte=0;device_ticks=divisor+divisor/2;
        }else if(device_sending&&!--device_ticks){
            device_ticks=divisor;
            if(device_bit<8){device_byte|=uint8_t(tx)<<device_bit;device_bit++;}
            else {if(tx){transmit.push_back(device_byte);stats.uart_tx_bytes++;}else{stats.uart_tx_frame_errors++;sticky=8;}device_sending=false;}
        }
        previous_tx=tx;
    }
    void pixel_sample(){
        bool vs=top->video_vs;
        if(vs&&!previous_vs&&pixels){
            stats.frames_complete++;stats.pixel_crc=crc^0xffffffffu;stats.frame_pixels=pixels;
            stats.active_buffer=scan_base;crc=0xffffffffu;pixels=0;
        }
        previous_vs=vs;
        if(top->video_de){
            if(!pixels)scan_base=top->video_front;
            uint32_t rgb=top->video_rgb;
            for(int shift=16;shift>=0;shift-=8)crc=crc_table[(crc^(rgb>>shift))&255]^(crc>>8);
            pixels++;
        }
    }
    cpu_edge tick(){
        // C API 只在 SYS tick 之间改配置；各事件上一次 eval 已稳定，不重复求值静止组合网。
        top->eval();
        for(;;){
            uint64_t now=clocks[0].next;
            for(unsigned i=1;i<5;i++)now=std::min(now,clocks[i].next);
            if(top->eventsPending())now=std::min(now,top->nextTimeSlot());
            bool change[5];for(unsigned i=0;i<5;i++)change[i]=clocks[i].next==now;
            bool sys_rising=change[0]&&!top->clk_sys;
            bool pixel_rising=change[4]&&!top->clk_pixel;
            cpu_edge event;
            if(sys_rising){event.request=top->cfg_valid&&top->cfg_ready;event.response=top->cfg_rsp_valid&&top->cfg_rsp_ready;event.value=top->cfg_rdata;event.error=top->cfg_error;}
            context->time(now);
            if(change[0]){top->clk_sys=!top->clk_sys;clocks[0].advance();if(top->clk_sys)stats.sys_cycles++;}
            if(change[1]){top->clk_ddr=!top->clk_ddr;clocks[1].advance();if(top->clk_ddr)stats.ddr_cycles++;}
            if(change[2]){if(top->clk_periph)serial_negative_edge();top->clk_periph=!top->clk_periph;clocks[2].advance();if(top->clk_periph)stats.periph_cycles++;}
            if(change[3]){top->clk_npu=!top->clk_npu;clocks[3].advance();if(top->clk_npu)stats.npu_cycles++;}
            if(change[4]){top->clk_pixel=!top->clk_pixel;clocks[4].advance();if(top->clk_pixel)stats.pixel_cycles++;}
            top->eval();
            if(pixel_rising)pixel_sample();
            if(context->gotFinish()){sticky=9;return event;}
            if(sys_rising)return event;
        }
    }
    int transaction(bool write,uint32_t address,uint32_t value,uint32_t *result){
        if(sticky)return sticky;
        if(address&3u)return 7;
        top->cfg_valid=1;top->cfg_write=write;top->cfg_addr=address;top->cfg_wdata=value;top->cfg_rsp_ready=0;
        uint64_t start=stats.sys_cycles;
        unsigned hold=number()%4;
        for(unsigned cycle=0;cycle<200000;cycle++){
            if(top->cfg_rsp_valid){if(!hold)top->cfg_rsp_ready=1;else hold--;}
            cpu_edge event=tick();
            if(event.request)top->cfg_valid=0;
            if(event.response){
                top->cfg_rsp_ready=0;
                if(write)stats.writes++;else stats.reads++;
                stats.maximum_transaction_cycles=std::max(stats.maximum_transaction_cycles,stats.sys_cycles-start);
                if(event.error){stats.axi_error++;sticky=16+event.error;}
                if(result)*result=event.value;
                if(!event.error&&write&&address==0x20000008u&&value==2u){tiles++;if(progress)progress(progress_context,tiles,stats.sys_cycles);}
                return int(event.error);
            }
        }
        sticky=4;return sticky;
    }
    int set_baud(uint32_t baud){
        if(!baud||baud>15000000u||host_sending||!receive.empty()||device_sending)return 7;
        uint32_t next=uint32_t((60000000ull+baud/2)/baud);
        next=std::max(4u,next);
        int error=transaction(true,0x1000000cu,next,nullptr);
        if(!error){divisor=next;stats.uart_divisor=next;stats.uart_baud=60000000u/next;}
        return error;
    }
};
extern "C" void yolo_demo_ddr_read(unsigned int address,svBitVecVal *value){
    uint8_t *pointer=active_io?active_io->pointer(address,32):nullptr;
    if(!pointer){if(active_io)active_io->sticky=10;std::memset(value,0,32);return;}
    std::memcpy(value,pointer,32);
}
extern "C" void yolo_demo_ddr_write(unsigned int address,const svBitVecVal *value,unsigned int mask){
    uint8_t *pointer=active_io?active_io->pointer(address,32):nullptr;
    if(!pointer){if(active_io)active_io->sticky=10;return;}
    if(mask==0xffffffffu)std::memcpy(pointer,value,32);
    else for(unsigned lane=0;lane<32;lane++)if((mask>>lane)&1u)pointer[lane]=uint8_t(value[lane/4]>>(8*(lane%4)));
}
extern "C" yolo_demo_io *yolo_demo_io_open(const yolo_demo_io_config *config){
    if(active_io)return nullptr;
    yolo_demo_io_config defaults{115200,1};
    try{return new yolo_demo_io(config?*config:defaults);}catch(...){active_io=nullptr;return nullptr;}
}
extern "C" void yolo_demo_io_close(yolo_demo_io *io){delete io;}
extern "C" int yolo_demo_io_read32(yolo_demo_io *io,uint32_t address,uint32_t *value){return io?io->transaction(false,address,0,value):7;}
extern "C" int yolo_demo_io_write32(yolo_demo_io *io,uint32_t address,uint32_t value){return io?io->transaction(true,address,value,nullptr):7;}
extern "C" void *yolo_demo_io_ram_ptr(yolo_demo_io *io,uint32_t address,size_t bytes){return io?io->pointer(address,bytes):nullptr;}
extern "C" int yolo_demo_io_queue_rx(yolo_demo_io *io,const uint8_t *data,size_t bytes){
    if(!io||(!data&&bytes)||bytes>16u*1024u*1024u)return 7;
    try{io->receive.insert(io->receive.end(),data,data+bytes);}catch(...){return 6;}return 0;
}
extern "C" size_t yolo_demo_io_take_tx(yolo_demo_io *io,uint8_t *data,size_t capacity){
    if(!io||!data)return 0;
    size_t count=std::min(capacity,io->transmit.size());
    for(size_t i=0;i<count;i++){data[i]=io->transmit.front();io->transmit.pop_front();}return count;
}
extern "C" int yolo_demo_io_step(yolo_demo_io *io,uint64_t cycles){if(!io)return 7;for(uint64_t i=0;i<cycles&&!io->sticky;i++)io->tick();return io->sticky;}
extern "C" int yolo_demo_io_error(yolo_demo_io *io){return io?io->sticky:7;}
extern "C" int yolo_demo_io_set_baud(yolo_demo_io *io,uint32_t baud){return io?io->set_baud(baud):7;}
extern "C" void yolo_demo_io_progress(yolo_demo_io *io,void (*callback)(void *,uint64_t,uint64_t),void *context){if(io){io->progress=callback;io->progress_context=context;}}
extern "C" void yolo_demo_io_get_stats(yolo_demo_io *io,yolo_demo_io_stats *out){
    if(!io||!out)return;
    *out=io->stats;out->uart_rx_queued=io->receive.size()+unsigned(io->host_sending);
    out->frame_sequence=io->top->video_frame_sequence;out->underflow=io->top->video_underflow;
    out->video_bus_errors=io->top->video_bus_errors;out->i2c_done=io->top->i2c_done;
    out->i2c_error=io->top->i2c_error;out->i2c_writes=io->top->i2c_writes;
    out->ddr_ar=io->top->ddr_ar;out->ddr_aw=io->top->ddr_aw;out->ddr_r=io->top->ddr_r;
    out->ddr_w=io->top->ddr_w;out->ddr_b=io->top->ddr_b;
}
