// Module: tb_block_to_axi
// Description: Independent byte scoreboard for split block transfers, AXI framing, faults, backpressure and concurrent owners.
module tb_block_to_axi;
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
    logic awvalid, awready, awid, awlock, wvalid, wready, wlast;
    logic arvalid, arready, arid, arlock, bvalid, bready, bid, rvalid, rready, rid, rlast;
    logic [31:0] awaddr, araddr;
    logic [7:0] awlen, arlen;
    logic [2:0] awsize, arsize, awprot, arprot;
    logic [1:0] awburst, arburst, bresp, rresp;
    logic [3:0] awcache, awqos, awregion, arcache, arqos, arregion;
    logic [255:0] wdata, rdata;
    logic [31:0] wstrb;
    logic [31:0] fault_read_addr = '1, fault_write_addr = '1;
    logic override_b = 0, bad_bid = 0;
    logic [1:0] injected_bresp = 0;
    logic manual = 0;
    logic model_awready, model_wready, model_arready, model_bvalid, model_bid;
    logic model_rvalid, model_rid, model_rlast;
    logic [1:0] model_bresp, model_rresp;
    logic [255:0] model_rdata;
    logic manual_arready = 0, manual_rvalid = 0, manual_rid = 0, manual_rlast = 0;
    logic [1:0] manual_rresp = 0;
    logic [255:0] manual_rdata = '0;
    byte unsigned expected [BYTES];
    int checks = 0, ar_count = 0, aw_count = 0, r_count = 0, w_count = 0, overlaps = 0;
    int sequence_number = 0;
    logic read_pending = 0, write_pending = 0;
    block_to_axi #(.DDR_BYTES(BYTES)) dut (.*);
    axi_block_memory_model #(.BYTES(BYTES)) memory (
        .clk, .rst(rst || manual), .fault_read_addr, .fault_write_addr,
        .awvalid(awvalid && !manual), .awready(model_awready), .awid, .awaddr, .awlen, .awsize,
        .wvalid(wvalid && !manual), .wready(model_wready), .wdata, .wstrb, .wlast,
        .bvalid(model_bvalid), .bready(bready && !manual), .bid(model_bid), .bresp(model_bresp),
        .arvalid(arvalid && !manual), .arready(model_arready), .arid, .araddr, .arlen, .arsize,
        .rvalid(model_rvalid), .rready(rready && !manual), .rid(model_rid), .rdata(model_rdata),
        .rresp(model_rresp), .rlast(model_rlast)
    );
    assign awready = !manual && model_awready;
    assign wready = !manual && model_wready;
    assign bvalid = !manual && model_bvalid;
    assign bid = model_bid || bad_bid;
    assign bresp = override_b ? injected_bresp : model_bresp;
    assign arready = manual ? manual_arready : model_arready;
    assign rvalid = manual ? manual_rvalid : model_rvalid;
    assign rid = manual ? manual_rid : model_rid;
    assign rdata = manual ? manual_rdata : model_rdata;
    assign rresp = manual ? manual_rresp : model_rresp;
    assign rlast = manual ? manual_rlast : model_rlast;

    // 计数只读取真实握手；参考地址/字节来自激励，不读取DUT的owner、计数器或缓存作答案。
    always_ff @(posedge clk) begin
        if (rst) begin
            ar_count <= 0; aw_count <= 0; r_count <= 0; w_count <= 0;
            read_pending <= 0; write_pending <= 0; overlaps <= 0;
        end else begin
            if (arvalid && arready) begin
                ar_count <= ar_count + 1; read_pending <= 1;
                assert (arburst == 1 && arid == 0 &&
                        int'(araddr[11:0]) + ((int'(arlen)+1) << arsize) <= 4096)
                    else $fatal(1, "AR crossed 4 KiB or changed AXI attributes");
            end
            if (awvalid && awready) begin
                aw_count <= aw_count + 1; write_pending <= 1;
                assert (awburst == 1 && awid == 0 &&
                        int'(awaddr[11:0]) + ((int'(awlen)+1) << awsize) <= 4096)
                    else $fatal(1, "AW crossed 4 KiB or changed AXI attributes");
            end
            if (rvalid && rready) begin r_count <= r_count + 1; if (rlast) read_pending <= 0; end
            if (wvalid && wready) w_count <= w_count + 1;
            if (bvalid && bready) write_pending <= 0;
            if (read_pending && write_pending) overlaps <= overlaps + 1;
        end
    end
    logic held_ar = 0, held_aw = 0, held_w = 0, held_rd = 0, held_b = 0;
    logic [43:0] saved_ar, saved_aw;
    logic [288:0] saved_w;
    block_r_t saved_rd;
    block_b_t saved_b;
    always_ff @(posedge clk) begin
        if (rst) begin held_ar <= 0; held_aw <= 0; held_w <= 0; held_rd <= 0; held_b <= 0; end
        else begin
            if (held_ar) assert (arvalid && {araddr, arlen, arsize, arid} == saved_ar) else $fatal(1, "AR changed");
            if (held_aw) assert (awvalid && {awaddr, awlen, awsize, awid} == saved_aw) else $fatal(1, "AW changed");
            if (held_w) assert (wvalid && {wdata, wstrb, wlast} == saved_w) else $fatal(1, "W changed");
            if (held_rd) assert (rd_valid && rd_data == saved_rd) else $fatal(1, "R block changed");
            if (held_b) assert (wr_rsp_valid && wr_rsp == saved_b) else $fatal(1, "B block changed");
            held_ar <= arvalid && !arready; saved_ar <= {araddr, arlen, arsize, arid};
            held_aw <= awvalid && !awready; saved_aw <= {awaddr, awlen, awsize, awid};
            held_w <= wvalid && !wready; saved_w <= {wdata, wstrb, wlast};
            held_rd <= rd_valid && !rd_ready; saved_rd <= rd_data;
            held_b <= wr_rsp_valid && !wr_rsp_ready; saved_b <= wr_rsp;
        end
    end
    task automatic tick;
        @(posedge clk); @(negedge clk);
    endtask
    task automatic issue_read(input xlen_t address, input int beats, input int size, input bit execute = 0);
        @(negedge clk);
        rd_cmd = '{addr:address, len:8'(beats-1), size:3'(size), execute:execute};
        rd_cmd_valid = 1;
        do @(posedge clk); while (!rd_cmd_ready);
        @(negedge clk); rd_cmd_valid = 0; rd_cmd = '1;
    endtask
    task automatic receive_read(input xlen_t address, input int beats, input int size,
                                input bus_error_e header_error = BUS_OK, input int fault = -1);
        int index;
        bus_error_e expected_error;
        for (int i = 0; i < beats; i++) begin
            while (!rd_valid) @(negedge clk);
            repeat (2) begin
                assert (!rd_cmd_ready) else $fatal(1, "read owner released before consumption");
                tick();
            end
            expected_error = header_error != BUS_OK ? header_error : (i == fault ? BUS_SLVERR : BUS_OK);
            assert (rd_data.error == expected_error && rd_data.last == (i == beats-1))
                else $fatal(1, "R error/last beat=%0d got=%0d expected=%0d last=%0d", i, rd_data.error, expected_error, rd_data.last);
            if (expected_error == BUS_OK) begin
                index = int'(address-BASE+(xlen_t'(i)<<size)) & ~31;
                for (int b = 0; b < 32; b++)
                    assert (rd_data.data[b*8 +: 8] == expected[index+b])
                        else $fatal(1, "R byte mismatch addr=%h byte=%0d", address, i*32+b);
            end
            rd_ready = 1; tick(); rd_ready = 0;
        end
        assert (!rd_valid && rd_cmd_ready) else $fatal(1, "duplicate read completion");
        checks++;
    endtask
    task automatic read_case(input xlen_t address, input int beats, input int size,
                             input bus_error_e error = BUS_OK, input int fault = -1, input bit execute = 0);
        issue_read(address, beats, size, execute);
        receive_read(address, beats > 4 ? 1 : beats, size, error, fault);
    endtask
    task automatic write_case(input xlen_t address, input int beats, input int size,
                              input bus_error_e error = BUS_OK, input bit partial = 0,
                              input bit bad_last = 0, input bit bad_mask = 0, input bit execute = 0);
        int index, actual_beats, salt;
        logic [31:0] mask;
        logic [255:0] payload;
        actual_beats = beats > 4 ? 1 : beats;
        salt = sequence_number; sequence_number++;
        @(negedge clk);
        wr_cmd = '{addr:address, len:8'(beats-1), size:3'(size), execute:execute};
        wr_cmd_valid = 1;
        do @(posedge clk); while (!wr_cmd_ready);
        @(negedge clk); wr_cmd_valid = 0; wr_cmd = '1;
        for (int i = 0; i < actual_beats; i++) begin
            mask = 32'(((65'd1 << (1 << size))-1) << ((address+(xlen_t'(i)<<size)) & 31));
            if (partial) mask &= 32'h55aa55aa;
            if (bad_mask) mask = '1;
            for (int b = 0; b < 32; b++) payload[b*8 +: 8] = 8'(salt*13+i*31+b*7);
            wr_data = '{data:payload, strb:mask, last:((i == actual_beats-1) ^ bad_last)};
            wr_valid = 1;
            do @(posedge clk); while (!wr_ready);
            @(negedge clk); wr_valid = 0; wr_data = '1;
            if (!bad_last && !bad_mask && !execute && beats <= 4 &&
                (error == BUS_OK || fault_write_addr != 32'hffffffff || override_b || bad_bid)) begin
                index = int'(address-BASE+(xlen_t'(i)<<size)) & ~31;
                if (32'(address+(xlen_t'(i)<<size)) != fault_write_addr)
                    for (int b = 0; b < 32; b++) if (mask[b]) expected[index+b] = payload[b*8 +: 8];
            end
            repeat (i%2) tick();
        end
        while (!wr_rsp_valid) @(negedge clk);
        repeat (3) begin
            assert (!wr_cmd_ready) else $fatal(1, "write owner released before response consumption");
            tick();
        end
        assert (wr_rsp.error == error) else $fatal(1, "B error got=%0d expected=%0d", wr_rsp.error, error);
        wr_rsp_ready = 1; tick(); wr_rsp_ready = 0;
        assert (!wr_rsp_valid && wr_cmd_ready) else $fatal(1, "duplicate write completion");
        checks++;
    endtask
    task automatic malformed_read(input int mode);
        int count;
        @(negedge clk); manual = 1; manual_arready = 0;
        issue_read(BASE, 4, 5);
        repeat (3) tick();
        manual_arready = 1;
        do @(posedge clk); while (!arvalid);
        @(negedge clk); manual_arready = 0;
        count = mode == 0 ? 1 : (mode == 1 ? 6 : 4);
        for (int i = 0; i < count; i++) begin
            manual_rvalid = 1;
            manual_rid = mode == 2 && i == 1;
            manual_rresp = mode == 3 && i == 2 ? 2'b01 : 2'b00;
            manual_rlast = i == count-1;
            for (int b = 0; b < 32; b++) manual_rdata[b*8 +: 8] = expected[(i%4)*32+b];
            do @(posedge clk); while (!rready);
            @(negedge clk); manual_rvalid = 0;
            if (i != count-1) assert (!rd_valid) else $fatal(1, "returned before real LAST");
        end
        receive_read(BASE, 4, 5, mode < 2 ? BUS_SLVERR : BUS_OK, mode == 2 ? 1 : 2);
        manual = 0; manual_rid = 0; manual_rresp = 0; manual_rlast = 0;
    endtask
    task automatic coordinated_reset;
        @(negedge clk); rst = 1; rd_cmd_valid = 0; wr_cmd_valid = 0;
        wr_valid = 0; rd_ready = 0; wr_rsp_ready = 0; manual = 0; manual_rvalid = 0;
        repeat (3) tick(); rst = 0; tick();
        assert (rd_cmd_ready && wr_cmd_ready && !rd_valid && !wr_rsp_valid)
            else $fatal(1, "coordinated reset retained owner");
        checks++;
    endtask
    initial begin
        int before_ar, before_aw;
        repeat (4) @(posedge clk);
        @(negedge clk);
        for (int i = 0; i < BYTES; i++) begin
            expected[i] = 8'(i*17+3);
            memory.mem[i/DBUS_BYTES][(i%DBUS_BYTES)*8 +: 8] = expected[i];
        end
        rst = 0;
        for (int beats = 1; beats <= 4; beats++) begin
            write_case(BASE+xlen_t'(beats*128), beats, 5, BUS_OK, beats == 3);
            read_case(BASE+xlen_t'(beats*128), beats, 5, BUS_OK, -1, 1);
        end
        for (int size = 0; size <= 5; size++) begin
            for (int lane = 0; lane < 32; lane += 1 << size) begin
                write_case(BASE+1024+xlen_t'(lane), 1, size);
                read_case(BASE+1024+xlen_t'(lane), 1, size);
            end
        end
        before_aw = aw_count; before_ar = ar_count;
        write_case(BASE+4064, 4, 5); read_case(BASE+4064, 4, 5);
        assert (aw_count-before_aw == 2 && ar_count-before_ar == 2) else $fatal(1, "4 KiB split missing");
        for (int fault = 0; fault < 4; fault++) begin
            fault_read_addr = 32'(BASE)+2048+32'(fault*32);
            read_case(BASE+2048, 4, 5, BUS_OK, fault);
        end
        fault_read_addr = '1;
        fault_write_addr = 32'(BASE)+3072+64;
        write_case(BASE+3072, 4, 5, BUS_SLVERR); read_case(BASE+3072, 4, 5);
        fault_write_addr = '1;
        override_b = 1; injected_bresp = 2'b11;
        write_case(BASE+3328, 4, 5, BUS_DECERR);
        injected_bresp = 2'b01;
        write_case(BASE+3456, 4, 5, BUS_SLVERR);
        override_b = 0; bad_bid = 1;
        write_case(BASE+3584, 4, 5, BUS_SLVERR);
        bad_bid = 0; read_case(BASE+3584, 4, 5);
        before_ar = ar_count; before_aw = aw_count;
        read_case(BASE+1, 4, 5, BUS_SLVERR);
        read_case(BASE+8160, 4, 5, BUS_DECERR);
        read_case(BASE, 5, 5, BUS_SLVERR);
        read_case(BASE, 2, 2, BUS_SLVERR);
        read_case(BASE, 1, 6, BUS_SLVERR);
        read_case(BASE, 1, 0, BUS_SLVERR, -1, 1);
        write_case(BASE+1, 4, 5, BUS_SLVERR);
        write_case(BASE, 4, 5, BUS_SLVERR, 0, 1);
        write_case(BASE+7, 1, 0, BUS_SLVERR, 0, 0, 1);
        write_case(BASE, 4, 5, BUS_SLVERR, 0, 0, 0, 1);
        write_case(BASE, 5, 5, BUS_SLVERR);
        write_case(BASE+8160, 4, 5, BUS_DECERR);
        if (XLEN == 64) read_case(BASE | (xlen_t'(1)<<32), 4, 5, BUS_DECERR);
        assert (ar_count == before_ar && aw_count == before_aw) else $fatal(1, "invalid request reached AXI");
        fork
            write_case(BASE+6144, 4, 5);
            read_case(BASE+6400, 4, 5);
        join
        assert (overlaps > 0) else $fatal(1, "independent read/write overlap was not exercised");
        for (int mode = 0; mode < 4; mode++) malformed_read(mode);
        issue_read(BASE, 4, 5); repeat (3) tick(); coordinated_reset();
        @(negedge clk); wr_cmd = '{addr:BASE, len:3, size:5, execute:0}; wr_cmd_valid = 1;
        do @(posedge clk); while (!wr_cmd_ready);
        @(negedge clk); wr_cmd_valid = 0; coordinated_reset();
        read_case(BASE+3072, 4, 5);
        $display("PASS tb_block_to_axi RV%0d checks=%0d", XLEN, checks);
        $finish;
    end
    initial begin #2000000; $fatal(1, "block bridge watchdog"); end
endmodule
