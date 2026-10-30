/* Module: yolo_demo_io_api
 * Description: Native CPU access to real UART/NPU/video/AXI RTL with shared behavioral DDR; no RISC-V CPU.
 */
#ifndef YOLO_DEMO_IO_H
#define YOLO_DEMO_IO_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
struct yolo_demo_io;
struct yolo_demo_io_config {
    uint32_t uart_baud; /* 0=115200; actual divisor rounded from the real 60 MHz peripheral clock. */
    uint32_t random_seed;
};
struct yolo_demo_io_stats {
    uint64_t sys_cycles,ddr_cycles,periph_cycles,npu_cycles,pixel_cycles;
    uint64_t uart_rx_bytes,uart_tx_bytes,uart_tx_frame_errors,uart_rx_queued;
    uint64_t reads,writes,axi_error,maximum_transaction_cycles;
    uint64_t ddr_ar,ddr_aw,ddr_r,ddr_w,ddr_b;
    uint64_t frames_complete;
    uint32_t pixel_crc,frame_pixels,frame_sequence,active_buffer;
    uint32_t underflow,video_bus_errors,i2c_done,i2c_error,i2c_writes;
    uint32_t uart_baud,uart_divisor;
};
struct yolo_demo_io *yolo_demo_io_open(const struct yolo_demo_io_config *);
void yolo_demo_io_close(struct yolo_demo_io *);
int yolo_demo_io_read32(struct yolo_demo_io *,uint32_t address,uint32_t *value);
int yolo_demo_io_write32(struct yolo_demo_io *,uint32_t address,uint32_t value);
void *yolo_demo_io_ram_ptr(struct yolo_demo_io *,uint32_t address,size_t bytes);
int yolo_demo_io_queue_rx(struct yolo_demo_io *,const uint8_t *,size_t bytes);
size_t yolo_demo_io_take_tx(struct yolo_demo_io *,uint8_t *,size_t capacity);
int yolo_demo_io_step(struct yolo_demo_io *,uint64_t sys_cycles);
void yolo_demo_io_get_stats(struct yolo_demo_io *,struct yolo_demo_io_stats *);
int yolo_demo_io_error(struct yolo_demo_io *);
/* Finish pending host RX first; this updates the actual MMIO divisor and serial timing together. */
int yolo_demo_io_set_baud(struct yolo_demo_io *,uint32_t baud);
/* Optional progress notification after a real accepted NPU START(2) write. */
void yolo_demo_io_progress(struct yolo_demo_io *,void (*)(void *,uint64_t tiles,uint64_t sys_cycles),void *);
#ifdef __cplusplus
}
#endif
#endif
