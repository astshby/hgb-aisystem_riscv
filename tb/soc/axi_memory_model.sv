// Module: axi_memory_model
// Description: Simulation-only single-beat external RAM with channel stalls and fault injection.
module axi_memory_model #(
    parameter int unsigned BYTES = 64 * 1024
) (
    input logic clk, rst,
    input logic [31:0] fault_read_addr, fault_write_addr,
    input logic awvalid,
    output logic awready,
    input logic [31:0] awaddr,
    input logic [2:0] awsize,
    input logic wvalid,
    output logic wready,
    input logic [core_config_pkg::XLEN-1:0] wdata,
    input logic [core_config_pkg::DBUS_BYTES-1:0] wstrb,
    input logic wlast,
    output logic bvalid,
    input logic bready,
    output logic bid,
    output logic [1:0] bresp,
    input logic arvalid,
    output logic arready,
    input logic [31:0] araddr,
    input logic [2:0] arsize,
    output logic rvalid,
    input logic rready,
    output logic rid,
    output logic [core_config_pkg::XLEN-1:0] rdata,
    output logic [1:0] rresp,
    output logic rlast
);
    import core_config_pkg::*;
    import soc_addr_pkg::*;
    localparam int WORDS = BYTES / DBUS_BYTES;
    logic [XLEN-1:0] mem [WORDS];
    logic [31:0] cycle_q, awaddr_q;
    logic [XLEN-1:0] wdata_q;
    logic [DBUS_BYTES-1:0] wstrb_q;
    logic aw_seen_q, w_seen_q, b_pending_q, r_pending_q;
    logic [2:0] b_delay_q, r_delay_q;
    logic [31:0] accepted_awaddr;
    logic [XLEN-1:0] accepted_wdata;
    logic [DBUS_BYTES-1:0] accepted_wstrb;
    logic aw_fire, w_fire, ar_fire;
    initial for (int w = 0; w < WORDS; w++) mem[w] = '0;

    // 不同通道独立反压；请求后固定若干拍才回响应，不伪装真实 DDR3 控制器时序。
    assign awready = !rst && !aw_seen_q && !b_pending_q && cycle_q[1:0] != 0;
    assign wready = !rst && !w_seen_q && !b_pending_q && cycle_q[1:0] != 1;
    assign arready = !rst && !r_pending_q && cycle_q[1:0] != 2;
    assign aw_fire = awvalid && awready;
    assign w_fire = wvalid && wready;
    assign ar_fire = arvalid && arready;
    assign accepted_awaddr = aw_fire ? awaddr : awaddr_q;
    assign accepted_wdata = w_fire ? wdata : wdata_q;
    assign accepted_wstrb = w_fire ? wstrb : wstrb_q;
    assign bid = 1'b0;
    assign rid = 1'b0;
    assign rlast = 1'b1;

    // 写副作用只发生一次，在 AW、W 都已接受后；B/R 有效时保持到对应 ready。
    always_ff @(posedge clk) begin
        if (rst) begin
            cycle_q <= '0;
            awaddr_q <= '0;
            wdata_q <= '0;
            wstrb_q <= '0;
            aw_seen_q <= 1'b0;
            w_seen_q <= 1'b0;
            b_pending_q <= 1'b0;
            r_pending_q <= 1'b0;
            b_delay_q <= '0;
            r_delay_q <= '0;
            bvalid <= 1'b0;
            bresp <= '0;
            rvalid <= 1'b0;
            rdata <= '0;
            rresp <= '0;
        end else begin
            cycle_q <= cycle_q + 32'd1;
            if (aw_fire) begin
                aw_seen_q <= 1'b1;
                awaddr_q <= awaddr;
            end
            if (w_fire) begin
                w_seen_q <= 1'b1;
                wdata_q <= wdata;
                wstrb_q <= wstrb;
            end
            if (!b_pending_q && (aw_seen_q || aw_fire) && (w_seen_q || w_fire)) begin
                aw_seen_q <= 1'b0;
                w_seen_q <= 1'b0;
                b_pending_q <= 1'b1;
                b_delay_q <= 3;
                bresp <= accepted_awaddr == fault_write_addr ? 2'b10 : 2'b00;
                if (accepted_awaddr >= DDR_BASE &&
                    33'(accepted_awaddr) < 33'(DDR_BASE) + BYTES &&
                    accepted_awaddr != fault_write_addr) begin
                    for (int b = 0; b < DBUS_BYTES; b++)
                        if (accepted_wstrb[b])
                            mem[(accepted_awaddr-DDR_BASE) / DBUS_BYTES][b*8 +: 8] <=
                                accepted_wdata[b*8 +: 8];
                end else bresp <= 2'b10;
            end
            if (b_pending_q && !bvalid) begin
                if (b_delay_q != 0) b_delay_q <= b_delay_q - 3'd1;
                else bvalid <= 1'b1;
            end
            if (bvalid && bready) begin
                bvalid <= 1'b0;
                b_pending_q <= 1'b0;
            end
            if (ar_fire) begin
                r_pending_q <= 1'b1;
                r_delay_q <= 3;
                rresp <= araddr == fault_read_addr ? 2'b10 : 2'b00;
                rdata <= '0;
                if (araddr >= DDR_BASE && 33'(araddr) < 33'(DDR_BASE) + BYTES &&
                    araddr != fault_read_addr)
                    rdata <= mem[(araddr-DDR_BASE) / DBUS_BYTES];
                else rresp <= 2'b10;
            end
            if (r_pending_q && !rvalid) begin
                if (r_delay_q != 0) r_delay_q <= r_delay_q - 3'd1;
                else rvalid <= 1'b1;
            end
            if (rvalid && rready) begin
                rvalid <= 1'b0;
                r_pending_q <= 1'b0;
            end
        end
    end
    logic unused_size;
    assign unused_size = ^{awsize, arsize, wlast};
endmodule
