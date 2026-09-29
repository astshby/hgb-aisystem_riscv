// Package: bus_types_pkg
// Description: Single-outstanding local bus request, response, and target types.
// valid/ready 是独立握手线；载荷不混入有效位。地址保留 XLEN，避免 RV64 高位静默截断。
package bus_types_pkg;
    import core_config_pkg::*;
    import core_types_pkg::*;
    typedef enum logic [1:0] { BUS_OK, BUS_DECERR, BUS_SLVERR } bus_error_e;
    typedef enum logic [3:0] {
        TARGET_ERROR, TARGET_ROM, TARGET_ITCM, TARGET_DTCM, TARGET_MTIME,
        TARGET_IRQ, TARGET_UART0, TARGET_UART1, TARGET_TIMER,
        TARGET_GPIO0, TARGET_GPIO1, TARGET_GPIO2, TARGET_DMA, TARGET_SOC, TARGET_DDR
    } bus_target_e;
    typedef struct packed {
        logic write;
        logic execute;
        mem_size_e size;
        xlen_t addr;
        xlen_t wdata;
        logic [DBUS_BYTES-1:0] wstrb;
    } bus_req_t;
    typedef struct packed {
        xlen_t rdata;
        bus_error_e error;
    } bus_rsp_t;
endpackage
