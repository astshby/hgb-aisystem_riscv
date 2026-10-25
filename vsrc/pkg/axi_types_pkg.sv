// Package: axi_types_pkg
// Description: Physical 32-bit address, 256-bit data AXI4 system channels.
package axi_types_pkg;
    localparam int AXI_DATA_W = 256;
    localparam int AXI_BYTES = 32;
    localparam int AXI_LOCAL_ID_W = 2;
    localparam int AXI_MASTER_W = 2;
    localparam int AXI_ID_W = AXI_LOCAL_ID_W + AXI_MASTER_W;
    typedef logic [AXI_ID_W-1:0] axi_id_t;
    typedef enum logic [1:0] {AXI_OKAY=2'b00, AXI_SLVERR=2'b10, AXI_DECERR=2'b11} axi_resp_e;
    typedef struct packed {
        axi_id_t id;
        logic [31:0] addr;
        logic [7:0] len;
        logic [2:0] size;
        logic [1:0] burst;
        logic lock;
        logic [3:0] cache;
        logic [2:0] prot;
        logic [3:0] qos;
    } axi_a_t;
    typedef struct packed {
        logic [255:0] data;
        logic [31:0] strb;
        logic last;
    } axi_w_t;
    typedef struct packed {axi_id_t id; axi_resp_e resp;} axi_b_t;
    typedef struct packed {
        axi_id_t id;
        logic [255:0] data;
        axi_resp_e resp;
        logic last;
    } axi_r_t;
    typedef struct packed {
        logic aw_valid;
        axi_a_t aw;
        logic w_valid;
        axi_w_t w;
        logic b_ready;
        logic ar_valid;
        axi_a_t ar;
        logic r_ready;
    } axi_req_t;
    typedef struct packed {
        logic aw_ready, w_ready;
        logic b_valid;
        axi_b_t b;
        logic ar_ready, r_valid;
        axi_r_t r;
    } axi_rsp_t;
    // AXI4-Lite 控制口保留 64 位，mtime 的 RV64 访问不拆成两次副作用。
    typedef struct packed {logic [31:0] addr; logic [2:0] prot;} axil_a_t;
    typedef struct packed {logic [63:0] data; logic [7:0] strb;} axil_w_t;
    typedef struct packed {logic [63:0] data; axi_resp_e resp;} axil_r_t;
    typedef struct packed {
        logic aw_valid; axil_a_t aw;
        logic w_valid; axil_w_t w;
        logic b_ready;
        logic ar_valid; axil_a_t ar;
        logic r_ready;
    } axil_req_t;
    typedef struct packed {
        logic aw_ready, w_ready, b_valid;
        axi_resp_e b;
        logic ar_ready, r_valid;
        axil_r_t r;
    } axil_rsp_t;
endpackage
