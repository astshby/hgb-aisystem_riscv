// Module: ddr_block_adapter
// Description: Preserves single-beat DDR request semantics on independent block read and write channels.
module ddr_block_adapter #(
    parameter int unsigned DDR_BYTES = 64 * 1024
) (
    input logic clk, rst,
    input logic req_valid,
    output logic req_ready,
    input bus_types_pkg::ddr_req_t request,
    output logic rsp_valid,
    input logic rsp_ready,
    output bus_types_pkg::ddr_rsp_t response,
    output logic rd_cmd_valid,
    input logic rd_cmd_ready,
    output block_types_pkg::block_cmd_t rd_cmd,
    input logic rd_valid,
    output logic rd_ready,
    input block_types_pkg::block_r_t rd_data,
    output logic wr_cmd_valid,
    input logic wr_cmd_ready,
    output block_types_pkg::block_cmd_t wr_cmd,
    output logic wr_valid,
    input logic wr_ready,
    output block_types_pkg::block_w_t wr_data,
    input logic wr_rsp_valid,
    output logic wr_rsp_ready,
    input block_types_pkg::block_b_t wr_rsp
);
    import core_types_pkg::*;
    import bus_types_pkg::*;
    import block_types_pkg::*;
    import soc_addr_pkg::*;
    typedef enum logic [2:0] {IDLE, READ_COMMAND, READ_DATA, WRITE_COMMAND,
        WRITE_DATA, WRITE_RESPONSE, RESPONSE} state_e;
    state_e state_q;
    ddr_req_t request_q;
    ddr_rsp_t response_q;
    bus_error_e request_error;
    logic [64:0] access_end;
    logic [31:0] allowed_strb;
    logic read_extra_q;

    // 原窄访问与已验证的Cache行命令分开：不能借行接口放宽取指大小、写权限或地址高位。
    always_comb begin
        access_end = 65'(request.addr) + (65'd1 << request.size);
        allowed_strb = 32'(((65'd1 << (65'd1 << request.size))-1) << request.addr[4:0]);
        request_error = BUS_OK;
        if (65'(request.addr) < 65'(DDR_BASE) ||
            access_end > 65'(DDR_BASE) + 65'(DDR_BYTES) || access_end > (65'd1 << 32))
            request_error = BUS_DECERR;
        else if (request.size > 5 || (65'(request.addr) & ((65'd1 << request.size)-1)) != 0 ||
                 (request.execute && (request.write || request.size != 2)) ||
                 (request.write && (request.wstrb & ~allowed_strb) != 0))
            request_error = BUS_SLVERR;
    end
    assign req_ready = !rst && state_q == IDLE;
    assign rsp_valid = !rst && state_q == RESPONSE;
    assign response = response_q;
    assign rd_cmd_valid = !rst && state_q == READ_COMMAND;
    assign wr_cmd_valid = !rst && state_q == WRITE_COMMAND;
    assign rd_cmd = '{addr:request_q.addr, len:8'd0, size:request_q.size, execute:request_q.execute};
    assign wr_cmd = rd_cmd;
    assign rd_ready = !rst && state_q == READ_DATA;
    assign wr_valid = !rst && state_q == WRITE_DATA;
    assign wr_data = '{data:request_q.wdata, strb:request_q.wstrb, last:1'b1};
    assign wr_rsp_ready = !rst && state_q == WRITE_RESPONSE;

    // 接受后只使用请求快照；完成反压不能重复读写，异常长读帧必须排空到真正last。
    always_ff @(posedge clk) begin
        if (rst) begin
            state_q <= IDLE;
            request_q <= '0;
            response_q <= '0;
            read_extra_q <= 1'b0;
        end else begin
            case (state_q)
                IDLE: if (req_valid && req_ready) begin
                    request_q <= request;
                    response_q <= '{rdata:'0, error:request_error};
                    read_extra_q <= 1'b0;
                    if (request_error != BUS_OK) state_q <= RESPONSE;
                    else state_q <= request.write ? WRITE_COMMAND : READ_COMMAND;
                end
                READ_COMMAND: if (rd_cmd_ready) state_q <= READ_DATA;
                READ_DATA: if (rd_valid && rd_ready) begin
                    if (!rd_data.last) read_extra_q <= 1'b1;
                    else begin
                        response_q <= '{rdata:rd_data.data,
                            error:read_extra_q ? BUS_SLVERR : rd_data.error};
                        state_q <= RESPONSE;
                    end
                end
                WRITE_COMMAND: if (wr_cmd_ready) state_q <= WRITE_DATA;
                WRITE_DATA: if (wr_valid && wr_ready) state_q <= WRITE_RESPONSE;
                WRITE_RESPONSE: if (wr_rsp_valid && wr_rsp_ready) begin
                    response_q <= '{rdata:'0, error:wr_rsp.error};
                    state_q <= RESPONSE;
                end
                RESPONSE: if (rsp_ready) state_q <= IDLE;
                default: state_q <= IDLE;
            endcase
        end
    end
endmodule
