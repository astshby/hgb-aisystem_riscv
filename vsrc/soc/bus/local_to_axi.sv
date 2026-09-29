// Module: local_to_axi
// Description: Single-outstanding local bus to single-beat AXI4 master bridge.
module local_to_axi (
    input logic clk, rst,
    input logic req_valid,
    output logic req_ready,
    input bus_types_pkg::bus_req_t request,
    output logic rsp_valid,
    input logic rsp_ready,
    output bus_types_pkg::bus_rsp_t response,
    output logic awvalid,
    input logic awready,
    output logic awid,
    output logic [31:0] awaddr,
    output logic [7:0] awlen,
    output logic [2:0] awsize,
    output logic [1:0] awburst,
    output logic awlock,
    output logic [3:0] awcache, awqos, awregion,
    output logic [2:0] awprot,
    output logic wvalid,
    input logic wready,
    output logic [core_config_pkg::XLEN-1:0] wdata,
    output logic [core_config_pkg::DBUS_BYTES-1:0] wstrb,
    output logic wlast,
    input logic bvalid,
    output logic bready,
    input logic bid,
    input logic [1:0] bresp,
    output logic arvalid,
    input logic arready,
    output logic arid,
    output logic [31:0] araddr,
    output logic [7:0] arlen,
    output logic [2:0] arsize,
    output logic [1:0] arburst,
    output logic arlock,
    output logic [3:0] arcache, arqos, arregion,
    output logic [2:0] arprot,
    input logic rvalid,
    output logic rready,
    input logic rid,
    input logic [core_config_pkg::XLEN-1:0] rdata,
    input logic [1:0] rresp,
    input logic rlast
);
    import core_config_pkg::*;
    import core_types_pkg::*;
    import bus_types_pkg::*;
    typedef enum logic [1:0] { IDLE, READ, WRITE, RESPONSE } state_e;
    state_e state_q;
    bus_req_t request_q;
    bus_rsp_t response_q;
    logic aw_pending_q, w_pending_q, ar_pending_q, read_bad_q;
    logic [DBUS_BYTES-1:0] allowed_strb;
    bus_error_e request_error, axi_error;

    // 首版物理地址固定 32 位；非法请求只在本地完成，不能截断成合法 AXI 地址。
    // 数据已按总线 byte lane 对齐，窄访问不再平移 WDATA/RDATA。
    always_comb begin
        allowed_strb = DBUS_BYTES'(((1 << (1 << request.size)) - 1) <<
                                   request.addr[$clog2(DBUS_BYTES)-1:0]);
        request_error = BUS_OK;
        if (65'(request.addr) >= (65'd1 << 32))
            request_error = BUS_DECERR;
        else if ((request.addr & ((xlen_t'(1) << request.size) - 1)) != 0 ||
                 (request.size == MEM_DWORD && XLEN != 64) ||
                 (request.execute && (request.write || request.size != MEM_WORD)) ||
                 (request.write && ((request.wstrb & ~allowed_strb) != 0)))
            request_error = BUS_SLVERR;
    end

    // 所有 AXI VALID 仅取决于已寄存状态，不等待对方 READY；写地址与写数据独立完成。
    assign req_ready = !rst && state_q == IDLE;
    assign rsp_valid = !rst && state_q == RESPONSE;
    assign response = response_q;
    assign awvalid = !rst && state_q == WRITE && aw_pending_q;
    assign wvalid = !rst && state_q == WRITE && w_pending_q;
    assign bready = !rst && state_q == WRITE && !aw_pending_q && !w_pending_q;
    assign arvalid = !rst && state_q == READ && ar_pending_q;
    assign rready = !rst && state_q == READ && !ar_pending_q;
    assign awaddr = 32'(request_q.addr);
    assign araddr = 32'(request_q.addr);
    assign awsize = 3'(request_q.size);
    assign arsize = 3'(request_q.size);
    assign wdata = request_q.wdata;
    assign wstrb = request_q.wstrb;
    assign wlast = 1'b1;

    // 固定 ID=0、单 beat INCR、无独占、无缓存/缓冲；PROT 标记 M-mode 和取指用途。
    assign awid = 1'b0;
    assign arid = 1'b0;
    assign awlen = '0;
    assign arlen = '0;
    assign awburst = 2'b01;
    assign arburst = 2'b01;
    assign awlock = 1'b0;
    assign arlock = 1'b0;
    assign awcache = '0;
    assign arcache = '0;
    assign awqos = '0;
    assign arqos = '0;
    assign awregion = '0;
    assign arregion = '0;
    assign awprot = 3'b001;
    assign arprot = {request_q.execute, 2'b01};

    // 不发独占请求，因此 EXOKAY/错误 ID 不是正常完成；异常读 beat 排空到 RLAST。
    always_comb begin
        axi_error = BUS_OK;
        case ((state_q == WRITE) ? bresp : rresp)
            2'b00: axi_error = BUS_OK;
            2'b11: axi_error = BUS_DECERR;
            default: axi_error = BUS_SLVERR;
        endcase
        if ((state_q == WRITE && bid) ||
            (state_q == READ && (rid || read_bad_q || !rlast)))
            axi_error = BUS_SLVERR;
    end

    // 接受本地请求后不可取消；响应保持到本地消费。复位必须与外部互连/从端协调。
    always_ff @(posedge clk) begin
        if (rst) begin
            state_q <= IDLE;
            request_q <= '0;
            response_q <= '0;
            aw_pending_q <= 1'b0;
            w_pending_q <= 1'b0;
            ar_pending_q <= 1'b0;
            read_bad_q <= 1'b0;
        end else begin
            case (state_q)
                IDLE: if (req_valid && req_ready) begin
                    request_q <= request;
                    response_q <= '{rdata: '0, error: request_error};
                    read_bad_q <= 1'b0;
                    if (request_error != BUS_OK) begin
                        state_q <= RESPONSE;
                    end else if (request.write) begin
                        state_q <= WRITE;
                        aw_pending_q <= 1'b1;
                        w_pending_q <= 1'b1;
                    end else begin
                        state_q <= READ;
                        ar_pending_q <= 1'b1;
                    end
                end
                WRITE: begin
                    if (awvalid && awready) aw_pending_q <= 1'b0;
                    if (wvalid && wready) w_pending_q <= 1'b0;
                    if (bvalid && bready) begin
                        response_q <= '{rdata: '0, error: axi_error};
                        state_q <= RESPONSE;
                    end
                end
                READ: begin
                    if (arvalid && arready) ar_pending_q <= 1'b0;
                    if (rvalid && rready) begin
                        if (!rlast) read_bad_q <= 1'b1;
                        else begin
                            response_q <= '{rdata: (axi_error == BUS_OK ? rdata : '0),
                                            error: axi_error};
                            state_q <= RESPONSE;
                        end
                    end
                end
                RESPONSE: if (rsp_ready) state_q <= IDLE;
                default: state_q <= IDLE;
            endcase
        end
    end
endmodule
