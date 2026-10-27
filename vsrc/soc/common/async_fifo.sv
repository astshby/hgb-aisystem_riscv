// Module: async_fifo
// Description: Dual-clock payload storage with Gray pointers and coordinated reset contract.
module async_fifo #(
    parameter int WIDTH = 32,
    parameter int DEPTH = 8
) (
    input logic s_clk, s_rst, m_clk, m_rst,
    input logic in_valid,
    output logic in_ready,
    input logic [WIDTH-1:0] in_data,
    output logic out_valid,
    input logic out_ready,
    output logic [WIDTH-1:0] out_data
);
    localparam int ADDR_W = $clog2(DEPTH);
    localparam int PTR_W = ADDR_W+1;
    logic [WIDTH-1:0] payload [DEPTH];
    logic [PTR_W-1:0] write_q, read_q, write_gray_q, read_gray_q;
    (* ASYNC_REG = "TRUE" *) logic [PTR_W-1:0] read_sync1_q, read_sync2_q;
    (* ASYNC_REG = "TRUE" *) logic [PTR_W-1:0] write_sync1_q, write_sync2_q;
    logic [PTR_W-1:0] write_next, read_next;
    logic full_q, empty_q, in_fire, out_fire;
    assign in_ready = !s_rst && !full_q;
    assign out_valid = !m_rst && !empty_q;
    assign in_fire = in_valid && in_ready;
    assign out_fire = out_valid && out_ready;
    assign write_next = write_q + PTR_W'(in_fire);
    assign read_next = read_q + PTR_W'(out_fire);
    assign out_data = payload[read_q[ADDR_W-1:0]];
    // 两侧复位必须来自同一个协调复位源。热复位丢弃所有在途，禁止单侧清指针。
    // 载荷仅在写握手时变化；Gray 指针同步后才允许读，不逐位同步数据总线。
    always_ff @(posedge s_clk or posedge s_rst) begin
        if (s_rst) begin
            write_q <= '0; write_gray_q <= '0; full_q <= 1'b0;
            read_sync1_q <= '0; read_sync2_q <= '0;
        end else begin
            read_sync1_q <= read_gray_q;
            read_sync2_q <= read_sync1_q;
            write_q <= write_next;
            write_gray_q <= (write_next >> 1) ^ write_next;
            full_q <= (((write_next >> 1) ^ write_next) ==
                       (read_sync2_q ^ (PTR_W'(3) << (PTR_W-2))));
        end
    end
    always_ff @(posedge s_clk) if (in_fire) payload[write_q[ADDR_W-1:0]] <= in_data;
    always_ff @(posedge m_clk or posedge m_rst) begin
        if (m_rst) begin
            read_q <= '0; read_gray_q <= '0; empty_q <= 1'b1;
            write_sync1_q <= '0; write_sync2_q <= '0;
        end else begin
            write_sync1_q <= write_gray_q;
            write_sync2_q <= write_sync1_q;
            read_q <= read_next;
            read_gray_q <= (read_next >> 1) ^ read_next;
            empty_q <= (((read_next >> 1) ^ read_next) == write_sync2_q);
        end
    end
`ifndef SYNTHESIS
    initial assert (DEPTH >= 2 && (DEPTH & (DEPTH-1)) == 0)
        else $fatal(1, "async_fifo requires power-of-two DEPTH >=2");
    assert property (@(posedge m_clk) disable iff (m_rst) out_valid && !out_ready |=>
                     m_rst || (out_valid && $stable(out_data)));
`endif
endmodule
