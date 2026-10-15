// Module: pango_ddr3_bridge
// Description: Single-outstanding local bus bridge to the PG2L200H DDR3 IP's 256-bit user port.
module pango_ddr3_bridge #(
    parameter int unsigned DDR_BYTES = 512 * 1024 * 1024
) (
    input logic clk, rst,
    input logic req_valid,
    output logic req_ready,
    input bus_types_pkg::bus_req_t request,
    output logic rsp_valid,
    input logic rsp_ready,
    output bus_types_pkg::bus_rsp_t response,
    output logic [27:0] axi_awaddr,
    output logic axi_awuser_ap,
    output logic [3:0] axi_awuser_id, axi_awlen,
    output logic axi_awvalid,
    input logic axi_awready,
    output logic [255:0] axi_wdata,
    output logic [31:0] axi_wstrb,
    input logic axi_wready,
    output logic [27:0] axi_araddr,
    output logic axi_aruser_ap,
    output logic [3:0] axi_aruser_id, axi_arlen,
    output logic axi_arvalid,
    input logic axi_arready,
    input logic [255:0] axi_rdata,
    input logic [3:0] axi_rid,
    input logic axi_rlast, axi_rvalid
);
    import core_config_pkg::*;
    import core_types_pkg::*;
    import bus_types_pkg::*;
    import soc_addr_pkg::*;

    typedef enum logic [2:0] { IDLE, WRITE_ADDR, WRITE_DATA, READ_ADDR,
                               READ_DATA, RESPONSE } state_e;
    state_e state_q;
    logic [27:0] ip_addr_q;
    logic [255:0] write_data_q;
    logic [31:0] write_strb_q;
    logic [4:0] read_lane_q;
    bus_rsp_t response_q;
    bus_error_e request_error;
    logic [DBUS_BYTES-1:0] allowed_strb;
    logic [4:0] word_lane;

    // IP 示例每个 256-bit beat 地址增加 8：地址单位是 32-bit 字，低 3 位为 beat 内偏移。
    // 本地 WDATA/WSTRB 已在 XLEN 字内按 byte lane 排列，仅移动到 32-byte beat 中的字位置。
    assign word_lane = request.addr[4:0] & 5'(~(DBUS_BYTES - 1));
    always_comb begin
        allowed_strb = DBUS_BYTES'(((1 << (1 << request.size)) - 1) <<
                                   request.addr[$clog2(DBUS_BYTES)-1:0]);
        request_error = BUS_OK;
        if (65'(request.addr) < 65'(DDR_BASE) ||
            65'(request.addr) >= (65'(DDR_BASE) + 65'(DDR_BYTES)))
            request_error = BUS_DECERR;
        else if ((request.addr & ((xlen_t'(1) << request.size) - 1)) != 0 ||
                 (request.size == MEM_DWORD && XLEN != 64) ||
                 (request.execute && (request.write || request.size != MEM_WORD)) ||
                 (request.write && ((request.wstrb & ~allowed_strb) != 0)))
            request_error = BUS_SLVERR;
    end

    assign req_ready = !rst && state_q == IDLE;
    assign rsp_valid = !rst && state_q == RESPONSE;
    assign response = response_q;
    assign axi_awvalid = !rst && state_q == WRITE_ADDR;
    assign axi_arvalid = !rst && state_q == READ_ADDR;
    assign axi_awaddr = ip_addr_q;
    assign axi_araddr = ip_addr_q;
    assign axi_wdata = write_data_q;
    assign axi_wstrb = write_strb_q;
    assign axi_awuser_ap = 1'b0;
    assign axi_aruser_ap = 1'b0;
    assign axi_awuser_id = '0;
    assign axi_aruser_id = '0;
    assign axi_awlen = '0;
    assign axi_arlen = '0;

    // 单笔在途，IP 没有标准 B 通道：写数据被 wready 接受后才向本地完成。
    // 读响应为无反压脉冲，必须寄存到本地响应被消费。
    always_ff @(posedge clk) begin
        if (rst) begin
            state_q <= IDLE;
            ip_addr_q <= '0;
            write_data_q <= '0;
            write_strb_q <= '0;
            read_lane_q <= '0;
            response_q <= '0;
        end else begin
            case (state_q)
                IDLE: if (req_valid && req_ready) begin
                    response_q <= '{rdata: '0, error: request_error};
                    if (request_error != BUS_OK) begin
                        state_q <= RESPONSE;
                    end else begin
                        ip_addr_q <= 28'((request.addr - xlen_t'(DDR_BASE)) >> 2) & 28'hffffff8;
                        read_lane_q <= word_lane;
                        write_data_q <= 256'(request.wdata) << (8 * word_lane);
                        write_strb_q <= 32'(request.wstrb) << word_lane;
                        state_q <= request.write ? WRITE_ADDR : READ_ADDR;
                    end
                end
                WRITE_ADDR: if (axi_awready) begin
                    if (axi_wready) begin
                        response_q <= '{rdata: '0, error: BUS_OK};
                        state_q <= RESPONSE;
                    end else state_q <= WRITE_DATA;
                end
                WRITE_DATA: if (axi_wready) begin
                    response_q <= '{rdata: '0, error: BUS_OK};
                    state_q <= RESPONSE;
                end
                READ_ADDR: if (axi_arready) begin
                    if (axi_rvalid) begin
                        response_q <= '{rdata: (axi_rid == 0 && axi_rlast ?
                                                xlen_t'(axi_rdata >> (8 * read_lane_q)) : '0),
                                        error: (axi_rid == 0 && axi_rlast ? BUS_OK : BUS_SLVERR)};
                        state_q <= RESPONSE;
                    end else state_q <= READ_DATA;
                end
                READ_DATA: if (axi_rvalid) begin
                    response_q <= '{rdata: (axi_rid == 0 && axi_rlast ?
                                            xlen_t'(axi_rdata >> (8 * read_lane_q)) : '0),
                                    error: (axi_rid == 0 && axi_rlast ? BUS_OK : BUS_SLVERR)};
                    state_q <= RESPONSE;
                end
                RESPONSE: if (rsp_ready) state_q <= IDLE;
                default: state_q <= IDLE;
            endcase
        end
    end
endmodule
