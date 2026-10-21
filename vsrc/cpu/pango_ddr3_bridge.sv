// Module: pango_ddr3_bridge
// Description: Single-outstanding 256-bit memory bridge to the PG2L200H DDR3 IP's native user port.
module pango_ddr3_bridge #(
    parameter int unsigned DDR_BYTES = 512 * 1024 * 1024
) (
    input logic clk, rst,
    input logic req_valid,
    output logic req_ready,
    input bus_types_pkg::ddr_req_t request,
    output logic rsp_valid,
    input logic rsp_ready,
    output bus_types_pkg::ddr_rsp_t response,
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
    ddr_rsp_t response_q;
    bus_error_e request_error;
    logic [31:0] allowed_strb;
    logic [64:0] access_end;
    logic read_bad_q;

    // IP 示例每个 256-bit beat 地址增加 8：地址单位是 32-bit 字，低 3 位为 beat 内偏移。
    // CPU 的 XLEN lane 转换由共用仲裁适配器完成；DMA 的 32 字节载荷原样到达用户口。
    // 此 IP 固定读整拍，但逻辑访问范围仍由 size 检查；DDR 是普通内存，不支持 MMIO。
    always_comb begin
        access_end = 65'(request.addr) + (65'd1 << request.size);
        allowed_strb = 32'(((65'd1 << (65'd1 << request.size)) - 1) << request.addr[4:0]);
        request_error = BUS_OK;
        if (65'(request.addr) < 65'(DDR_BASE) ||
            access_end > (65'(DDR_BASE) + 65'(DDR_BYTES)) || access_end > (65'd1 << 32))
            request_error = BUS_DECERR;
        else if (request.size > 5 || (65'(request.addr) & ((65'd1 << request.size) - 1)) != 0 ||
                 (request.execute && (request.write || request.size != 2)) ||
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
            response_q <= '0;
            read_bad_q <= 1'b0;
        end else begin
            case (state_q)
                IDLE: if (req_valid && req_ready) begin
                    read_bad_q <= 1'b0;
                    response_q <= '{rdata: '0, error: request_error};
                    if (request_error != BUS_OK) begin
                        state_q <= RESPONSE;
                    end else begin
                        ip_addr_q <= 28'((request.addr - xlen_t'(DDR_BASE)) >> 2) & 28'hffffff8;
                        write_data_q <= request.wdata;
                        write_strb_q <= request.wstrb;
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
                        if (!axi_rlast) begin
                            read_bad_q <= 1'b1;
                            state_q <= READ_DATA;
                        end else begin
                            response_q <= '{rdata: (axi_rid == 0 ? axi_rdata : '0),
                                            error: (axi_rid == 0 ? BUS_OK : BUS_SLVERR)};
                            state_q <= RESPONSE;
                        end
                    end else state_q <= READ_DATA;
                end
                READ_DATA: if (axi_rvalid) begin
                    // IP 无 RREADY，异常长帧仍必须等真实 RLAST；否则迟到 beat 会污染下一 owner。
                    if (!axi_rlast) read_bad_q <= 1'b1;
                    else begin
                        response_q <= '{rdata: (axi_rid == 0 && !read_bad_q ? axi_rdata : '0),
                                        error: (axi_rid == 0 && !read_bad_q ? BUS_OK : BUS_SLVERR)};
                        state_q <= RESPONSE;
                    end
                end
                RESPONSE: if (rsp_ready) state_q <= IDLE;
                default: state_q <= IDLE;
            endcase
        end
    end
endmodule
