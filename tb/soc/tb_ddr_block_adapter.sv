// Module: tb_ddr_block_adapter
// Description: Preserves narrow access validation, payload lanes and completion ownership across a block adapter.
module tb_ddr_block_adapter;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import bus_types_pkg::*;
    import block_types_pkg::*;
    import soc_addr_pkg::*;
    logic clk = 0, rst = 1;
    logic req_valid, req_ready, rsp_valid, rsp_ready;
    ddr_req_t request;
    ddr_rsp_t response;
    logic rd_cmd_valid, rd_cmd_ready, rd_valid, rd_ready;
    logic wr_cmd_valid, wr_cmd_ready, wr_valid, wr_ready, wr_rsp_valid, wr_rsp_ready;
    block_cmd_t rd_cmd, wr_cmd;
    block_r_t rd_data;
    block_w_t wr_data;
    block_b_t wr_rsp;
    int checks = 0, accepted = 0, completed = 0, read_commands = 0, write_commands = 0;
    int write_data_beats = 0, write_responses = 0, resets = 0;
    logic [255:0] pattern;
    always #5 clk = ~clk;
    ddr_block_adapter #(.DDR_BYTES(4096)) dut (.*);

    always @(posedge clk) if (!rst) begin
        if (req_valid && req_ready) accepted++;
        if (rsp_valid && rsp_ready) completed++;
        if (rd_cmd_valid && rd_cmd_ready) read_commands++;
        if (wr_cmd_valid && wr_cmd_ready) write_commands++;
        if (wr_valid && wr_ready) write_data_beats++;
        if (wr_rsp_valid && wr_rsp_ready) write_responses++;
    end
    task automatic tick;
        @(posedge clk);
        @(negedge clk);
        #1;
    endtask

    function automatic ddr_req_t make_request(input bit write_access, input int size, lane);
        ddr_req_t item;
        item = '0;
        item.addr = xlen_t'(DDR_BASE) + xlen_t'(lane);
        item.size = 3'(size);
        item.write = write_access;
        item.wdata = pattern;
        // 按字节集合形成合法掩码，不使用DUT的移位宽度公式作为参考。
        for (int byte_lane = 0; byte_lane < 32; byte_lane++)
            item.wstrb[byte_lane] = write_access && byte_lane >= lane && byte_lane < lane+(1<<size);
        return item;
    endfunction

    task automatic reset_all;
        rst = 1;
        req_valid = 0; rsp_ready = 0;
        rd_cmd_ready = 0; rd_valid = 0;
        wr_cmd_ready = 0; wr_ready = 0; wr_rsp_valid = 0;
        #1;
        assert (!req_ready && !rsp_valid && !rd_cmd_valid && !wr_cmd_valid &&
                !wr_valid && !rd_ready && !wr_rsp_ready) else $fatal(1, "Reset exposed old owner");
        repeat (2) tick();
        rst = 0;
        #1;
        resets++;
    endtask

    task automatic accept_request(input ddr_req_t item);
        request = item;
        req_valid = 1;
        #1;
        assert (req_ready) else $fatal(1, "Adapter did not recover idle");
        tick();
        req_valid = 0;
        request = '1;
        #1;
    endtask

    task automatic transfer(input ddr_req_t item, input bus_error_e validation_error,
                            input bus_error_e downstream_error = BUS_OK, input bit extra_read = 0);
        block_cmd_t expected_cmd;
        ddr_rsp_t expected_rsp;
        int before_reads, before_writes, before_wbeats, before_b;
        before_reads = read_commands; before_writes = write_commands;
        before_wbeats = write_data_beats; before_b = write_responses;
        expected_cmd = '{addr:item.addr, len:8'd0, size:item.size, execute:item.execute};
        expected_rsp = '{rdata:'0, error:validation_error};
        accept_request(item);
        if (validation_error == BUS_OK) begin
            repeat (3) begin
                assert (!req_ready && !rsp_valid &&
                        rd_cmd_valid == !item.write && wr_cmd_valid == item.write)
                    else $fatal(1, "Command direction or premature response");
                assert ((item.write ? wr_cmd : rd_cmd) == expected_cmd)
                    else $fatal(1, "Changed address/size/execute under command backpressure");
                tick();
            end
            if (item.write) begin
                wr_cmd_ready = 1;
                tick();
                wr_cmd_ready = 0;
                repeat (3) begin
                    assert (wr_valid && wr_data.data == item.wdata && wr_data.strb == item.wstrb && wr_data.last &&
                            !rsp_valid && !rd_cmd_valid && !wr_cmd_valid)
                        else $fatal(1, "Write byte lanes/payload lost while blocked");
                    tick();
                end
                wr_ready = 1;
                tick();
                wr_ready = 0;
                repeat (3) begin
                    assert (!rsp_valid && !wr_valid && wr_rsp_ready) else $fatal(1, "W mistaken for B completion");
                    tick();
                end
                wr_rsp = '{error:downstream_error};
                wr_rsp_valid = 1;
                tick();
                wr_rsp_valid = 0;
                expected_rsp = '{rdata:'0, error:downstream_error};
            end else begin
                rd_cmd_ready = 1;
                tick();
                rd_cmd_ready = 0;
                if (extra_read) begin
                    rd_data = '{data:~pattern, error:BUS_SLVERR, last:1'b0};
                    rd_valid = 1;
                    assert (rd_ready) else $fatal(1, "Read drain not ready");
                    tick();
                    rd_valid = 0;
                    repeat (3) begin
                        assert (!rsp_valid && rd_ready && !req_ready) else $fatal(1, "Extra read frame released early");
                        tick();
                    end
                end
                rd_data = '{data:pattern, error:downstream_error, last:1'b1};
                rd_valid = 1;
                assert (rd_ready) else $fatal(1, "Read owner missing");
                tick();
                rd_valid = 0;
                expected_rsp = '{rdata:pattern, error:extra_read ? BUS_SLVERR : downstream_error};
            end
        end
        #1;
        repeat (4) begin
            assert (rsp_valid && response == expected_rsp && !req_ready && !rd_cmd_valid &&
                    !wr_cmd_valid && !wr_valid && !rd_ready && !wr_rsp_ready)
                else $fatal(1, "Response/error did not hold validation=%0d write=%0d", validation_error, item.write);
            tick();
        end
        rsp_ready = 1;
        tick();
        rsp_ready = 0;
        assert (!rsp_valid && req_ready) else $fatal(1, "Completion was duplicated");
        assert (read_commands-before_reads == int'(validation_error == BUS_OK && !item.write) &&
                write_commands-before_writes == int'(validation_error == BUS_OK && item.write) &&
                write_data_beats-before_wbeats == int'(validation_error == BUS_OK && item.write) &&
                write_responses-before_b == int'(validation_error == BUS_OK && item.write))
            else $fatal(1, "Invalid access escaped or transaction duplicated");
        checks++;
    endtask

    initial begin
        ddr_req_t item;
        pattern = '0;
        for (int lane = 0; lane < 32; lane++) pattern[lane*8 +: 8] = 8'(lane*11+7);
        request = '0; rd_data = '0; wr_rsp = '0;
        @(negedge clk);
        reset_all();
        for (int size = 0; size <= 5; size++) begin
            for (int lane = 0; lane < 32; lane += (1<<size)) begin
                transfer(make_request(0, size, lane), BUS_OK);
                transfer(make_request(1, size, lane), BUS_OK);
            end
        end
        item = make_request(0, 2, 4); item.execute = 1;
        transfer(item, BUS_OK);
        item.size = 3; item.addr = xlen_t'(DDR_BASE);
        transfer(item, BUS_SLVERR);
        item = make_request(1, 2, 0); item.execute = 1;
        transfer(item, BUS_SLVERR);
        item = make_request(1, 0, 0); item.wstrb[31] = 1;
        transfer(item, BUS_SLVERR);
        item = make_request(1, 2, 4); item.wstrb = 0;
        transfer(item, BUS_OK);
        item = make_request(0, 2, 0); item.addr++;
        transfer(item, BUS_SLVERR);
        item = make_request(0, 0, 0); item.size = 6;
        transfer(item, BUS_SLVERR);
        item = make_request(0, 2, 0); item.addr = xlen_t'(DDR_BASE)-1;
        transfer(item, BUS_DECERR);
        item.addr = xlen_t'(DDR_BASE)+4096;
        transfer(item, BUS_DECERR);
        if (XLEN == 64) begin
            item.addr = xlen_t'(64'h0000_0001_8000_0000);
            transfer(item, BUS_DECERR);
        end
        transfer(make_request(0, 2, 0), BUS_OK, BUS_DECERR);
        transfer(make_request(0, 2, 0), BUS_OK, BUS_SLVERR);
        transfer(make_request(1, 2, 0), BUS_OK, BUS_DECERR);
        transfer(make_request(1, 2, 0), BUS_OK, BUS_SLVERR);
        transfer(make_request(0, 2, 0), BUS_OK, BUS_OK, 1);
        // 所有阶段的复位同时清模拟下游义务；不测试非法单边丢弃外部事务。
        for (int phase = 0; phase < 6; phase++) begin
            item = make_request(phase >= 2 && phase <= 4, 2, 0);
            accept_request(item);
            if (phase == 1 || phase == 5) begin
                rd_cmd_ready = 1; tick(); rd_cmd_ready = 0;
                if (phase == 5) begin
                    rd_data = '{data:pattern, error:BUS_OK, last:1'b1};
                    rd_valid = 1; tick(); rd_valid = 0;
                    assert (rsp_valid) else $fatal(1, "No held response reset setup");
                end
            end
            if (phase == 3 || phase == 4) begin
                wr_cmd_ready = 1; tick(); wr_cmd_ready = 0;
                if (phase == 4) begin wr_ready = 1; tick(); wr_ready = 0; end
            end
            reset_all();
            transfer(make_request(0, 2, 0), BUS_OK);
        end
        assert (accepted == completed+6) else $fatal(1, "Reset owner accounting");
        $display("PASS tb_ddr_block_adapter XLEN=%0d checks=%0d req/rsp=%0d/%0d Rcmd=%0d Wcmd=%0d W=%0d B=%0d resets=%0d",
            XLEN, checks, accepted, completed, read_commands, write_commands, write_data_beats, write_responses, resets);
        $finish;
    end
    initial begin
        #2000000;
        $fatal(1, "Adapter test timeout");
    end
endmodule
