// Module: tb_pango_block_bridge
// Description: Native DDR pulse model checking bounded buffering, same-edge responses, split addresses and independent owners.
module tb_pango_block_bridge;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import bus_types_pkg::*;
    import block_types_pkg::*;
    localparam int BYTES = 8192;
    localparam xlen_t BASE = xlen_t'(32'h80000000);
    logic clk = 0, rst = 1;
    always #5 clk = ~clk;
    logic rd_cmd_valid = 0, rd_cmd_ready, rd_valid, rd_ready = 0;
    block_cmd_t rd_cmd = '0;
    block_r_t rd_data;
    logic wr_cmd_valid = 0, wr_cmd_ready, wr_valid = 0, wr_ready, wr_rsp_valid, wr_rsp_ready = 0;
    block_cmd_t wr_cmd = '0;
    block_w_t wr_data = '0;
    block_b_t wr_rsp;
    logic [27:0] axi_awaddr, axi_araddr;
    logic axi_awuser_ap, axi_aruser_ap, axi_awvalid, axi_arvalid, axi_awready, axi_arready, axi_wready;
    logic [3:0] axi_awuser_id, axi_awlen, axi_aruser_id, axi_arlen, axi_rid;
    logic [255:0] axi_wdata, axi_rdata;
    logic [31:0] axi_wstrb;
    logic axi_rlast, axi_rvalid;
    byte unsigned memory [BYTES], expected [BYTES];
    int checks = 0, cycle_q = 0, ar_count = 0, aw_count = 0, overlaps = 0;
    int immediate_reads = 0, immediate_writes = 0, sequence_number = 0;
    logic read_pending_q = 0, write_pending_q = 0, immediate = 0, pause_read = 0;
    int read_left_q = 0, write_left_q = 0, read_delay_q = 0, read_index_q = 0;
    int read_addr_q = 0, write_addr_q = 0, read_address, write_address, actual_read_beats;
    int malformed = 0;
    logic ar_fire, aw_fire, read_pulse, write_pulse;
    pango_block_bridge #(.DDR_BYTES(BYTES)) dut (.*);
    assign axi_arready = !rst && !read_pending_q && cycle_q%4 != 2;
    assign axi_awready = !rst && !write_pending_q && cycle_q%4 != 0;
    assign ar_fire = axi_arvalid && axi_arready;
    assign aw_fire = axi_awvalid && axi_awready;
    assign axi_rvalid = !rst && !pause_read && ((read_pending_q && read_delay_q == 0) || (immediate && ar_fire));
    assign axi_wready = !rst && (write_pending_q || aw_fire) && (immediate || cycle_q%3 != 1);
    assign read_pulse = axi_rvalid;
    assign write_pulse = axi_wready;
    always_comb begin
        actual_read_beats = malformed == 1 ? 1 : int'(axi_arlen)+1+(malformed == 2 ? 2 : 0);
        read_address = read_pending_q ? read_addr_q : int'(axi_araddr)*4;
        write_address = write_pending_q ? write_addr_q : int'(axi_awaddr)*4;
        axi_rlast = read_pending_q ? read_left_q == 1 : actual_read_beats == 1;
        axi_rid = malformed == 3 && read_index_q == 1 ? 4'd1 : 4'd0;
        for (int b = 0; b < 32; b++)
            axi_rdata[b*8 +: 8] = read_address+b < BYTES ? memory[read_address+b] : 8'd0;
    end

    // 原生接口没有RREADY/WVALID：模型发脉冲后不会重发，写数据只在WREADY沿消费一次。
    // 模型状态用NBA，激励在下降沿改变；独立字节数组提供读写真值。
    always_ff @(posedge clk) begin
        if (rst) begin
            cycle_q <= 0; read_pending_q <= 0; write_pending_q <= 0;
            read_left_q <= 0; write_left_q <= 0; read_delay_q <= 0; read_index_q <= 0;
            read_addr_q <= 0; write_addr_q <= 0;
            ar_count <= 0; aw_count <= 0; overlaps <= 0;
            immediate_reads <= 0; immediate_writes <= 0;
        end else begin
            cycle_q <= cycle_q + 1;
            if (ar_fire) begin
                assert (axi_aruser_id == 0 && !axi_aruser_ap && axi_araddr[2:0] == 0 &&
                        int'(axi_araddr[9:0])*4 + (int'(axi_arlen)+1)*32 <= 4096)
                    else $fatal(1, "bad native AR address/length");
                ar_count <= ar_count + 1;
                read_pending_q <= 1;
                read_addr_q <= int'(axi_araddr)*4;
                read_left_q <= actual_read_beats;
                read_index_q <= 0;
                read_delay_q <= 3;
            end
            if (read_pending_q && read_delay_q != 0) read_delay_q <= read_delay_q-1;
            if (read_pulse) begin
                if (ar_fire) immediate_reads <= immediate_reads + 1;
                if (axi_rlast) read_pending_q <= 0;
                else begin
                    read_pending_q <= 1;
                    read_addr_q <= read_address + 32;
                    read_left_q <= (read_pending_q ? read_left_q : actual_read_beats)-1;
                    read_index_q <= read_pending_q ? read_index_q+1 : 1;
                    read_delay_q <= immediate ? 0 : cycle_q%3;
                end
            end
            if (aw_fire) begin
                assert (axi_awuser_id == 0 && !axi_awuser_ap && axi_awaddr[2:0] == 0 &&
                        int'(axi_awaddr[9:0])*4 + (int'(axi_awlen)+1)*32 <= 4096)
                    else $fatal(1, "bad native AW address/length");
                aw_count <= aw_count + 1;
                write_pending_q <= 1;
                write_addr_q <= int'(axi_awaddr)*4;
                write_left_q <= int'(axi_awlen)+1;
            end
            if (write_pulse) begin
                if (aw_fire) immediate_writes <= immediate_writes + 1;
                for (int b = 0; b < 32; b++) if (axi_wstrb[b]) memory[write_address+b] <= axi_wdata[b*8 +: 8];
                if ((write_pending_q ? write_left_q : int'(axi_awlen)+1) == 1) write_pending_q <= 0;
                else begin
                    write_pending_q <= 1;
                    write_addr_q <= write_address + 32;
                    write_left_q <= (write_pending_q ? write_left_q : int'(axi_awlen)+1)-1;
                end
            end
            if (read_pending_q && write_pending_q) overlaps <= overlaps+1;
        end
    end
    logic held_ar = 0, held_aw = 0, held_rd = 0, held_b = 0;
    logic [31:0] saved_ar, saved_aw;
    block_r_t saved_rd;
    block_b_t saved_b;
    always_ff @(posedge clk) begin
        if (rst) begin held_ar <= 0; held_aw <= 0; held_rd <= 0; held_b <= 0; end
        else begin
            if (held_ar) assert (axi_arvalid && {axi_araddr, axi_arlen} == saved_ar) else $fatal(1, "native AR changed");
            if (held_aw) assert (axi_awvalid && {axi_awaddr, axi_awlen} == saved_aw) else $fatal(1, "native AW changed");
            if (held_rd) assert (rd_valid && rd_data == saved_rd) else $fatal(1, "native read response changed");
            if (held_b) assert (wr_rsp_valid && wr_rsp == saved_b) else $fatal(1, "native write response changed");
            held_ar <= axi_arvalid && !axi_arready; saved_ar <= {axi_araddr, axi_arlen};
            held_aw <= axi_awvalid && !axi_awready; saved_aw <= {axi_awaddr, axi_awlen};
            held_rd <= rd_valid && !rd_ready; saved_rd <= rd_data;
            held_b <= wr_rsp_valid && !wr_rsp_ready; saved_b <= wr_rsp;
        end
    end
    task automatic tick;
        @(posedge clk); @(negedge clk);
    endtask
    task automatic read_case(input xlen_t address, input int beats, input int size,
                             input bus_error_e error = BUS_OK, input bit execute = 0);
        int count, index;
        bus_error_e expected_error;
        count = beats > 4 ? 1 : beats;
        @(negedge clk); rd_cmd = '{addr:address, len:8'(beats-1), size:3'(size), execute:execute}; rd_cmd_valid = 1;
        do @(posedge clk); while (!rd_cmd_ready);
        @(negedge clk); rd_cmd_valid = 0; rd_cmd = '1;
        for (int i = 0; i < count; i++) begin
            while (!rd_valid) @(negedge clk);
            repeat (4) begin
                assert (!rd_cmd_ready) else $fatal(1, "native read owner released early");
                tick();
            end
            expected_error = malformed == 1 || malformed == 2 || (malformed == 3 && i == 1) ? BUS_SLVERR : error;
            assert (rd_data.last == (i == count-1) && rd_data.error == expected_error)
                else $fatal(1, "native read framing error beat=%0d got=%0d expected=%0d", i, rd_data.error, expected_error);
            if (expected_error == BUS_OK) begin
                index = int'(address-BASE+(xlen_t'(i)<<size)) & ~31;
                for (int b = 0; b < 32; b++) assert (rd_data.data[b*8 +: 8] == expected[index+b])
                    else $fatal(1, "native read data mismatch index=%0d", index+b);
            end
            rd_ready = 1; tick(); rd_ready = 0;
        end
        assert (!rd_valid && rd_cmd_ready) else $fatal(1, "duplicate native read");
        checks++;
    endtask
    task automatic write_case(input xlen_t address, input int beats, input int size,
                              input bus_error_e error = BUS_OK, input bit partial = 0, input bit bad_last = 0,
                              input bit bad_mask = 0, input bit execute = 0);
        int count, index, salt;
        logic [31:0] mask;
        logic [255:0] payload;
        count = beats > 4 ? 1 : beats;
        salt = sequence_number; sequence_number++;
        @(negedge clk); wr_cmd = '{addr:address, len:8'(beats-1), size:3'(size), execute:execute}; wr_cmd_valid = 1;
        do @(posedge clk); while (!wr_cmd_ready);
        @(negedge clk); wr_cmd_valid = 0; wr_cmd = '1;
        for (int i = 0; i < count; i++) begin
            assert (!axi_awvalid) else $fatal(1, "native write command before entire block was buffered");
            mask = 32'(((65'd1 << (1 << size))-1) << ((address+(xlen_t'(i)<<size)) & 31));
            if (partial) mask &= 32'h5aa55aa5;
            if (bad_mask) mask = '1;
            for (int b = 0; b < 32; b++) payload[b*8 +: 8] = 8'(salt*13+i*31+b*7);
            wr_data = '{data:payload, strb:mask, last:((i == count-1) ^ bad_last)}; wr_valid = 1;
            do @(posedge clk); while (!wr_ready);
            @(negedge clk); wr_valid = 0; wr_data = '1;
            if (error == BUS_OK) begin
                index = int'(address-BASE+(xlen_t'(i)<<size)) & ~31;
                for (int b = 0; b < 32; b++) if (mask[b]) expected[index+b] = payload[b*8 +: 8];
            end
            if (i != count-1) repeat (2) tick();
        end
        while (!wr_rsp_valid) @(negedge clk);
        repeat (4) begin
            assert (!wr_cmd_ready) else $fatal(1, "native write owner released early");
            tick();
        end
        assert (wr_rsp.error == error) else $fatal(1, "native write error got=%0d expected=%0d", wr_rsp.error, error);
        wr_rsp_ready = 1; tick(); wr_rsp_ready = 0;
        checks++;
    endtask
    task automatic coordinated_reset;
        @(negedge clk); rst = 1; rd_cmd_valid = 0; wr_cmd_valid = 0;
        wr_valid = 0; rd_ready = 0; wr_rsp_ready = 0;
        repeat (3) tick(); rst = 0; tick();
        assert (!rd_valid && !wr_rsp_valid && rd_cmd_ready && wr_cmd_ready) else $fatal(1, "native reset retained owner");
        checks++;
    endtask
    initial begin
        int before_ar, before_aw;
        repeat (4) @(posedge clk);
        @(negedge clk);
        for (int i = 0; i < BYTES; i++) begin expected[i] = 8'(i*17+3); memory[i] = expected[i]; end
        rst = 0;
        for (int beats = 1; beats <= 4; beats++) begin
            write_case(BASE+xlen_t'(beats*128), beats, 5, BUS_OK, beats == 3);
            read_case(BASE+xlen_t'(beats*128), beats, 5, BUS_OK, 1);
        end
        for (int size = 0; size <= 5; size++)
            for (int lane = 0; lane < 32; lane += 1 << size) begin
                write_case(BASE+1024+xlen_t'(lane), 1, size);
                read_case(BASE+1024+xlen_t'(lane), 1, size);
            end
        before_aw = aw_count; before_ar = ar_count;
        write_case(BASE+4064, 4, 5); read_case(BASE+4064, 4, 5);
        assert (aw_count-before_aw == 2 && ar_count-before_ar == 2) else $fatal(1, "native split missing");
        before_ar = ar_count; before_aw = aw_count;
        read_case(BASE+1, 4, 5, BUS_SLVERR);
        read_case(BASE+8160, 4, 5, BUS_DECERR);
        read_case(BASE, 5, 5, BUS_SLVERR);
        read_case(BASE, 2, 2, BUS_SLVERR);
        read_case(BASE, 1, 6, BUS_SLVERR);
        read_case(BASE, 1, 0, BUS_SLVERR, 1);
        write_case(BASE+1, 4, 5, BUS_SLVERR);
        write_case(BASE, 4, 5, BUS_SLVERR, 0, 1);
        write_case(BASE, 5, 5, BUS_SLVERR);
        write_case(BASE+8160, 4, 5, BUS_DECERR);
        write_case(BASE+7, 1, 0, BUS_SLVERR, 0, 0, 1);
        write_case(BASE, 4, 5, BUS_SLVERR, 0, 0, 0, 1);
        if (XLEN == 64) read_case(BASE | (xlen_t'(1)<<32), 4, 5, BUS_DECERR);
        assert (ar_count == before_ar && aw_count == before_aw) else $fatal(1, "invalid native command escaped");
        // 先建立读owner，等完整写块到IP后才返回读数据，保证真实跨方向在途重叠。
        pause_read = 1;
        fork
            write_case(BASE+6144, 4, 5);
            read_case(BASE+6400, 4, 5);
            begin
                do @(posedge clk); while (!aw_fire);
                @(negedge clk); pause_read = 0;
            end
        join
        assert (overlaps > 0) else $fatal(1, "native read/write overlap missing");
        immediate = 1;
        write_case(BASE+2048, 1, 5); read_case(BASE+2048, 1, 5);
        write_case(BASE+2176, 4, 5); read_case(BASE+2176, 4, 5);
        assert (immediate_reads >= 2 && immediate_writes >= 2) else $fatal(1, "same-edge native paths untested");
        immediate = 0;
        for (int mode = 1; mode <= 3; mode++) begin
            malformed = mode; read_case(BASE, 4, 5);
        end
        malformed = 0; read_case(BASE+2176, 4, 5);
        @(negedge clk); rd_cmd = '{addr:BASE, len:3, size:5, execute:0}; rd_cmd_valid = 1;
        do @(posedge clk); while (!rd_cmd_ready);
        @(negedge clk); rd_cmd_valid = 0; repeat (2) tick(); coordinated_reset();
        read_case(BASE+2176, 4, 5);
        $display("PASS tb_pango_block_bridge RV%0d checks=%0d", XLEN, checks);
        $finish;
    end
    initial begin #2000000; $fatal(1, "native block watchdog"); end
endmodule
