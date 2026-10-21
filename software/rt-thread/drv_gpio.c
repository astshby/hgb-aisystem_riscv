/* SPDX-License-Identifier: Apache-2.0 */
#include "board.h"
static struct { void (*handler)(void *); void *arg; rt_uint8_t mode; } handlers[96];
static int valid(rt_base_t pin)
{
    /* 引脚号合法还须对应实际 bank；所有 API 在计算 MMIO 地址前共用此检查。 */
    return pin >= 0 && pin < 96 &&
           hgb_soc_has(hgb_soc_presence, HGB_TARGET_GPIO0 + (unsigned)pin / 32);
}
static unsigned bank(rt_base_t pin) { return GPIO_BASE((unsigned)pin / 32); }
static rt_uint32_t bit(rt_base_t pin) { return 1u << ((unsigned)pin % 32); }

rt_err_t hgb_pin_mode_checked(rt_base_t pin, rt_uint8_t mode)
{
    if (!valid(pin) || (mode != PIN_MODE_INPUT && mode != PIN_MODE_OUTPUT))
        return -RT_EINVAL;
    rt_base_t level = rt_hw_interrupt_disable();
    if (mode == PIN_MODE_OUTPUT) REG32(bank(pin) + 8) |= bit(pin);
    else REG32(bank(pin) + 8) &= ~bit(pin);
    rt_hw_interrupt_enable(level);
    return RT_EOK;
}

static void pin_mode(struct rt_device *dev, rt_base_t pin, rt_uint8_t mode)
{
    (void)dev;
    /* 上游 void API 无返回值；不支持的电气模式只设置 errno，不改寄存器。 */
    rt_err_t result = hgb_pin_mode_checked(pin, mode);
    if (result) rt_set_errno(result);
}
static void pin_write(struct rt_device *dev, rt_base_t pin, rt_uint8_t value)
{
    (void)dev;
    if (!valid(pin)) { rt_set_errno(-RT_EINVAL); return; }
    rt_base_t level = rt_hw_interrupt_disable();
    if (value) REG32(bank(pin) + 4) |= bit(pin);
    else REG32(bank(pin) + 4) &= ~bit(pin);
    rt_hw_interrupt_enable(level);
}
static rt_ssize_t pin_read(struct rt_device *dev, rt_base_t pin)
{
    (void)dev;
    if (!valid(pin)) return -RT_EINVAL;
    return !!(REG32(bank(pin)) & bit(pin));
}
static rt_err_t attach(struct rt_device *dev, rt_base_t pin, rt_uint8_t mode,
                       void (*handler)(void *), void *arg)
{
    (void)dev;
    if (!valid(pin) || !handler || mode > PIN_IRQ_MODE_RISING_FALLING) return -RT_EINVAL;
    rt_base_t level = rt_hw_interrupt_disable();
    if (handlers[pin].handler) { rt_hw_interrupt_enable(level); return -RT_EBUSY; }
    handlers[pin].handler = handler;
    handlers[pin].arg = arg;
    handlers[pin].mode = mode;
    rt_hw_interrupt_enable(level);
    return RT_EOK;
}
static rt_err_t irq_enable(struct rt_device *dev, rt_base_t pin, rt_uint8_t enabled)
{
    (void)dev;
    if (!valid(pin) || enabled > PIN_IRQ_ENABLE) return -RT_EINVAL;
    rt_base_t level = rt_hw_interrupt_disable();
    unsigned b = bank(pin); rt_uint32_t mask = bit(pin);
    REG32(b + 12) &= ~mask;
    if (enabled) {
        if (!handlers[pin].handler) { rt_hw_interrupt_enable(level); return -RT_EINVAL; }
        rt_uint8_t mode = handlers[pin].mode;
        REG32(b + 16) = (REG32(b + 16) & ~mask) |
            (mode != PIN_IRQ_MODE_FALLING ? mask : 0);
        REG32(b + 20) = (REG32(b + 20) & ~mask) |
            (mode != PIN_IRQ_MODE_RISING ? mask : 0);
        REG32(b + 24) = mask;
        REG32(b + 12) |= mask;
    }
    rt_hw_interrupt_enable(level);
    return RT_EOK;
}
static rt_err_t detach(struct rt_device *dev, rt_base_t pin)
{
    if (!valid(pin)) return -RT_EINVAL;
    rt_base_t level = rt_hw_interrupt_disable();
    irq_enable(dev, pin, PIN_IRQ_DISABLE);
    handlers[pin].handler = RT_NULL;
    handlers[pin].arg = RT_NULL;
    rt_hw_interrupt_enable(level);
    return RT_EOK;
}
static const struct rt_pin_ops ops = {
    .pin_mode = pin_mode, .pin_write = pin_write, .pin_read = pin_read,
    .pin_attach_irq = attach, .pin_detach_irq = detach, .pin_irq_enable = irq_enable
};
void hgb_gpio_irq(unsigned n)
{
    if (n >= 3 || !hgb_soc_has(hgb_soc_presence, HGB_TARGET_GPIO0 + n))
        hgb_finish(153);
    unsigned b = GPIO_BASE(n);
    rt_uint32_t pending = REG32(b + 24) & REG32(b + 12);
    /* 清除快照后再回调，避免回调期间新边沿被误清。 */
    REG32(b + 24) = pending;
    for (unsigned p = 0; p < 32; p++)
        if ((pending & (1u << p)) && handlers[n * 32 + p].handler)
            handlers[n * 32 + p].handler(handlers[n * 32 + p].arg);
}
extern void hgb_uart_init(void);
void hgb_drivers_init(void)
{
    REG32(IRQ_BASE + 0x2000) = 0;
    REG32(IRQ_BASE + 0x200000) = 0;
    hgb_uart_init();
    for (unsigned n = 0; n < 3; n++) {
        if (!hgb_soc_has(hgb_soc_presence, HGB_TARGET_GPIO0 + n)) continue;
        REG32(GPIO_BASE(n) + 12) = 0;
        REG32(GPIO_BASE(n) + 16) = 0;
        REG32(GPIO_BASE(n) + 20) = 0;
        REG32(GPIO_BASE(n) + 24) = 0xffffffffu;
        if (hgb_irq_enable(n + 4) != RT_EOK) hgb_finish(154);
    }
    if (rt_device_pin_register("pin", &ops, RT_NULL)) hgb_finish(148);
}
