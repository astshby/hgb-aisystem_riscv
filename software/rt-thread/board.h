#ifndef HGB_BOARD_H
#define HGB_BOARD_H
#include <rtthread.h>
#include <rthw.h>
#include <rtdevice.h>
#define REG32(addr) (*(volatile rt_uint32_t *)(rt_ubase_t)(addr))
#define UART_BASE(n) (0x10000000u + (n) * 0x1000u)
#define GPIO_BASE(n) (0x10020000u + (n) * 0x1000u)
#define IRQ_BASE 0x0c000000u
#define DMA_BASE 0x10030000u
#define INFO_BASE 0x10040000u
#define HOT_CODE __attribute__((section(".hot.text")))
extern volatile unsigned int tohost;
extern volatile unsigned char sim_console;
extern volatile rt_uint32_t hgb_irq_count[8], hgb_tick_irqs, hgb_dma_bytes;
extern volatile rt_uint32_t hgb_uart_errors[2];
void hgb_finish(unsigned code) __attribute__((noreturn));
void hgb_drivers_init(void);
void hgb_uart_irq(unsigned n);
void hgb_gpio_irq(unsigned n);
void hgb_app_init(void);
void hgb_irq_enable(unsigned id);
rt_uint64_t hgb_mtime(void);
rt_err_t hgb_pin_mode_checked(rt_base_t pin, rt_uint8_t mode);
#endif
