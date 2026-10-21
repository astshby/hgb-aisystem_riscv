/* SPDX-License-Identifier: Apache-2.0 */
#include "board.h"
static struct rt_thread tester, workers[2];
static rt_uint8_t tester_stack[4096] __attribute__((aligned(16)));
static rt_uint8_t worker_stack[2][2048] __attribute__((aligned(16)));
static struct rt_semaphore events;
static volatile rt_uint32_t progress[2], stopped, exited, timer_calls;
static struct rt_timer test_timer;
extern int hgb_context_probe(volatile rt_uint32_t *stop, volatile rt_uint32_t *count, unsigned id);

#define CHECK(expr, code) do { if (!(expr)) hgb_finish(code); } while (0)
static void report(const char *s) { while (*s) sim_console = *s++; }
static void timer_callback(void *arg) { (void)arg; timer_calls++; }
static void pin_callback(void *arg)
{
    (void)arg;
    CHECK(rt_interrupt_get_nest() > 0, 50);
    rt_sem_release(&events);
}
static rt_err_t rx_callback(rt_device_t dev, rt_size_t size)
{
    (void)dev;
    CHECK(size > 0 && rt_interrupt_get_nest() > 0, 51);
    rt_sem_release(&events);
    return RT_EOK;
}
static void worker(void *arg)
{
    unsigned id = (unsigned)(rt_ubase_t)arg;
    /* 不主动 yield/delay：两个同优先级线程必须靠时钟时间片获得 CPU。 */
    CHECK(hgb_context_probe(&stopped, &progress[id], id) == 0, 52);
    rt_base_t level = rt_hw_interrupt_disable();
    exited++;
    rt_hw_interrupt_enable(level);
}
static void test_entry(void *arg)
{
    (void)arg;
    unsigned uart_count = 0, gpio_count = 0, missing_count = 0;
    char summary[128];
    rt_snprintf(summary, sizeof(summary), "rt discovery ABI=%u profile=%u presence=0x%08x\n",
                HGB_SOC_DISCOVERY_ABI, (unsigned)hgb_soc_profile, (unsigned)hgb_soc_presence);
    report(summary);
    rt_ubase_t mtvec;
    __asm__ volatile("csrr %0, mtvec" : "=r"(mtvec));
    CHECK(mtvec == 0x0100e000u && hgb_dma_bytes > 0, 1);
    report("PASS rt DMA hot code + Direct mtvec\n");
    rt_tick_t start = rt_tick_get();
    CHECK(rt_thread_delay(12) == RT_EOK, 2);
    CHECK(rt_tick_get() - start >= 12 && hgb_tick_irqs > 0, 3);
    CHECK(progress[0] > 0 && progress[1] > 0, 4);
    CHECK(timer_calls >= 2, 5);
    CHECK(rt_sem_take(&events, 2) == -RT_ETIMEOUT, 6);
    report("PASS rt tick preemption + time slice + timer + semaphore timeout\n");

    for (unsigned n = 0; n < 2; n++) {
        rt_device_t dev = rt_device_find(n ? "uart1" : "uart0");
        if (!hgb_soc_has(hgb_soc_presence, HGB_TARGET_UART0 + n)) {
            CHECK(dev == RT_NULL && hgb_irq_enable(n + 1) == -RT_EINVAL, 21);
            missing_count++;
            continue;
        }
        uart_count++;
        CHECK(dev != RT_NULL, 10);
        CHECK(rt_device_init(dev) == RT_EOK, 11);
        struct serial_configure cfg = RT_SERIAL_CONFIG_DEFAULT;
        cfg.parity = PARITY_ODD;
        CHECK(rt_device_control(dev, RT_DEVICE_CTRL_CONFIG, &cfg) == -RT_EINVAL, 12);
        cfg.parity = PARITY_NONE;
        CHECK(rt_device_control(dev, RT_DEVICE_CTRL_CONFIG, &cfg) == RT_EOK, 13);
        rt_device_set_rx_indicate(dev, rx_callback);
        CHECK(rt_device_open(dev, RT_DEVICE_OFLAG_RDWR | RT_DEVICE_FLAG_INT_RX) == RT_EOK, 14);
        for (unsigned i = 0; i < 4; i++) {
            unsigned char tx = 0x41 + n * 4 + i, rx = 0;
            CHECK(rt_device_write(dev, 0, &tx, 1) == 1, 15);
            CHECK(rt_sem_take(&events, 20) == RT_EOK, 16);
            CHECK(rt_device_read(dev, 0, &rx, 1) == 1 && rx == tx, 17);
        }
        CHECK(hgb_irq_count[n + 1] >= 4 && hgb_uart_errors[n] == 0, 18);
        CHECK(rt_device_close(dev) == RT_EOK, 19);
        CHECK(REG32(UART_BASE(n) + 16) == 0, 20);
    }
    if (uart_count == 2)
        report("PASS rt UART0/1 device API + RX IRQ semaphore wakeup + close\n");
    else
        report("PASS rt present UART device API + RX IRQ semaphore wakeup + close; absent UART unregistered\n");

    CHECK(hgb_pin_mode_checked(0, PIN_MODE_INPUT_PULLUP) == -RT_EINVAL, 30);
    CHECK(rt_pin_attach_irq(96, PIN_IRQ_MODE_RISING, pin_callback, RT_NULL) == -RT_EINVAL, 31);
    for (unsigned n = 0; n < 3; n++) {
        rt_base_t p = n * 32 + 3;
        if (!hgb_soc_has(hgb_soc_presence, HGB_TARGET_GPIO0 + n)) {
            CHECK(hgb_pin_mode_checked(p, PIN_MODE_OUTPUT) == -RT_EINVAL, 41);
            CHECK(rt_pin_read(p) == -RT_EINVAL, 42);
            CHECK(rt_pin_attach_irq(p, PIN_IRQ_MODE_RISING, pin_callback, RT_NULL) == -RT_EINVAL, 43);
            CHECK(rt_pin_irq_enable(p, PIN_IRQ_ENABLE) == -RT_EINVAL &&
                  rt_pin_detach_irq(p) == -RT_EINVAL && hgb_irq_enable(n + 4) == -RT_EINVAL, 44);
            rt_set_errno(0);
            rt_pin_write(p, PIN_HIGH);
            CHECK(rt_get_errno() == -RT_EINVAL, 45);
            missing_count++;
            continue;
        }
        gpio_count++;
        rt_pin_write(p, PIN_LOW);
        rt_pin_mode(p, PIN_MODE_OUTPUT);
        CHECK(rt_pin_attach_irq(p, PIN_IRQ_MODE_HIGH_LEVEL, pin_callback, RT_NULL) == -RT_EINVAL, 32);
        CHECK(rt_pin_attach_irq(p, PIN_IRQ_MODE_RISING_FALLING, pin_callback, RT_NULL) == RT_EOK, 33);
        CHECK(rt_pin_irq_enable(p, PIN_IRQ_ENABLE) == RT_EOK, 34);
        rt_pin_write(p, PIN_HIGH);
        CHECK(rt_sem_take(&events, 10) == RT_EOK && rt_pin_read(p) == PIN_HIGH, 35);
        rt_pin_write(p, PIN_LOW);
        CHECK(rt_sem_take(&events, 10) == RT_EOK && rt_pin_read(p) == PIN_LOW, 36);
        CHECK(hgb_irq_count[n + 4] >= 2, 37);
        CHECK(rt_pin_detach_irq(p) == RT_EOK, 38);
        rt_pin_write(p, PIN_HIGH);
        CHECK(rt_sem_take(&events, 2) == -RT_ETIMEOUT, 39);
        rt_pin_mode(p, PIN_MODE_INPUT);
    }
    if (gpio_count == 3)
        report("PASS rt GPIO 3 banks + edge IRQ + detach + unsupported modes\n");
    else
        report("PASS rt present GPIO banks + edge IRQ + detach; absent GPIO APIs rejected\n");
    rt_snprintf(summary, sizeof(summary),
                "PASS rt capabilities profile=%u presence=0x%08x UART_count=%u GPIO_count=%u absent_checked=%u\n",
                (unsigned)hgb_soc_profile, (unsigned)hgb_soc_presence,
                uart_count, gpio_count, missing_count);
    report(summary);
    stopped = 1;
    rt_thread_delay(4);
    CHECK(exited == 2, 40);
    rt_timer_stop(&test_timer);
    report("PASS rt register context + thread return + idle\n");
    hgb_finish(0);
}
void hgb_app_init(void)
{
    CHECK(rt_sem_init(&events, "events", 0, RT_IPC_FLAG_FIFO) == RT_EOK, 60);
    rt_timer_init(&test_timer, "periodic", timer_callback, RT_NULL, 3, RT_TIMER_FLAG_PERIODIC);
    rt_timer_start(&test_timer);
    for (unsigned n = 0; n < 2; n++) {
        CHECK(rt_thread_init(&workers[n], n ? "worker1" : "worker0", worker,
            (void *)(rt_ubase_t)n, worker_stack[n], sizeof(worker_stack[n]), 12, 2) == RT_EOK, 61);
        CHECK(rt_thread_startup(&workers[n]) == RT_EOK, 62);
    }
    CHECK(rt_thread_init(&tester, "smoke", test_entry, RT_NULL,
        tester_stack, sizeof(tester_stack), 8, 2) == RT_EOK, 63);
    CHECK(rt_thread_startup(&tester) == RT_EOK, 64);
}
