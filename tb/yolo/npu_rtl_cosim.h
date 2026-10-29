/* Module: yolo_npu_rtl_api
 * Description: Blocking real AXI/NPU transactions and independently clocked RTL simulation context.
 */
#ifndef YOLO_NPU_RTL_COSIM_H
#define YOLO_NPU_RTL_COSIM_H
#include <stdint.h>
#include "conv_schedule.h"
#ifdef __cplusplus
extern "C" {
#endif
struct yolo_npu_rtl_stats {
    uint64_t sys_cycles,npu_cycles,reads,writes,error_responses,response_stalls;
    uint64_t aw_count,w_count,b_count,ar_count,r_count,maximum_transaction_cycles;
};
void *yolo_npu_rtl_create(uint64_t sys_period_ps,uint64_t npu_period_ps,uint64_t phase_ps,uint32_t seed);
void yolo_npu_rtl_destroy(void *);
int yolo_npu_rtl_reset(void *);
void yolo_npu_rtl_advance(void *,uint32_t sys_cycles);
int yolo_npu_rtl_transaction(void *,int write,uint32_t address,uint32_t data,
    uint32_t strobes,uint32_t size,uint32_t response_hold_cycles,uint32_t *result);
int yolo_npu_rtl_error(void *);
void yolo_npu_rtl_clear_error(void *);
void yolo_npu_rtl_get_stats(void *,struct yolo_npu_rtl_stats *);
void yolo_npu_rtl_progress(void *,void (*callback)(void *,uint64_t tiles,uint64_t sys_cycles),void *);
uint32_t yolo_npu_rtl_nread(void *,uint32_t offset);
void yolo_npu_rtl_nwrite(void *,uint32_t offset,uint32_t data);
int yolo_npu_rtl_conv(void *,const struct yolo_conv *);
#ifdef __cplusplus
}
#endif
#endif
