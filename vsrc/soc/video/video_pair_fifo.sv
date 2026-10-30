// Module: video_pair_fifo
// Description: Dual-clock 64-bit pixel pairs plus SOF/epoch tags, with synchronous BRAM read and an elastic output register.
module video_pair_fifo #(
    parameter int DEPTH = 2048,
    parameter int WIDTH = 73
) (
    input logic s_clk, s_rst, m_clk, m_rst,
    input logic in_valid,
    output logic in_ready,
    input logic [WIDTH-1:0] in_data,
    output logic out_valid,
    input logic out_ready,
    output logic [WIDTH-1:0] out_data
);
    localparam int AW=$clog2(DEPTH), PW=AW+1;
    logic [WIDTH-1:0] payload [DEPTH];
    logic [PW-1:0] write_q, read_q, write_next, read_next;
    (* syn_preserve=1, syn_allow_retiming=0 *) logic [PW-1:0] write_gray_q, read_gray_q;
    (* ASYNC_REG="TRUE", PAP_ASYNC_REG=1, syn_allow_retiming=0 *) logic [PW-1:0] read_sync1_q,read_sync2_q;
    (* ASYNC_REG="TRUE", PAP_ASYNC_REG=1, syn_allow_retiming=0 *) logic [PW-1:0] write_sync1_q,write_sync2_q;
    logic full_q,empty_q,in_fire,prefetch;
    assign in_ready=!s_rst && !full_q;
    assign in_fire=in_valid && in_ready;
    assign prefetch=!m_rst && (!out_valid || out_ready) && !empty_q;
    assign write_next=write_q+PW'(in_fire);
    assign read_next=read_q+PW'(prefetch);
    always_ff @(posedge s_clk or posedge s_rst) begin
        if (s_rst) begin
            write_q<='0; write_gray_q<='0; full_q<=0; read_sync1_q<='0; read_sync2_q<='0;
        end else begin
            read_sync1_q<=read_gray_q; read_sync2_q<=read_sync1_q;
            write_q<=write_next; write_gray_q<=(write_next>>1)^write_next;
            full_q<=(((write_next>>1)^write_next)==(read_sync2_q^(PW'(3)<<(PW-2))));
        end
    end
    always_ff @(posedge s_clk) if (in_fire) payload[write_q[AW-1:0]]<=in_data;
    always_ff @(posedge m_clk or posedge m_rst) begin
        if (m_rst) begin
            read_q<='0; read_gray_q<='0; empty_q<=1; out_valid<=0;
            write_sync1_q<='0; write_sync2_q<='0;
        end else begin
            write_sync1_q<=write_gray_q; write_sync2_q<=write_sync1_q;
            read_q<=read_next; read_gray_q<=(read_next>>1)^read_next;
            empty_q<=(((read_next>>1)^read_next)==write_sync2_q);
            if (out_ready) out_valid<=0;
            if (prefetch) out_valid<=1;
        end
    end
    // 预取已把RAM所有权交给本域输出寄存器，反压期间不再改变该载荷。
    always_ff @(posedge m_clk) if (prefetch) out_data<=payload[read_q[AW-1:0]];
`ifndef SYNTHESIS
    initial assert (DEPTH>=2048 && (DEPTH&(DEPTH-1))==0) else $fatal(1,"video FIFO depth");
    assert property (@(posedge m_clk) disable iff(m_rst) out_valid && !out_ready |=>
        m_rst || (out_valid && $stable(out_data)));
`endif
endmodule
