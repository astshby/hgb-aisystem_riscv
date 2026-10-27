/* SPDX-License-Identifier: Apache-2.0 */
#include "board.h"
static struct rt_serial_device serial[2];
static rt_err_t (*framework_control)(rt_device_t, int, void *);
volatile rt_uint32_t hgb_uart_errors[2];

static rt_ubase_t base(struct rt_serial_device *s)
{
    return (rt_ubase_t)s->parent.user_data;
}

static rt_err_t validate_config(const struct serial_configure *cfg)
{
    rt_uint32_t clock = hgb_clocks.periph_hz;
    if (!cfg || !cfg->baud_rate || cfg->baud_rate > clock / 4 || !cfg->bufsz ||
        cfg->data_bits != DATA_BITS_8 || cfg->stop_bits != STOP_BITS_1 ||
        cfg->parity != PARITY_NONE || cfg->bit_order != BIT_ORDER_LSB ||
        cfg->invert != NRZ_NORMAL || cfg->flowcontrol != RT_SERIAL_FLOWCONTROL_NONE)
        return -RT_EINVAL;
    return RT_EOK;
}

static rt_err_t configure(struct rt_serial_device *s, struct serial_configure *cfg)
{
    rt_err_t result = validate_config(cfg);
    if (result) return result;
    REG32(base(s) + 12) = hgb_soc_uart_divisor(hgb_clocks.periph_hz, cfg->baud_rate);
    return RT_EOK;
}

static rt_err_t checked_control(rt_device_t dev, int cmd, void *arg)
{
    /* v5.2.2 serial-v1 会先缓存配置且忽略 configure 的错误，必须在入口拒绝。 */
    if (cmd == RT_DEVICE_CTRL_CONFIG) {
        rt_err_t result = validate_config(arg);
        if (result) return result;
    }
    return framework_control(dev, cmd, arg);
}

static rt_err_t control(struct rt_serial_device *s, int cmd, void *arg)
{
    rt_ubase_t flags = (rt_ubase_t)arg;
    switch (cmd) {
    case RT_DEVICE_CTRL_CLR_INT:
        if (flags != RT_DEVICE_FLAG_INT_RX) return -RT_EINVAL;
        REG32(base(s) + 16) = 0;
        return RT_EOK;
    case RT_DEVICE_CTRL_SET_INT:
        if (flags != RT_DEVICE_FLAG_INT_RX) return -RT_EINVAL;
        REG32(base(s) + 16) = 5;
        return RT_EOK;
    default: return -RT_ENOSYS;
    }
}

static int putc_uart(struct rt_serial_device *s, char ch)
{
    /* 轮询期间允许中断；ready 检查和写入不可被另一发送者打断。 */
    for (;;) {
        rt_base_t level = rt_hw_interrupt_disable();
        if (REG32(base(s) + 8) & 1) {
            REG32(base(s)) = (unsigned char)ch;
            rt_hw_interrupt_enable(level);
            return 1;
        }
        rt_hw_interrupt_enable(level);
    }
}

static int getc_uart(struct rt_serial_device *s)
{
    if (!(REG32(base(s) + 8) & 2)) return -1;
    return REG32(base(s) + 4) & 255;
}

static const struct rt_uart_ops ops = {
    .configure = configure, .control = control,
    .putc = putc_uart, .getc = getc_uart, .dma_transmit = RT_NULL
};

void hgb_uart_irq(unsigned n)
{
    if (n >= 2 || !hgb_soc_has(hgb_soc_presence, HGB_TARGET_UART0 + n))
        hgb_finish(151);
    rt_uint32_t status = REG32(UART_BASE(n) + 8);
    if (status & 12) {
        hgb_uart_errors[n]++;
        REG32(UART_BASE(n) + 8) = status & 12;
    }
    if (status & 2) rt_hw_serial_isr(&serial[n], RT_SERIAL_EVENT_RX_IND);
}

void hgb_uart_init(void)
{
    struct serial_configure cfg = RT_SERIAL_CONFIG_DEFAULT;
    for (unsigned n = 0; n < 2; n++) {
        if (!hgb_soc_has(hgb_soc_presence, HGB_TARGET_UART0 + n)) continue;
        REG32(UART_BASE(n) + 16) = 0;
        REG32(UART_BASE(n) + 8) = 12;
        serial[n].ops = &ops;
        serial[n].config = cfg;
        if (rt_hw_serial_register(&serial[n], n ? "uart1" : "uart0",
                RT_DEVICE_FLAG_RDWR | RT_DEVICE_FLAG_INT_RX,
                (void *)(rt_ubase_t)UART_BASE(n)) != RT_EOK) hgb_finish(147);
        framework_control = serial[n].parent.control;
        serial[n].parent.control = checked_control;
        if (hgb_irq_enable(n + 1) != RT_EOK) hgb_finish(152);
    }
}
