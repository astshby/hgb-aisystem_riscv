// Module: dcache_banked
// Description: Two disjoint line banks with dual CPU hit paths and shared scalar/block refill ownership.
module dcache_banked #(
    parameter bit ENABLE = 1,
    parameter int unsigned DDR_BYTES = 0,
    parameter int unsigned CACHE_BYTES = 4096,
    parameter int unsigned LINE_BYTES = 32,
    parameter bit BLOCK_ENABLE = 0
) (
    input logic clk, rst,
    input logic [1:0] req_valid,
    output logic [1:0] req_ready,
    input bus_types_pkg::bus_req_t request [2],
    output logic [1:0] rsp_valid,
    input logic [1:0] rsp_ready,
    output bus_types_pkg::bus_rsp_t response [2],
    input logic maint_req_valid,
    output logic maint_req_ready,
    input cache_pkg::cache_maint_op_e maint_op,
    output logic maint_rsp_valid,
    input logic maint_rsp_ready,
    output cache_pkg::cache_maint_error_e maint_error,
    output core_types_pkg::xlen_t maint_fault_addr,
    output logic fault_valid,
    output cache_pkg::cache_maint_error_e fault_code,
    output core_types_pkg::xlen_t fault_addr,
    output logic mem_req_valid,
    input logic mem_req_ready,
    output bus_types_pkg::bus_req_t mem_request,
    input logic mem_rsp_valid,
    output logic mem_rsp_ready,
    input bus_types_pkg::bus_rsp_t mem_response,
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
    import cache_pkg::*;
    import block_types_pkg::*;
    // 每半容量 bank 的索引之上的一位选择 bank：同一行唯一归属，两个 bank 合计原总容量。
    localparam int BANK_BIT = $clog2(CACHE_BYTES/4);
    logic [1:0] bank_busy_q, bank_locked_q, bank_owner_q, bank_next_q, selected, found;
    logic [1:0] b_req_valid, b_req_ready, b_rsp_valid, b_rsp_ready, request_fire, response_fire;
    bus_req_t b_request [2], c_request [2];
    bus_rsp_t b_response [2], c_response [2];
    logic [1:0] c_req_valid, c_req_ready, c_rsp_valid, c_rsp_ready;
    logic [1:0] c_rd_cmd_valid, c_rd_cmd_ready, c_rd_valid, c_rd_ready;
    logic [1:0] c_wr_cmd_valid, c_wr_cmd_ready, c_wr_valid, c_wr_ready, c_wr_rsp_valid, c_wr_rsp_ready;
    block_cmd_t c_rd_cmd [2], c_wr_cmd [2];
    block_r_t c_rd_data [2];
    block_w_t c_wr_data [2];
    block_b_t c_wr_rsp [2];
    logic maintenance_q;
    logic [1:0] maint_sent_q, maint_done_q, b_maint_req_valid, b_maint_req_ready;
    logic [1:0] b_maint_rsp_valid, b_maint_rsp_ready, b_fault_valid;
    cache_maint_op_e maint_op_q;
    cache_maint_error_e b_maint_error [2], saved_error_q [2], b_fault_code [2];
    xlen_t b_maint_addr [2], saved_addr_q [2], b_fault_addr [2];

    // 每个 bank 独立轮询；反压锁定展示项，响应归属保存到真正消费。
    always_comb begin
        selected = bank_owner_q; found = bank_locked_q;
        rsp_valid = 0; b_req_valid = 0; b_rsp_ready = 0;
        response[0] = '0; response[1] = '0;
        for (int b = 0; b < 2; b++) begin
            for (int offset = 0; offset < 2; offset++) begin
                if (!found[b] && req_valid[bank_next_q[b] ^ 1'(offset)] &&
                    request[bank_next_q[b] ^ 1'(offset)].addr[BANK_BIT] == 1'(b)) begin
                    found[b] = 1;
                    selected[b] = bank_next_q[b] ^ 1'(offset);
                end
            end
            b_request[b] = request[selected[b]];
            if (!rst && !bank_busy_q[b] && found[b] &&
                (bank_locked_q[b] || (!maintenance_q && !maint_req_valid))) begin
                b_req_valid[b] = req_valid[selected[b]];
            end
            if (!rst && bank_busy_q[b]) begin
                rsp_valid[bank_owner_q[b]] = b_rsp_valid[b];
                response[bank_owner_q[b]] = b_response[b];
                b_rsp_ready[b] = rsp_ready[bank_owner_q[b]];
            end
        end
    end
    for (genvar p = 0; p < 2; p++) begin : g_request_ready
        assign req_ready[p] = (b_req_valid[0] && selected[0] == 1'(p) && b_req_ready[0]) ||
                              (b_req_valid[1] && selected[1] == 1'(p) && b_req_ready[1]);
    end
    assign request_fire = b_req_valid & b_req_ready;
    assign response_fire = b_rsp_valid & b_rsp_ready;
    always_ff @(posedge clk) begin
        if (rst) begin bank_busy_q <= 0; bank_locked_q <= 0; bank_owner_q <= 0; bank_next_q <= 0; end
        else for (int b = 0; b < 2; b++) begin
            if (b_req_valid[b] && !b_req_ready[b]) begin bank_locked_q[b] <= 1; bank_owner_q[b] <= selected[b]; end
            if (request_fire[b]) begin
                bank_busy_q[b] <= 1; bank_locked_q[b] <= 0; bank_owner_q[b] <= selected[b];
            end else if (response_fire[b]) begin
                bank_busy_q[b] <= 0; bank_next_q[b] <= !bank_owner_q[b];
            end
        end
    end

    // 一个维护命令只向每个 bank 发送一次；两者均结束后才向系统控制器回复。
    assign maint_req_ready = !rst && !maintenance_q;
    assign maint_rsp_valid = maintenance_q && (&maint_done_q);
    assign maint_error = saved_error_q[0] != CACHE_OK ? saved_error_q[0] : saved_error_q[1];
    assign maint_fault_addr = saved_error_q[0] != CACHE_OK ? saved_addr_q[0] : saved_addr_q[1];
    assign b_maint_req_valid = {2{maintenance_q}} & ~maint_sent_q;
    assign b_maint_rsp_ready = {2{maintenance_q}} & ~maint_done_q;
    assign fault_valid = |b_fault_valid;
    assign fault_code = b_fault_valid[0] ? b_fault_code[0] : b_fault_code[1];
    assign fault_addr = b_fault_valid[0] ? b_fault_addr[0] : b_fault_addr[1];
    always_ff @(posedge clk) begin
        if (rst) begin
            maintenance_q <= 0; maint_sent_q <= 0; maint_done_q <= 0; maint_op_q <= CACHE_CLEAN;
            for (int b = 0; b < 2; b++) begin saved_error_q[b] <= CACHE_OK; saved_addr_q[b] <= 0; end
        end else begin
            if (maint_rsp_valid && maint_rsp_ready) maintenance_q <= 0;
            if (maint_req_valid && maint_req_ready) begin
                maintenance_q <= 1; maint_op_q <= maint_op; maint_sent_q <= 0; maint_done_q <= 0;
                for (int b = 0; b < 2; b++) begin saved_error_q[b] <= CACHE_OK; saved_addr_q[b] <= 0; end
            end
            for (int b = 0; b < 2; b++) begin
                if (b_maint_req_valid[b] && b_maint_req_ready[b]) maint_sent_q[b] <= 1;
                if (b_maint_rsp_valid[b] && b_maint_rsp_ready[b]) begin
                    maint_done_q[b] <= 1; saved_error_q[b] <= b_maint_error[b]; saved_addr_q[b] <= b_maint_addr[b];
                end
            end
        end
    end
    for (genvar b = 0; b < 2; b++) begin : g_bank
        dcache #(.ENABLE(ENABLE), .DDR_BYTES(DDR_BYTES), .CACHE_BYTES(CACHE_BYTES/2),
                 .LINE_BYTES(LINE_BYTES), .BLOCK_ENABLE(BLOCK_ENABLE)) u_cache (
            .clk, .rst, .req_valid(b_req_valid[b]), .req_ready(b_req_ready[b]), .request(b_request[b]),
            .rsp_valid(b_rsp_valid[b]), .rsp_ready(b_rsp_ready[b]), .response(b_response[b]),
            .maint_req_valid(b_maint_req_valid[b]), .maint_req_ready(b_maint_req_ready[b]), .maint_op(maint_op_q),
            .maint_rsp_valid(b_maint_rsp_valid[b]), .maint_rsp_ready(b_maint_rsp_ready[b]),
            .maint_error(b_maint_error[b]), .maint_fault_addr(b_maint_addr[b]),
            .fault_valid(b_fault_valid[b]), .fault_code(b_fault_code[b]), .fault_addr(b_fault_addr[b]),
            .mem_req_valid(c_req_valid[b]), .mem_req_ready(c_req_ready[b]), .mem_request(c_request[b]),
            .mem_rsp_valid(c_rsp_valid[b]), .mem_rsp_ready(c_rsp_ready[b]), .mem_response(c_response[b]),
            .rd_cmd_valid(c_rd_cmd_valid[b]), .rd_cmd_ready(c_rd_cmd_ready[b]), .rd_cmd(c_rd_cmd[b]),
            .rd_valid(c_rd_valid[b]), .rd_ready(c_rd_ready[b]), .rd_data(c_rd_data[b]),
            .wr_cmd_valid(c_wr_cmd_valid[b]), .wr_cmd_ready(c_wr_cmd_ready[b]), .wr_cmd(c_wr_cmd[b]),
            .wr_valid(c_wr_valid[b]), .wr_ready(c_wr_ready[b]), .wr_data(c_wr_data[b]),
            .wr_rsp_valid(c_wr_rsp_valid[b]), .wr_rsp_ready(c_wr_rsp_ready[b]), .wr_rsp(c_wr_rsp[b])
        );
    end
    bus_pair_arbiter u_scalar (
        .clk, .rst, .c_req_valid, .c_req_ready, .c_request, .c_rsp_valid, .c_rsp_ready, .c_response,
        .req_valid(mem_req_valid), .req_ready(mem_req_ready), .request(mem_request),
        .rsp_valid(mem_rsp_valid), .rsp_ready(mem_rsp_ready), .response(mem_response)
    );
    block_arbiter #(.CLIENTS(2)) u_block (.*);
`ifndef SYNTHESIS
    initial assert (CACHE_BYTES >= 8*LINE_BYTES && (CACHE_BYTES & (CACHE_BYTES-1)) == 0)
        else $fatal(1, "banked D-cache needs two power-of-two banks with at least two sets");
`endif
endmodule
