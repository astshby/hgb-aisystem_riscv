// Module: ddr_to_axi
// Description: Single-outstanding 256-bit DDR memory port to single-beat AXI4, with native byte addressing.
module ddr_to_axi #(
    parameter int unsigned DDR_BYTES = 64 * 1024
) (
    input logic clk, rst,
    input logic req_valid,
    output logic req_ready,
    input bus_types_pkg::ddr_req_t request,
    output logic rsp_valid,
    input logic rsp_ready,
    output bus_types_pkg::ddr_rsp_t response,
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
    output logic [255:0] wdata,
    output logic [31:0] wstrb,
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
    input logic [255:0] rdata,
    input logic [1:0] rresp,
    input logic rlast
);
    import bus_types_pkg::*;
    import soc_addr_pkg::*;
    typedef enum logic [1:0] {IDLE, READ, WRITE, RESPONSE} state_e;
    state_e state_q;
    ddr_req_t request_q;
    ddr_rsp_t response_q;
    logic aw_pending_q, w_pending_q, ar_pending_q, read_bad_q;
    logic [31:0] allowed_strb;
    logic [64:0] access_end;
    bus_error_e request_error, axi_error;

    // size 表达实际字节数；CPU 窄读仍发窄 ARSIZE，不为扩宽数据线偷偷扩大访问范围。
    // DMA 整拍 size=5，自然对齐使单 beat 不跨 4 KiB；这里不宣称支持 AXI burst。
    always_comb begin
        access_end = 65'(request.addr) + (65'd1 << request.size);
        allowed_strb = 32'(((65'd1 << (65'd1 << request.size)) - 1) << request.addr[4:0]);
        request_error = BUS_OK;
        if (65'(request.addr) < 65'(DDR_BASE) || access_end > 65'(DDR_BASE) + 65'(DDR_BYTES) ||
            access_end > (65'd1 << 32))
            request_error = BUS_DECERR;
        else if (request.size > 5 ||
                 (65'(request.addr) & ((65'd1 << request.size)-1)) != 0 ||
                 (request.execute && (request.write || request.size != 2)) ||
                 (request.write && (request.wstrb & ~allowed_strb) != 0))
            request_error = BUS_SLVERR;
    end
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
    assign awsize = request_q.size;
    assign arsize = request_q.size;
    assign wdata = request_q.wdata;
    assign wstrb = request_q.wstrb;
    assign wlast = 1'b1;
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

    // 无独占请求；EXOKAY/错误 ID/多余读 beat 都是 SLVERR，多余 beat 排空到 RLAST。
    always_comb begin
        unique case (state_q == WRITE ? bresp : rresp)
            2'b00: axi_error = BUS_OK;
            2'b11: axi_error = BUS_DECERR;
            default: axi_error = BUS_SLVERR;
        endcase
        if ((state_q == WRITE && bid) || (state_q == READ && (rid || read_bad_q || !rlast)))
            axi_error = BUS_SLVERR;
    end

    // AXI 通道 valid 来自已寄存的 owner；AW/W 独立握手，最终 B 才确认成功写。
    // 响应槽保持至上游消费，复位必须与共享外存端协调，不提供事务撤销。
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
            unique case (state_q)
                IDLE: if (req_valid && req_ready) begin
                    request_q <= request;
                    response_q <= '{rdata:'0, error:request_error};
                    read_bad_q <= 1'b0;
                    if (request_error != BUS_OK) state_q <= RESPONSE;
                    else if (request.write) begin
                        state_q <= WRITE; aw_pending_q <= 1'b1; w_pending_q <= 1'b1;
                    end else begin state_q <= READ; ar_pending_q <= 1'b1; end
                end
                WRITE: begin
                    if (awvalid && awready) aw_pending_q <= 1'b0;
                    if (wvalid && wready) w_pending_q <= 1'b0;
                    if (bvalid && bready) begin
                        response_q <= '{rdata:'0, error:axi_error}; state_q <= RESPONSE;
                    end
                end
                READ: begin
                    if (arvalid && arready) ar_pending_q <= 1'b0;
                    if (rvalid && rready) begin
                        if (!rlast) read_bad_q <= 1'b1;
                        else begin
                            response_q <= '{rdata:(axi_error == BUS_OK ? rdata : '0), error:axi_error};
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
