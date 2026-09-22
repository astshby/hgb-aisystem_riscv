// Module: tb_pipeline_ctrl
// Description: Checks redirect age priority and per-register ADVANCE/HOLD/CLEAR actions.
module tb_pipeline_ctrl;
    timeunit 1ns;
    timeprecision 1ps;

    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;

    redirect_t wb_redirect;
    redirect_t ex_redirect;
    redirect_t d1_redirect;
    logic ex_serialize_req;
    logic d1_serialize_req;
    logic wb_wait;
    logic mem_request_stall;
    logic execution_stall;
    logic load_use_stall;
    redirect_t redirect;
    logic serialize_start;
    logic fetch_ready;
    logic mem_issue_enable;
    logic d1_flush;
    pipeline_actions_t actions;

    pipeline_ctrl dut (.*);

    initial begin
        wb_redirect = '0;
        ex_redirect = '0;
        d1_redirect = '0;
        ex_serialize_req = 1'b0;
        d1_serialize_req = 1'b0;
        wb_wait = 1'b0;
        mem_request_stall = 1'b0;
        execution_stall = 1'b0;
        load_use_stall = 1'b0;
        #1;
        assert (!redirect.valid && !serialize_start && !d1_flush && fetch_ready && mem_issue_enable &&
                actions.if_d1 == PIPE_ADVANCE &&
                actions.d1_d2 == PIPE_ADVANCE && actions.d2_ex == PIPE_ADVANCE &&
                actions.ex_mem == PIPE_ADVANCE && actions.mem_wb == PIPE_ADVANCE)
            else $fatal(1, "normal advance");

        d1_redirect.valid = 1'b1;
        d1_redirect.pc = xlen_t'(32'h100);
        #1;
        assert (redirect.valid && !serialize_start && !d1_flush && !fetch_ready && mem_issue_enable &&
                redirect.pc == xlen_t'(32'h100) &&
                actions.if_d1 == PIPE_CLEAR && actions.d1_d2 == PIPE_ADVANCE)
            else $fatal(1, "D1 redirect");

        d1_redirect.valid = 1'b0;
        d1_serialize_req = 1'b1;
        #1;
        assert (!redirect.valid && serialize_start && !d1_flush && !fetch_ready && mem_issue_enable &&
                actions.if_d1 == PIPE_CLEAR &&
                actions.d1_d2 == PIPE_ADVANCE)
            else $fatal(1, "D1 serialization");

        // load-use 比年轻的 D1 redirect 优先，JAL 留在原位置等待下一拍。
        d1_redirect.valid = 1'b1;
        load_use_stall = 1'b1;
        #1;
        assert (!redirect.valid && !serialize_start && !d1_flush && !fetch_ready && mem_issue_enable &&
                actions.if_d1 == PIPE_HOLD &&
                actions.d1_d2 == PIPE_HOLD && actions.d2_ex == PIPE_CLEAR &&
                actions.ex_mem == PIPE_ADVANCE && actions.mem_wb == PIPE_ADVANCE)
            else $fatal(1, "load-use priority");

        // MDU 等待保持 EX，但排空较老 MEM/WB；年轻 D1 事件不能取消运算。
        load_use_stall = 1'b0;
        execution_stall = 1'b1;
        #1;
        assert (!redirect.valid && !serialize_start && !d1_flush && !fetch_ready &&
                mem_issue_enable &&
                actions.if_d1 == PIPE_HOLD && actions.d1_d2 == PIPE_HOLD &&
                actions.d2_ex == PIPE_HOLD && actions.ex_mem == PIPE_CLEAR &&
                actions.mem_wb == PIPE_ADVANCE)
            else $fatal(1, "MDU wait must drain older instructions once");

        // MEM 请求未被接受时，年轻的 EX redirect 也必须延后。
        load_use_stall = 1'b0;
        d1_serialize_req = 1'b1;
        ex_redirect.valid = 1'b1;
        ex_redirect.pc = xlen_t'(32'h200);
        mem_request_stall = 1'b1;
        #1;
        assert (!redirect.valid && !serialize_start && !d1_flush && !fetch_ready && mem_issue_enable &&
                actions.if_d1 == PIPE_HOLD &&
                actions.d1_d2 == PIPE_HOLD && actions.d2_ex == PIPE_HOLD &&
                actions.ex_mem == PIPE_HOLD && actions.mem_wb == PIPE_ADVANCE)
            else $fatal(1, "MEM request stall priority");

        // MEM 请求完成后，EX 重定向清除自身之前的年轻指令。
        mem_request_stall = 1'b0;
        execution_stall = 1'b0;
        #1;
        assert (redirect.valid && !serialize_start && d1_flush && !fetch_ready && mem_issue_enable &&
                redirect.pc == xlen_t'(32'h200) &&
                actions.if_d1 == PIPE_CLEAR && actions.d1_d2 == PIPE_CLEAR &&
                actions.d2_ex == PIPE_CLEAR && actions.ex_mem == PIPE_ADVANCE)
            else $fatal(1, "EX redirect");

        ex_redirect.valid = 1'b0;
        d1_serialize_req = 1'b0;
        ex_serialize_req = 1'b1;
        #1;
        assert (!redirect.valid && serialize_start && d1_flush && !fetch_ready && mem_issue_enable &&
                actions.if_d1 == PIPE_CLEAR &&
                actions.d1_d2 == PIPE_CLEAR && actions.d2_ex == PIPE_CLEAR &&
                actions.ex_mem == PIPE_ADVANCE)
            else $fatal(1, "EX serialization");

        // Cache miss 在 WB 等响应，需要保持包括 MEM/WB 在内的全部流水状态。
        wb_wait = 1'b1;
        #1;
        assert (!redirect.valid && !serialize_start && !d1_flush && !fetch_ready && !mem_issue_enable &&
                actions.if_d1 == PIPE_HOLD &&
                actions.d1_d2 == PIPE_HOLD && actions.d2_ex == PIPE_HOLD &&
                actions.ex_mem == PIPE_HOLD && actions.mem_wb == PIPE_HOLD)
            else $fatal(1, "WB response wait");

        // WB 重定向最老，覆盖所有等待并清除全部年轻指令。
        wb_redirect.valid = 1'b1;
        wb_redirect.pc = xlen_t'(32'h300);
        execution_stall = 1'b1;
        #1;
        assert (redirect.valid && !serialize_start && d1_flush && !fetch_ready && !mem_issue_enable &&
                redirect.pc == xlen_t'(32'h300))
            else $fatal(1, "WB redirect priority");
        assert (actions.if_d1 == PIPE_CLEAR && actions.d1_d2 == PIPE_CLEAR &&
                actions.d2_ex == PIPE_CLEAR && actions.ex_mem == PIPE_CLEAR &&
                actions.mem_wb == PIPE_CLEAR)
            else $fatal(1, "WB redirect flush scope");

        $display("PASS tb_pipeline_ctrl");
        $finish;
    end
endmodule
