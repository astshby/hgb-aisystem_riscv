// Module: tb_core_lsu_ownership
// Description: Checks external LSU timing and architectural trace and measures consecutive-Load MDU overlap.
module tb_core_lsu_ownership;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import rv_asm_pkg::*;

    logic clk = 0, rst = 1;
    logic imem_req_valid, imem_req_ready, imem_rsp_valid, imem_rsp_ready;
    logic imem_rsp_error = 0;
    xlen_t imem_req_addr;
    logic [31:0] imem_rsp_data;
    logic dmem_req_valid, dmem_req_ready, dmem_req_write;
    logic dmem_rsp_valid, dmem_rsp_ready, dmem_rsp_error;
    mem_size_e dmem_req_size;
    xlen_t dmem_req_addr, dmem_req_wdata, dmem_rsp_rdata;
    logic [DBUS_BYTES-1:0] dmem_req_wstrb;
    logic commit_valid, commit_rd_we, commit_exception;
    xlen_t commit_pc, commit_rd_data;
    logic [31:0] commit_inst;
    gpr_addr_t commit_rd;
    logic [31:0] program_words[32];
    xlen_t expected[8];
    logic expected_write[8];
    int scenario, length, cycle, retired, requests, responses, stores;
    int req_cycle, rsp_cycle, first_rsp_cycle, mdu_issue_cycle, first_req_cycle;
    int result_cycle;
    int fast_loads = 0, fast_stores = 0;
    int result_backpressure = 0;
    logic pending_q, model_pending, model_responded, done;
    xlen_t pending_data_q;
    int delay_q;
    logic held_request;
    logic held_write;
    xlen_t held_addr, held_data;
    logic [DBUS_BYTES-1:0] held_strb;
    mem_size_e held_size;

    always #5 clk = ~clk;
    core dut (.commit_trace(), .imem_rsp_error_1(1'b0), .fence_i_commit(), .irq_software(1'b0), .irq_timer(1'b0), .irq_external(1'b0), .*);
    assign imem_req_ready = !imem_rsp_valid || imem_rsp_ready;
    assign dmem_req_ready = !pending_q && !dmem_rsp_valid;

    always_ff @(posedge clk) begin
        if (rst) begin
            imem_rsp_valid <= 0;
            dmem_rsp_valid <= 0;
            dmem_rsp_error <= 0;
            pending_q <= 0;
            delay_q <= 0;
        end else begin
            if (imem_rsp_valid && imem_rsp_ready) imem_rsp_valid <= 0;
            if (imem_req_valid && imem_req_ready) begin
                imem_rsp_valid <= 1;
                imem_rsp_data <= program_words[int'(imem_req_addr >> 2) & 31];
            end
            if (dmem_rsp_valid && dmem_rsp_ready) dmem_rsp_valid <= 0;
            if (pending_q) begin
                if (delay_q == 0) begin
                    pending_q <= 0;
                    dmem_rsp_valid <= 1;
                    dmem_rsp_rdata <= pending_data_q;
                end else delay_q <= delay_q - 1;
            end
            if (dmem_req_valid && dmem_req_ready) begin
                if (scenario == 0) begin
                    dmem_rsp_valid <= 1;
                    dmem_rsp_rdata <= xlen_t'(41);
                end else begin
                    pending_q <= 1;
                    delay_q <= 12;
                    pending_data_q <= dmem_req_addr == 0 ? xlen_t'(41) : xlen_t'(50);
                end
            end
        end
    end

    // 参考只看总线/退休事件和程序表；不读取 LSU 状态、响应槽或 DUT 队列指针。
    // 请求/响应/退休仍独立建模；C3c 另观察唯一 LSU 完成口，区分结果边界和仲裁等待。
    always @(posedge clk) begin
        if (rst) begin
            cycle = 0;
            retired = 0;
            requests = 0;
            responses = 0;
            stores = 0;
            req_cycle = -1;
            rsp_cycle = -1;
            result_cycle = -1;
            first_req_cycle = -1;
            first_rsp_cycle = -1;
            mdu_issue_cycle = -1;
            model_pending = 0;
            model_responded = 0;
            held_request = 0;
            done = 0;
        end else if (!done) begin
            cycle++;
            if (model_responded) begin
                if (result_cycle < 0) result_cycle = cycle;
                assert (dut.lsu_complete_valid && cycle >= rsp_cycle + 1)
                    else $fatal(1, "LSU registered E2 result missing before retirement");
                if (!dut.lsu_complete_ready) result_backpressure++;
            end
            if (held_request)
                assert (dmem_req_valid && {dmem_req_write,dmem_req_size,dmem_req_addr,dmem_req_wdata,dmem_req_wstrb} ==
                        {held_write,held_size,held_addr,held_data,held_strb})
                    else $fatal(1, "LSU blocked request changed");
            held_request = dmem_req_valid && !dmem_req_ready;
            if (held_request) begin
                held_write = dmem_req_write;
                held_size = dmem_req_size;
                held_addr = dmem_req_addr;
                held_data = dmem_req_wdata;
                held_strb = dmem_req_wstrb;
            end
            if (dmem_req_valid && dmem_req_ready) begin
                assert (!model_pending && !model_responded && dmem_req_size == MEM_WORD)
                    else $fatal(1, "LSU request duplicated an unretired transaction");
                model_pending = 1;
                req_cycle = cycle;
                result_cycle = -1;
                requests++;
                if (first_req_cycle < 0) first_req_cycle = cycle;
                if (dmem_req_write) begin
                    stores++;
                    assert (dmem_req_wstrb == DBUS_BYTES'(15) &&
                            dmem_req_wdata[31:0] == (scenario == 0 ? 32'd42 : 32'd13))
                        else $fatal(1, "LSU Store lane/data side effect mismatch");
                end
            end
            if (dmem_rsp_valid && dmem_rsp_ready) begin
                assert (model_pending && !dmem_rsp_error && cycle > req_cycle)
                    else $fatal(1, "response arrived without an accepted owner or in request cycle");
                model_pending = 0;
                model_responded = 1;
                rsp_cycle = cycle;
                if (first_rsp_cycle < 0) first_rsp_cycle = cycle;
                responses++;
                if (scenario == 0)
                    assert (rsp_cycle == req_cycle + 1) else $fatal(1, "fast response is not E1");
            end
            if (dut.mdu_req_valid && dut.mdu_req_ready) begin
                assert (mdu_issue_cycle < 0) else $fatal(1, "MDU issued twice");
                mdu_issue_cycle = cycle;
            end
            if (commit_valid) begin
                assert (!commit_exception && retired < length && commit_pc == xlen_t'(retired*4) &&
                        commit_inst == program_words[retired] && commit_rd_we == expected_write[retired])
                    else $fatal(1, "LSU trace order/metadata scenario=%0d pc=%h index=%0d", scenario, commit_pc, retired);
                if (commit_rd_we)
                    assert (commit_rd == program_words[retired][11:7] && commit_rd_data == expected[retired])
                        else $fatal(1, "LSU trace destination/value pc=%h", commit_pc);
                if (commit_inst[6:0] inside {7'h03, 7'h23}) begin
                    assert (model_responded && !model_pending && cycle >= rsp_cycle + 1 &&
                            cycle - rsp_cycle <= RETIRE_ENTRIES)
                        else $fatal(1, "LSU retirement preceded E2 or exceeded bounded arbitration");
                    model_responded = 0;
                    $display("LSU_EVENT RV%0d scenario=%0d write=%0d request=%0d response=%0d result_valid=%0d complete_fire=%0d retire=%0d",
                             XLEN,scenario,commit_inst[6:0] == 7'h23,req_cycle,rsp_cycle,result_cycle,cycle,cycle);
                    if (scenario == 0) begin
                        if (commit_inst[6:0] == 7'h03) fast_loads++;
                        else fast_stores++;
                    end
                end
                retired++;
                if (retired == length) done = 1;
            end
        end
    end

    initial begin
        for (scenario = 0; scenario < 3; scenario++) begin
            rst = 1;
            for (int i = 0; i < 32; i++) program_words[i] = enc_jal(0, 0);
            for (int i = 0; i < 8; i++) begin expected[i] = '0; expected_write[i] = 1; end
            if (scenario == 0) begin
                length = 4;
                program_words[0] = enc_lw(1, 0, 0); expected[0] = 41;
                program_words[1] = enc_addi(2, 1, 1); expected[1] = 42;
                program_words[2] = enc_sw(2, 0, 8); expected_write[2] = 0;
                program_words[3] = enc_addi(3, 0, 9); expected[3] = 9;
            end else begin
                int offset;
                offset = scenario == 2 ? 1 : 0;
                length = 7 + offset;
                program_words[0] = enc_addi(10, 0, 84); expected[0] = 84;
                program_words[1] = enc_addi(11, 0, 7); expected[1] = 7;
                program_words[2] = enc_lw(1, 0, 0); expected[2] = 41;
                if (offset != 0) begin program_words[3] = enc_lw(2, 0, 8); expected[3] = 50; end
                program_words[3+offset] = enc_div(3, 10, 11); expected[3+offset] = 12;
                program_words[4+offset] = enc_addi(4, 3, 1); expected[4+offset] = 13;
                program_words[5+offset] = enc_sw(4, 0, 16); expected_write[5+offset] = 0;
                program_words[6+offset] = enc_addi(5, 0, 1); expected[6+offset] = 1;
            end
            repeat (3) @(negedge clk);
            rst = 0;
            for (int timeout = 0; timeout < 1000 && !done; timeout++) @(negedge clk);
            assert (done && requests == (scenario == 2 ? 3 : 2) && responses == requests && stores == 1 &&
                    !model_pending && !model_responded)
                else $fatal(1, "LSU ownership coverage/timeout scenario=%0d", scenario);
            $display("LSU_TIMING RV%0d scenario=%0d cycles=%0d first_req=%0d first_rsp=%0d mdu_issue=%0d mdu_from_first_rsp=%0d requests=%0d",
                     XLEN, scenario, cycle, first_req_cycle, first_rsp_cycle, mdu_issue_cycle,
                     mdu_issue_cycle - first_rsp_cycle, requests);
        end
        assert (fast_loads == 1 && fast_stores == 1) else $fatal(1, "fast Load/Store boundary coverage missing");
        $display("PASS tb_core_lsu_ownership RV%0d scenarios=3 fast_loads=%0d fast_stores=%0d req_rsp_result=E0_E1_E2 result_backpressure=%0d", XLEN, fast_loads, fast_stores, result_backpressure);
        $finish;
    end
endmodule
