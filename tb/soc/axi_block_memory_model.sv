// Module: axi_block_memory_model
// Description: Simulation-only bounded AXI INCR memory with independent channels, byte strobes and per-beat faults.
module axi_block_memory_model #(
    parameter int unsigned BYTES = 64 * 1024,
    parameter int unsigned DATA_W = 256
) (
    input logic clk, rst,
    input logic [31:0] fault_read_addr, fault_write_addr,
    input logic awvalid,
    output logic awready,
    input logic awid,
    input logic [31:0] awaddr,
    input logic [7:0] awlen,
    input logic [2:0] awsize,
    input logic wvalid,
    output logic wready,
    input logic [DATA_W-1:0] wdata,
    input logic [DATA_W/8-1:0] wstrb,
    input logic wlast,
    output logic bvalid,
    input logic bready,
    output logic bid,
    output logic [1:0] bresp,
    input logic arvalid,
    output logic arready,
    input logic arid,
    input logic [31:0] araddr,
    input logic [7:0] arlen,
    input logic [2:0] arsize,
    output logic rvalid,
    input logic rready,
    output logic rid,
    output logic [DATA_W-1:0] rdata,
    output logic [1:0] rresp,
    output logic rlast
);
    import core_config_pkg::*;
    import soc_addr_pkg::*;
    localparam int unsigned DATA_BYTES = DATA_W / 8;
    localparam int unsigned MAX_BEATS = 4;
    // 保留XLEN数组与单一mem层级，原ELF/RT镜像加载代码可复用；两个方向访问同一份内存。
    logic [XLEN-1:0] mem [BYTES/DBUS_BYTES];
    logic [31:0] cycle_q, write_addr_q, read_addr_q;
    logic [7:0] write_len_q, read_len_q, read_count_q;
    logic [2:0] write_size_q, read_size_q, write_count_q;
    logic write_id_q, read_id_q, aw_seen_q, b_pending_q, r_pending_q;
    logic [2:0] b_delay_q, r_delay_q;
    logic [DATA_W-1:0] write_data_q [MAX_BEATS];
    logic [DATA_BYTES-1:0] write_strb_q [MAX_BEATS];
    logic write_last_q [MAX_BEATS];
    logic aw_fire, w_fire, ar_fire, r_fire;
    logic [31:0] read_beat_addr, read_base;
    logic write_bad;
    initial begin
        assert (DATA_W == 256) else $fatal(1, "block model requires 256-bit data");
        for (int i = 0; i < BYTES/DBUS_BYTES; i++) mem[i] = '0;
    end
    assign awready = !rst && !aw_seen_q && !b_pending_q && cycle_q[1:0] != 0;
    assign wready = !rst && write_count_q < 3'(MAX_BEATS) && !b_pending_q && cycle_q[1:0] != 1;
    assign arready = !rst && !r_pending_q && !rvalid && cycle_q[1:0] != 2;
    assign aw_fire = awvalid && awready;
    assign w_fire = wvalid && wready;
    assign ar_fire = arvalid && arready;
    assign r_fire = rvalid && rready;
    assign read_beat_addr = read_addr_q + (32'(read_count_q) << read_size_q);
    assign read_base = (read_beat_addr - DDR_BASE) & ~(32'(DATA_BYTES)-1);
    always_comb begin
        write_bad = 1'b0;
        for (int i = 0; i < MAX_BEATS; i++) begin
            if (i <= int'(write_len_q) &&
                ((write_addr_q + (32'(i) << write_size_q)) == fault_write_addr ||
                 write_last_q[i] != (i == int'(write_len_q)))) write_bad = 1'b1;
        end
    end

    // 所有驱动状态使用NBA；反压时R/B载荷不变，AW/W可不同顺序到达。
    always_ff @(posedge clk) begin
        if (rst) begin
            cycle_q <= '0;
            write_addr_q <= '0;
            read_addr_q <= '0;
            write_len_q <= '0;
            read_len_q <= '0;
            read_count_q <= '0;
            write_count_q <= '0;
            write_size_q <= '0;
            read_size_q <= '0;
            write_id_q <= 1'b0;
            read_id_q <= 1'b0;
            aw_seen_q <= 1'b0;
            b_pending_q <= 1'b0;
            r_pending_q <= 1'b0;
            b_delay_q <= '0;
            r_delay_q <= '0;
            bvalid <= 1'b0;
            bid <= 1'b0;
            bresp <= '0;
            rvalid <= 1'b0;
            rid <= 1'b0;
            rdata <= '0;
            rresp <= '0;
            rlast <= 1'b0;
            for (int i = 0; i < MAX_BEATS; i++) begin
                write_data_q[i] <= '0;
                write_strb_q[i] <= '0;
                write_last_q[i] <= 1'b0;
            end
        end else begin
            cycle_q <= cycle_q + 1'b1;
            if (aw_fire) begin
                assert (awlen < 8'(MAX_BEATS) && awsize <= 5 &&
                        33'(awaddr[11:0]) + ((33'(awlen)+1) << awsize) <= 4096 &&
                        awaddr >= DDR_BASE &&
                        33'(awaddr) + ((33'(awlen)+1) << awsize) <= 33'(DDR_BASE)+BYTES)
                    else $fatal(1, "invalid model AW addr=%h len=%0d size=%0d", awaddr, awlen, awsize);
                aw_seen_q <= 1'b1;
                write_addr_q <= awaddr;
                write_len_q <= awlen;
                write_size_q <= awsize;
                write_id_q <= awid;
            end
            if (w_fire) begin
                write_data_q[write_count_q[1:0]] <= wdata;
                write_strb_q[write_count_q[1:0]] <= wstrb;
                write_last_q[write_count_q[1:0]] <= wlast;
                write_count_q <= write_count_q + 1'b1;
            end
            if (aw_seen_q && write_count_q == 3'(write_len_q)+1'b1 && !b_pending_q) begin
                // 注入故障beat不写；其余beat仍可成功，B错误不能被解释成整段回滚。
                for (int i = 0; i < MAX_BEATS; i++) begin
                    for (int b = 0; b < DATA_BYTES; b++) begin
                        if (i <= int'(write_len_q) && write_strb_q[i][b] &&
                            write_addr_q + (32'(i) << write_size_q) != fault_write_addr)
                            mem[(((write_addr_q-DDR_BASE+(32'(i)<<write_size_q)) &
                                 ~(32'(DATA_BYTES)-1)) + 32'(b))/DBUS_BYTES][(b%DBUS_BYTES)*8 +: 8] <=
                                write_data_q[i][b*8 +: 8];
                    end
                end
                aw_seen_q <= 1'b0;
                write_count_q <= '0;
                b_pending_q <= 1'b1;
                b_delay_q <= 3'd3;
                bresp <= write_bad ? 2'b10 : 2'b00;
                bid <= write_id_q;
            end
            if (b_pending_q && !bvalid) begin
                if (b_delay_q != 0) b_delay_q <= b_delay_q - 1'b1;
                else bvalid <= 1'b1;
            end
            if (bvalid && bready) begin bvalid <= 1'b0; b_pending_q <= 1'b0; end
            if (ar_fire) begin
                assert (arlen < 8'(MAX_BEATS) && arsize <= 5 &&
                        33'(araddr[11:0]) + ((33'(arlen)+1) << arsize) <= 4096 &&
                        araddr >= DDR_BASE &&
                        33'(araddr) + ((33'(arlen)+1) << arsize) <= 33'(DDR_BASE)+BYTES)
                    else $fatal(1, "invalid model AR addr=%h len=%0d size=%0d", araddr, arlen, arsize);
                read_addr_q <= araddr;
                read_len_q <= arlen;
                read_size_q <= arsize;
                read_id_q <= arid;
                read_count_q <= '0;
                r_pending_q <= 1'b1;
                r_delay_q <= 3'd2;
            end
            if (r_pending_q && !rvalid) begin
                if (r_delay_q != 0) r_delay_q <= r_delay_q - 1'b1;
                else begin
                    rvalid <= 1'b1;
                    rid <= read_id_q;
                    rlast <= read_count_q == read_len_q;
                    rresp <= read_beat_addr == fault_read_addr ? 2'b10 : 2'b00;
                    for (int b = 0; b < DATA_BYTES; b++)
                        rdata[b*8 +: 8] <= read_base + 32'(b) < BYTES ?
                            mem[(read_base+32'(b))/DBUS_BYTES][(b%DBUS_BYTES)*8 +: 8] : 8'd0;
                end
            end
            if (r_fire) begin
                rvalid <= 1'b0;
                if (read_count_q == read_len_q) r_pending_q <= 1'b0;
                else begin
                    read_count_q <= read_count_q + 1'b1;
                    r_delay_q <= {1'b0, cycle_q[1:0]};
                end
            end
        end
    end
endmodule
