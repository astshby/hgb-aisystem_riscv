// Module: block_arbiter
// Description: Independent round-robin read/write block ownership with locked offers and non-interleaved W data.
module block_arbiter #(
    parameter int unsigned CLIENTS = 4,
    parameter int unsigned OWNER_W = $clog2(CLIENTS)
) (
    input logic clk, rst,
    input logic [CLIENTS-1:0] c_rd_cmd_valid,
    output logic [CLIENTS-1:0] c_rd_cmd_ready,
    input block_types_pkg::block_cmd_t c_rd_cmd [CLIENTS],
    output logic [CLIENTS-1:0] c_rd_valid,
    input logic [CLIENTS-1:0] c_rd_ready,
    output block_types_pkg::block_r_t c_rd_data [CLIENTS],
    input logic [CLIENTS-1:0] c_wr_cmd_valid,
    output logic [CLIENTS-1:0] c_wr_cmd_ready,
    input block_types_pkg::block_cmd_t c_wr_cmd [CLIENTS],
    input logic [CLIENTS-1:0] c_wr_valid,
    output logic [CLIENTS-1:0] c_wr_ready,
    input block_types_pkg::block_w_t c_wr_data [CLIENTS],
    output logic [CLIENTS-1:0] c_wr_rsp_valid,
    input logic [CLIENTS-1:0] c_wr_rsp_ready,
    output block_types_pkg::block_b_t c_wr_rsp [CLIENTS],
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
    import block_types_pkg::*;
    logic rd_busy_q, wr_busy_q, rd_locked_q, wr_locked_q;
    logic [OWNER_W-1:0] rd_owner_q, wr_owner_q, rd_next_q, wr_next_q;
    logic [OWNER_W-1:0] rd_selected, wr_selected;
    logic rd_found, wr_found;
    logic rd_cmd_fire, rd_fire, wr_cmd_fire, wr_rsp_fire;

    // 每方向独立选择年龄无关的client；反压锁定展示项，后到请求不能更换其载荷。
    always_comb begin
        rd_selected = rd_owner_q;
        wr_selected = wr_owner_q;
        rd_found = rd_locked_q;
        wr_found = wr_locked_q;
        for (int offset = 0; offset < CLIENTS; offset++) begin
            if (!rd_found && c_rd_cmd_valid[(int'(rd_next_q)+offset)%CLIENTS]) begin
                rd_selected = OWNER_W'((int'(rd_next_q)+offset)%CLIENTS);
                rd_found = 1'b1;
            end
            if (!wr_found && c_wr_cmd_valid[(int'(wr_next_q)+offset)%CLIENTS]) begin
                wr_selected = OWNER_W'((int'(wr_next_q)+offset)%CLIENTS);
                wr_found = 1'b1;
            end
        end
    end

    // 读数据归属直到last握手；写归属直到完成握手，不在最后W后过早释放owner。
    always_comb begin
        c_rd_cmd_ready = '0;
        c_rd_valid = '0;
        c_wr_cmd_ready = '0;
        c_wr_ready = '0;
        c_wr_rsp_valid = '0;
        for (int client = 0; client < CLIENTS; client++) begin
            c_rd_data[client] = rd_data;
            c_wr_rsp[client] = wr_rsp;
        end
        rd_cmd = c_rd_cmd[rd_selected];
        wr_cmd = c_wr_cmd[wr_selected];
        rd_cmd_valid = !rst && !rd_busy_q && rd_found && c_rd_cmd_valid[rd_selected];
        wr_cmd_valid = !rst && !wr_busy_q && wr_found && c_wr_cmd_valid[wr_selected];
        rd_ready = 1'b0;
        wr_valid = 1'b0;
        wr_data = c_wr_data[wr_owner_q];
        wr_rsp_ready = 1'b0;
        if (!rst) begin
            if (!rd_busy_q && rd_found) c_rd_cmd_ready[rd_selected] = rd_cmd_ready;
            if (!wr_busy_q && wr_found) c_wr_cmd_ready[wr_selected] = wr_cmd_ready;
            if (rd_busy_q) begin
                c_rd_valid[rd_owner_q] = rd_valid;
                rd_ready = c_rd_ready[rd_owner_q];
            end
            if (wr_busy_q) begin
                wr_valid = c_wr_valid[wr_owner_q];
                c_wr_ready[wr_owner_q] = wr_ready;
                c_wr_rsp_valid[wr_owner_q] = wr_rsp_valid;
                wr_rsp_ready = c_wr_rsp_ready[wr_owner_q];
            end
        end
    end
    assign rd_cmd_fire = rd_cmd_valid && rd_cmd_ready;
    assign rd_fire = rd_valid && rd_ready;
    assign wr_cmd_fire = wr_cmd_valid && wr_cmd_ready;
    assign wr_rsp_fire = wr_rsp_valid && wr_rsp_ready;

    // 轮询指针按整块完成推进；从端或client永久反压时不宣称固定等待上界。
    always_ff @(posedge clk) begin
        if (rst) begin
            rd_busy_q <= 1'b0;
            wr_busy_q <= 1'b0;
            rd_locked_q <= 1'b0;
            wr_locked_q <= 1'b0;
            rd_owner_q <= '0;
            wr_owner_q <= '0;
            rd_next_q <= '0;
            wr_next_q <= '0;
        end else begin
            if (rd_cmd_valid && !rd_cmd_ready) begin
                rd_locked_q <= 1'b1;
                rd_owner_q <= rd_selected;
            end
            if (wr_cmd_valid && !wr_cmd_ready) begin
                wr_locked_q <= 1'b1;
                wr_owner_q <= wr_selected;
            end
            if (rd_cmd_fire) begin
                rd_busy_q <= 1'b1;
                rd_locked_q <= 1'b0;
                rd_owner_q <= rd_selected;
            end else if (rd_fire && rd_data.last) begin
                rd_busy_q <= 1'b0;
                rd_next_q <= rd_owner_q == OWNER_W'(CLIENTS-1) ? '0 : rd_owner_q + OWNER_W'(1);
            end
            if (wr_cmd_fire) begin
                wr_busy_q <= 1'b1;
                wr_locked_q <= 1'b0;
                wr_owner_q <= wr_selected;
            end else if (wr_rsp_fire) begin
                wr_busy_q <= 1'b0;
                wr_next_q <= wr_owner_q == OWNER_W'(CLIENTS-1) ? '0 : wr_owner_q + OWNER_W'(1);
            end
        end
    end
`ifndef SYNTHESIS
    initial assert (CLIENTS >= 2 && OWNER_W >= $clog2(CLIENTS))
        else $fatal(1, "block_arbiter requires at least two representable clients");
`endif
endmodule
