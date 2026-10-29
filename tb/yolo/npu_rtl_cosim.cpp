/* Module: yolo_npu_rtl_driver
 * Description: C-callable bus master driving real AXI/CDC responses, backpressure and independent clocks.
 */
#include "Vnpu_csr_cosim.h"
#include "verilated.h"
extern "C" {
#include "npu_rtl_cosim.h"
}
#include <algorithm>
#include <cstdint>
#include <memory>
#include <new>
struct edge {bool request,response;uint32_t data,error;};
struct simulator {
    std::unique_ptr<VerilatedContext> context;
    std::unique_ptr<Vnpu_csr_cosim> top;
    uint64_t sys_half,npu_half,next_sys,next_npu;
    uint32_t random;
    int sticky=0;
    uint64_t tiles=0;
    void (*progress)(void *,uint64_t,uint64_t)=nullptr;
    void *progress_context=nullptr;
    yolo_npu_rtl_stats stats{};
    simulator(uint64_t sys,uint64_t npu,uint64_t phase,uint32_t seed):
        context(new VerilatedContext),sys_half(sys/2),npu_half(npu/2),next_sys(sys/2),next_npu(phase+npu/2),random(seed?seed:1) {
        context->threads(1);top.reset(new Vnpu_csr_cosim(context.get()));
        top->clk_sys=0;top->clk_npu=0;top->rst_sys=1;top->rst_npu=1;
        top->cfg_valid=0;top->cfg_rsp_ready=0;top->cfg_write=0;top->cfg_addr=0;
        top->cfg_wdata=0;top->cfg_wstrb=15;top->cfg_size=2;allow();top->eval();reset();
    }
    void allow(){top->allow_aw=1;top->allow_w=1;top->allow_ar=1;top->allow_b=1;top->allow_r=1;}
    uint32_t number(){random^=random<<13;random^=random>>17;random^=random<<5;return random;}
    edge tick() {
        for(;;) {
            uint64_t now=std::min(next_sys,next_npu);bool sys=next_sys==now,npu=next_npu==now;
            bool rising=sys&&!top->clk_sys;edge event{};
            top->eval();
            if(rising){event.request=top->cfg_valid&&top->cfg_ready;event.response=top->cfg_rsp_valid&&top->cfg_rsp_ready;event.data=top->cfg_rdata;event.error=top->cfg_error;}
            context->time(now);
            if(sys){top->clk_sys=!top->clk_sys;next_sys+=sys_half;if(rising)stats.sys_cycles++;}
            if(npu){top->clk_npu=!top->clk_npu;next_npu+=npu_half;if(top->clk_npu)stats.npu_cycles++;}
            top->eval();
            if(rising)return event;
        }
    }
    void reset() {
        top->cfg_valid=0;top->cfg_rsp_ready=0;allow();top->rst_sys=1;top->rst_npu=1;
        for(unsigned i=0;i<16;i++)tick();
        top->rst_sys=0;top->rst_npu=0;
        for(unsigned i=0;i<16;i++)tick();
        sticky=0;
    }
    int transaction(bool write,uint32_t address,uint32_t data,uint32_t strobes,uint32_t size,uint32_t hold,uint32_t *result) {
        if(sticky)return sticky;
        uint32_t aw_delay=number()%4,w_delay=number()%5,ar_delay=number()%3,response_delay=number()%5;
        top->allow_aw=0;top->allow_w=0;top->allow_ar=0;top->allow_b=0;top->allow_r=0;
        top->cfg_valid=1;top->cfg_write=write;top->cfg_addr=address;top->cfg_wdata=data;top->cfg_wstrb=strobes;top->cfg_size=size;
        top->cfg_rsp_ready=0;
        uint64_t start=stats.sys_cycles;unsigned bus_held=0,local_held=0;bool response_seen=false;uint32_t saved_data=0,saved_error=0;
        for(unsigned cycle=0;cycle<200000;cycle++) {
            if(cycle>=aw_delay)top->allow_aw=1;
            if(cycle>=w_delay)top->allow_w=1;
            if(cycle>=ar_delay)top->allow_ar=1;
            if((write?top->pending_b:top->pending_r)&&!(write?top->allow_b:top->allow_r)) {
                stats.response_stalls++;if(bus_held++>=response_delay){top->allow_b=1;top->allow_r=1;}
            }
            if(top->cfg_rsp_valid) {
                if(!response_seen){saved_data=top->cfg_rdata;saved_error=top->cfg_error;response_seen=true;}
                else if(saved_data!=top->cfg_rdata||saved_error!=top->cfg_error){sticky=5;return sticky;}
                if(local_held++>=hold)top->cfg_rsp_ready=1;else stats.response_stalls++;
            }
            edge event=tick();
            if(event.request)top->cfg_valid=0;
            if(event.response) {
                top->cfg_rsp_ready=0;
                if(write)stats.writes++;else stats.reads++;
                stats.maximum_transaction_cycles=std::max(stats.maximum_transaction_cycles,stats.sys_cycles-start);
                if(event.error){stats.error_responses++;sticky=(int)event.error;}
                if(!event.error&&write&&address==0x20000008u&&data==2u) {
                    tiles++;if(progress)progress(progress_context,tiles,stats.sys_cycles);
                }
                if(result)*result=event.data;
                return (int)event.error;
            }
        }
        sticky=4;return sticky;
    }
};
extern "C" void *yolo_npu_rtl_create(uint64_t sys,uint64_t npu,uint64_t phase,uint32_t seed) {
    if(sys<4||npu<4||sys%2||npu%2||phase>100000)return nullptr;
    try{return new simulator(sys,npu,phase,seed);}catch(const std::bad_alloc&){return nullptr;}
}
extern "C" void yolo_npu_rtl_destroy(void *handle){auto *s=(simulator*)handle;if(s){s->top->final();delete s;}}
extern "C" int yolo_npu_rtl_reset(void *handle){auto *s=(simulator*)handle;s->reset();return 0;}
extern "C" void yolo_npu_rtl_advance(void *handle,uint32_t cycles){auto *s=(simulator*)handle;for(uint32_t i=0;i<cycles;i++)s->tick();}
extern "C" int yolo_npu_rtl_transaction(void *handle,int write,uint32_t address,uint32_t data,uint32_t strobes,uint32_t size,uint32_t hold,uint32_t *result) {
    return ((simulator*)handle)->transaction(write!=0,address,data,strobes,size,hold,result);
}
extern "C" int yolo_npu_rtl_error(void *handle){return ((simulator*)handle)->sticky;}
extern "C" void yolo_npu_rtl_clear_error(void *handle){((simulator*)handle)->sticky=0;}
extern "C" void yolo_npu_rtl_progress(void *handle,void (*callback)(void *,uint64_t,uint64_t),void *context) {
    auto *s=(simulator*)handle;s->progress=callback;s->progress_context=context;
}
extern "C" void yolo_npu_rtl_get_stats(void *handle,struct yolo_npu_rtl_stats *out) {
    auto *s=(simulator*)handle;*out=s->stats;out->aw_count=s->top->aw_count;out->w_count=s->top->w_count;
    out->b_count=s->top->b_count;out->ar_count=s->top->ar_count;out->r_count=s->top->r_count;
}
extern "C" uint32_t yolo_npu_rtl_nread(void *handle,uint32_t offset) {
    auto *s=(simulator*)handle;if(s->sticky)return offset==0x0c?8u:0u;uint32_t result=0;
    s->transaction(false,0x20000000u+offset,0,15,2,s->number()%3,&result);return result;
}
extern "C" void yolo_npu_rtl_nwrite(void *handle,uint32_t offset,uint32_t data) {
    auto *s=(simulator*)handle;if(!s->sticky)s->transaction(true,0x20000000u+offset,data,15,2,s->number()%3,nullptr);
}
extern "C" int yolo_npu_rtl_conv(void *handle,const struct yolo_conv *conv) {
    auto *s=(simulator*)handle;if(s->sticky)return YOLO_CONV_DEVICE;
    struct yolo_npu_io io={yolo_npu_rtl_nread,yolo_npu_rtl_nwrite,handle};int error=yolo_conv_s8(conv,io);
    return s->sticky?YOLO_CONV_DEVICE:error;
}
