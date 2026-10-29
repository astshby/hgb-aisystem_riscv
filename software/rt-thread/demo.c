/* Module: rt_uart_demo
 * Description: Independent RT-Thread UART service with RX IRQ wakeup and a periodic worker.
 */
#include "board.h"
#include "demo_command.h"

static struct rt_thread terminal_thread, worker_thread;
static rt_uint8_t terminal_stack[4096] __attribute__((aligned(16)));
static rt_uint8_t worker_stack[2048] __attribute__((aligned(16)));
static struct rt_semaphore received;
static rt_device_t uart;
static volatile rt_uint32_t worker_steps;

static void write_text(const char *text)
{
    rt_size_t length = rt_strlen(text);
    if (rt_device_write(uart, 0, text, length) != length) hgb_finish(170);
}

static void status(const char *prefix)
{
    char text[256];
    rt_snprintf(text, sizeof(text),
        "%s app=rt-thread core_hz=%u sys_hz=%u ddr_hz=%u periph_hz=%u tick_hz=%u\n",
        prefix, hgb_clocks.core_hz, hgb_clocks.sys_hz, hgb_clocks.ddr_hz,
        hgb_clocks.periph_hz, RT_TICK_PER_SECOND);
    write_text(text);
}

static rt_err_t rx_indicate(rt_device_t device, rt_size_t size)
{
    (void)device;
    if (size) rt_sem_release(&received);
    return RT_EOK;
}

static void periodic_worker(void *argument)
{
    (void)argument;
    for (;;) {
        worker_steps++;
        rt_thread_delay(5);
    }
}

static void terminal(void *argument)
{
    (void)argument;
    struct rt_demo_input input = {0};
    status("READY");
    for (;;) {
        unsigned char byte;
        if (rt_device_read(uart, 0, &byte, 1) != 1) {
            rt_sem_take(&received, RT_WAITING_FOREVER);
            continue;
        }
        enum rt_demo_command command = rt_demo_feed(&input, byte);
        if (command == DEMO_MORE) continue;
        const char *done = "DONE status=completed\n";
        if (command == DEMO_STATUS) {
            char text[160];
            status("RT_CLOCKS");
            rt_snprintf(text, sizeof(text),
                "RT_STATUS tick=%u tick_irqs=%u worker_steps=%u uart_irqs=%u uart_errors=%u dma_boot_bytes=%u\n",
                (unsigned)rt_tick_get(), hgb_tick_irqs, worker_steps,
                hgb_irq_count[1], hgb_uart_errors[0], hgb_dma_bytes);
            write_text(text);
        } else if (command == DEMO_PING) write_text("PONG\n");
        else if (command == DEMO_ECHO) {
            write_text("RT_ECHO text=");
            write_text(input.text + 5);
            write_text("\n");
        } else if (command == DEMO_TASKS) {
            rt_uint32_t ticks = hgb_tick_irqs, steps = worker_steps;
            rt_thread_delay(20);
            char text[128];
            rt_snprintf(text, sizeof(text), "RT_TASKS tick_irqs_delta=%u worker_steps_delta=%u\n",
                        hgb_tick_irqs - ticks, worker_steps - steps);
            write_text(text);
            if (ticks == hgb_tick_irqs || steps == worker_steps) done = "DONE status=task_error\n";
        } else done = command == DEMO_LONG ? "DONE status=line_too_long\n" : "DONE status=bad_command\n";
        write_text(done);
        status("READY");
    }
}

void hgb_app_init(void)
{
    uart = rt_device_find("uart0");
    if (!uart || rt_sem_init(&received, "uart-rx", 0, RT_IPC_FLAG_FIFO)) hgb_finish(171);
    if (rt_device_init(uart)) hgb_finish(172);
    struct serial_configure config = RT_SERIAL_CONFIG_DEFAULT;
    config.baud_rate = 115200;
    config.bufsz = 256;
    if (rt_device_control(uart, RT_DEVICE_CTRL_CONFIG, &config)) hgb_finish(173);
    rt_device_set_rx_indicate(uart, rx_indicate);
    if (rt_device_open(uart, RT_DEVICE_OFLAG_RDWR | RT_DEVICE_FLAG_INT_RX)) hgb_finish(174);
    // 只有 terminal 线程发送 UART，worker 只记录计时调度进度。
    if (rt_thread_init(&worker_thread, "periodic", periodic_worker, RT_NULL,
                       worker_stack, sizeof(worker_stack), 12, 2) ||
        rt_thread_startup(&worker_thread)) hgb_finish(175);
    if (rt_thread_init(&terminal_thread, "terminal", terminal, RT_NULL,
                       terminal_stack, sizeof(terminal_stack), 8, 2) ||
        rt_thread_startup(&terminal_thread)) hgb_finish(176);
}
