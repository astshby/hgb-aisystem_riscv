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
    logic execution_stall;
    logic dispatch_waw_stall;
    logic decode_valid = 1'b1, dispatch_ready = 1'b1, dispatch_valid;
    redirect_t redirect;
    logic serialize_start;
    logic fetch_ready;
    logic mem_issue_enable;
    logic d1_flush;
    pipeline_actions_t actions;

    // 保留原来的“先选最老事件、再查动作表”作为参考，与 DUT 的逐级控制独立组织。
    pipeline_actions_t expected_actions;
    redirect_t expected_redirect;
    logic expected_serialize, expected_flush;
    int event_rank;

    pipeline_ctrl dut (.*);

    initial begin
        wb_redirect = '0;
        ex_redirect = '0;
        d1_redirect = '0;
        ex_serialize_req = 1'b0;
        d1_serialize_req = 1'b0;
        wb_wait = 1'b0;
        execution_stall = 1'b0;
        dispatch_waw_stall = 1'b0;
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

        // WAW 比年轻的 D1 redirect 优先，JAL 留在原位置等待下一拍。
        d1_redirect.valid = 1'b1;
        dispatch_waw_stall = 1'b1;
        #1;
        assert (!redirect.valid && !serialize_start && !d1_flush && !fetch_ready && mem_issue_enable &&
                actions.if_d1 == PIPE_HOLD &&
                actions.d1_d2 == PIPE_HOLD && actions.d2_ex == PIPE_CLEAR &&
                actions.ex_mem == PIPE_ADVANCE && actions.mem_wb == PIPE_ADVANCE)
            else $fatal(1, "WAW priority");

        // MDU 等待保持 EX，但排空较老 MEM/WB；年轻 D1 事件不能取消运算。
        dispatch_waw_stall = 1'b0;
        execution_stall = 1'b1;
        #1;
        assert (!redirect.valid && !serialize_start && !d1_flush && !fetch_ready &&
                mem_issue_enable &&
                actions.if_d1 == PIPE_HOLD && actions.d1_d2 == PIPE_HOLD &&
                actions.d2_ex == PIPE_HOLD && actions.ex_mem == PIPE_CLEAR &&
                actions.mem_wb == PIPE_ADVANCE)
            else $fatal(1, "MDU wait must drain older instructions once");

        // LSU 不再进入控制器；年轻 EX 重定向只受普通 WB 反压，不能清除独立 LSU owner。
        dispatch_waw_stall = 1'b0;
        d1_serialize_req = 1'b1;
        ex_redirect.valid = 1'b1;
        ex_redirect.pc = xlen_t'(32'h200);
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

        // 普通 WB 完成源被仲裁反压时，必须保持全部普通流水包。
        wb_wait = 1'b1;
        #1;
        assert (!redirect.valid && !serialize_start && !d1_flush && !fetch_ready && !mem_issue_enable &&
                actions.if_d1 == PIPE_HOLD &&
                actions.d1_d2 == PIPE_HOLD && actions.d2_ex == PIPE_HOLD &&
                actions.ex_mem == PIPE_HOLD && actions.mem_wb == PIPE_HOLD)
            else $fatal(1, "WB completion backpressure");

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

        // 穷举全部输入，包括正常流水中互斥的事件同时为 1，不能借不可达假设改变优先级。
        wb_redirect.reason = REDIR_TRAP;
        ex_redirect.reason = REDIR_EX_BRANCH;
        d1_redirect.reason = REDIR_D1_JAL;
        for (int pattern = 0; pattern < 1024; pattern++) begin
            {decode_valid, dispatch_ready} = 2'(pattern >> 8);
            {wb_redirect.valid, wb_wait,
             ex_redirect.valid, ex_serialize_req, execution_stall, dispatch_waw_stall,
             d1_redirect.valid, d1_serialize_req} = 8'(pattern);
            event_rank = 8;
            for (int bit_index = 7; bit_index >= 0; bit_index--)
                if (pattern[bit_index] && event_rank == 8)
                    event_rank = 7 - bit_index;

            expected_actions = '{default:PIPE_ADVANCE};
            expected_redirect = '0;
            expected_serialize = 1'b0;
            expected_flush = 1'b0;
            unique case (event_rank)
                0: begin
                    expected_actions = '{default:PIPE_CLEAR};
                    expected_redirect = wb_redirect;
                    expected_flush = 1'b1;
                end
                1: expected_actions = '{default:PIPE_HOLD};
                2, 3: begin
                    expected_actions.if_d1 = PIPE_CLEAR;
                    expected_actions.d1_d2 = PIPE_CLEAR;
                    expected_actions.d2_ex = PIPE_CLEAR;
                    expected_flush = 1'b1;
                    if (event_rank == 2)
                        expected_redirect = ex_redirect;
                    else
                        expected_serialize = 1'b1;
                end
                4: begin
                    expected_actions.if_d1 = PIPE_HOLD;
                    expected_actions.d1_d2 = PIPE_HOLD;
                    expected_actions.d2_ex = PIPE_HOLD;
                    expected_actions.ex_mem = PIPE_CLEAR;
                end
                5: begin
                    expected_actions.if_d1 = PIPE_HOLD;
                    expected_actions.d1_d2 = PIPE_HOLD;
                    expected_actions.d2_ex = PIPE_CLEAR;
                end
                6, 7: begin
                    expected_actions.if_d1 = PIPE_CLEAR;
                    if (event_rank == 6)
                        expected_redirect = d1_redirect;
                    else
                        expected_serialize = 1'b1;
                end
                default: ;
            endcase
            // 保留256 项事件参考表，再独立叠加发射容量：不能挡住老 EX/MEM/WB。
            // 未被接纳的 D1 JAL/序列化必须等待，不能提前清前端或训练预测器。
            if (event_rank >= 6 && decode_valid && !dispatch_ready) begin
                expected_actions.if_d1 = PIPE_HOLD;
                expected_actions.d1_d2 = PIPE_HOLD;
                expected_actions.d2_ex = PIPE_CLEAR;
                expected_redirect = '0;
                expected_serialize = 1'b0;
            end
            #1;
            assert (actions === expected_actions && redirect === expected_redirect &&
                    serialize_start == expected_serialize && d1_flush == expected_flush &&
                    fetch_ready == (expected_actions.if_d1 == PIPE_ADVANCE) &&
                    mem_issue_enable == (!wb_redirect.valid && !wb_wait) &&
                    dispatch_valid == (decode_valid && event_rank >= 6))
                else $fatal(1, "control equivalence pattern=%h event=%0d actions=%h expected=%h",
                            pattern, event_rank, actions, expected_actions);
        end
        // D1 冷 JAL 可与更老 D2 分配同沿推进，纠错只清更年轻 IF，不丢失两条指令。
        wb_redirect = '0; ex_redirect = '0; d1_redirect = '0;
        wb_wait = 0;
        ex_serialize_req = 0; execution_stall = 0; dispatch_waw_stall = 0;
        d1_serialize_req = 0; decode_valid = 1; dispatch_ready = 1;
        d1_redirect.valid = 1;
        #1;
        assert (dispatch_valid && actions.d2_ex == PIPE_ADVANCE &&
                actions.d1_d2 == PIPE_ADVANCE && actions.if_d1 == PIPE_CLEAR &&
                redirect.valid && !fetch_ready && !serialize_start)
            else $fatal(1, "D1 correction lost JAL or older D2 allocation");
        decode_valid = 0; d1_redirect.valid = 0;
        #1;
        assert (!dispatch_valid && actions.d1_d2 == PIPE_ADVANCE && fetch_ready)
            else $fatal(1, "correctly predicted JAL gained an age-only stall");
        // 第二条 LSU 和其他 EX 等待使用相同规则：旧 MEM 排空一次，然后插空。
        decode_valid = 1; execution_stall = 1;
        #1;
        assert (!dispatch_valid && mem_issue_enable && !fetch_ready &&
                actions.d2_ex == PIPE_HOLD && actions.ex_mem == PIPE_CLEAR &&
                actions.mem_wb == PIPE_ADVANCE)
            else $fatal(1, "second LSU wait duplicated or froze older ordinary packet");
        wb_wait = 1;
        #1;
        assert (actions.mem_wb == PIPE_HOLD && actions.ex_mem == PIPE_HOLD && !mem_issue_enable)
            else $fatal(1, "ordinary WB backpressure lost its owner");
        wb_redirect.valid = 1;
        expected_actions = '{default:PIPE_CLEAR};
        #1;
        assert (actions == expected_actions)
            else $fatal(1, "global flush did not override WB/EX waits");
        $display("PASS tb_pipeline_ctrl exhaustive=1024 plus directed priority cases and independent LSU boundary");
        $finish;
    end
endmodule
