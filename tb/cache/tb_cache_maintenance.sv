// Module: tb_cache_maintenance
// Description: Checks command ownership, FENCE.I queuing, backpressure and fail-stop behavior.
module tb_cache_maintenance #(parameter bit ACTIVE = 1'b1);
    timeunit 1ns;
    timeprecision 1ps;
    import cache_pkg::*;
    import core_types_pkg::*;
    logic clk = 0, rst = 1, fence_i_commit = 0;
    logic command_valid = 0, command_ready, busy, fetch_block, fatal;
    cache_maint_op_e command = CACHE_NONE, maint_op;
    cache_maint_error_e error, maint_error = CACHE_OK, cache_fault_code = CACHE_OK;
    xlen_t fault_addr, maint_fault_addr = '0, cache_fault_addr = '0;
    logic maint_req_valid, maint_req_ready = 0, maint_rsp_valid = 0, maint_rsp_ready;
    logic cache_fault_valid = 0;
    int checks = 0;
    always #5 clk = ~clk;
    cache_maintenance_controller #(.ACTIVE(ACTIVE)) dut (.*);

    task automatic tick;
        @(posedge clk); @(negedge clk);
    endtask
    task automatic issue(input cache_maint_op_e op);
        assert (command_ready) else $fatal(1, "command not ready");
        command = op; command_valid = 1;
        tick(); command_valid = 0;
        assert (busy && !command_ready && maint_req_valid && maint_op == op)
            else $fatal(1, "command not queued");
        checks++;
    endtask
    task automatic backend_start(input cache_maint_op_e expected);
        // Cache 尚有 CPU 响应时不可接受维护，控制器必须保持命令不变。
        repeat (4) begin
            tick();
            assert (maint_req_valid && maint_op == expected && !command_ready)
                else $fatal(1, "maintenance changed under backpressure");
        end
        maint_req_ready = 1; tick(); maint_req_ready = 0;
        assert (!maint_req_valid && maint_rsp_ready) else $fatal(1, "backend ownership lost");
        checks++;
    endtask
    task automatic backend_done(input cache_maint_error_e code);
        repeat (3) tick();
        maint_error = code; maint_fault_addr = xlen_t'(32'h80000118);
        maint_rsp_valid = 1; tick(); maint_rsp_valid = 0;
        checks++;
    endtask
    initial begin
        repeat (4) @(posedge clk);
        @(negedge clk); rst = 0; tick();
        issue(CACHE_FLUSH);
        backend_start(CACHE_FLUSH);
        // 软件命令在途时 FENCE.I 另行排队，不改变当前命令的归属。
        fence_i_commit = 1; #1;
        assert (fetch_block == ACTIVE) else $fatal(1, "FENCE.I did not block immediately");
        tick(); fence_i_commit = 0;
        backend_done(CACHE_OK);
        if (ACTIVE) begin
            assert (fetch_block) else $fatal(1, "pending FENCE lost");
            tick(); backend_start(CACHE_CLEAN);
            backend_done(CACHE_OK);
        end
        assert (!fetch_block && command_ready && !busy) else $fatal(1, "maintenance did not release");
        issue(CACHE_INVALIDATE);
        backend_start(CACHE_INVALIDATE);
        backend_done(CACHE_DIRTY_ERROR);
        assert (!fatal && error == CACHE_DIRTY_ERROR && fault_addr == maint_fault_addr)
            else $fatal(1, "manual error became fatal or lost address");
        issue(CACHE_CLEAN);
        assert (error == CACHE_OK) else $fatal(1, "new command did not clear old status");
        backend_start(CACHE_CLEAN); backend_done(CACHE_OK);
        cache_fault_valid = 1; cache_fault_code = CACHE_WRITEBACK_ERROR;
        cache_fault_addr = xlen_t'(32'h80000200);
        tick(); cache_fault_valid = 0;
        assert (error == CACHE_WRITEBACK_ERROR && fault_addr == cache_fault_addr && !fatal)
            else $fatal(1, "eviction fault not recorded");
        fence_i_commit = 1; tick(); fence_i_commit = 0;
        if (ACTIVE) begin
            backend_start(CACHE_CLEAN); backend_done(CACHE_WRITEBACK_ERROR);
            repeat (8) begin
                tick();
                assert (fatal && fetch_block && !command_ready && !maint_req_valid)
                    else $fatal(1, "failed FENCE.I must remain stopped until reset");
            end
        end else assert (!fetch_block && command_ready) else $fatal(1, "disabled cache blocked fetch");
        rst = 1; tick(); rst = 0; tick();
        assert (!fatal && !fetch_block && error == CACHE_OK && command_ready)
            else $fatal(1, "reset did not clear maintenance state");
        $display("PASS tb_cache_maintenance ACTIVE=%0d checks=%0d", ACTIVE, checks);
        $finish;
    end
    initial begin #20000; $fatal(1, "maintenance watchdog"); end
endmodule
