// Module: pipeline_ctrl
// Description: Applies age priority locally to each pipeline boundary and frontend control event.
// 接收已经确认的信号，传递流水线控制信息(流水线是否行进，是否清除，是否暂停)
module pipeline_ctrl (
    input  pipeline_pkg::redirect_t wb_redirect,
    input  pipeline_pkg::redirect_t ex_redirect,
    input  pipeline_pkg::redirect_t d1_redirect,
    input  logic                    ex_serialize_req, // EX 阶段发现需要按序提交的异常
    input  logic                    d1_serialize_req, // D1 阶段发现译码异常或 MRET，内化到流水线中直接处理
    input  logic                    wb_wait, // 普通 WB 完成反压保持普通流水；LSU 独立持有事务。
    input  logic                    execution_stall, // EX 操作数或 MDU 接收端尚未就绪。
    input  logic                    dispatch_waw_stall, // 保守同名写者等待，仅阻挡年轻发射。
    input  logic                    decode_valid,
    input  logic                    dispatch_ready, // 退休队列容量只反压尚未发射的前端。
    output logic                    dispatch_valid,
    output pipeline_pkg::redirect_t redirect, // 以上选择后都给 IF 阶段
    output logic                    serialize_start, // 给seralize_controller处理exc
    output logic                    fetch_ready,  // 由于imem，dmem是否由于后级阻塞本质也是流水线控制，内化此处处理
    output logic                    mem_issue_enable, // 普通 MEM 包向 WB 转交的许可，不控制 LSU 外部请求。
    output logic                    d1_flush, // D1阶段是否清除
    output pipeline_pkg::pipeline_actions_t actions
);
    import pipeline_pkg::*;

    logic dispatch_stall;

    // valid 不依赖 ready，避免队列容量与发射握手自反馈；较老阶段仍照常排空。
    assign dispatch_valid = decode_valid && !(wb_redirect.valid || wb_wait ||
                            ex_redirect.valid || ex_serialize_req || execution_stall || dispatch_waw_stall);
    assign dispatch_stall = dispatch_waw_stall || (dispatch_valid && !dispatch_ready);

    // 每拍只选择一个前端事件，优先级严格按照流水线中指令由老到年轻排列。
    // 普通 WB 或当前 EX 反压延后年轻事件；独立 LSU/MDU 的等待不阻挡无依赖的解析。
    // 序列化仍不能丢弃前面的正常指令，最终架构效果统一由队头退休授权。
    always_comb begin
        redirect = '0;
        serialize_start = 1'b0;
        d1_flush = 1'b0;
        if (wb_redirect.valid) begin
            redirect = wb_redirect;
            d1_flush = 1'b1;
        end else if (!wb_wait) begin
            if (ex_redirect.valid) begin
                redirect = ex_redirect;
                d1_flush = 1'b1;
            end else if (ex_serialize_req) begin
                serialize_start = 1'b1;
                d1_flush = 1'b1;
            end else if (!execution_stall && !dispatch_stall) begin
                if (d1_redirect.valid)
                    redirect = d1_redirect;
                else if (d1_serialize_req)
                    serialize_start = 1'b1;
            end
        end
    end

    // WB 只受自身完成和最老重定向影响，不再经过年轻 EX/D1 事件的编码与译码。
    // bubble 与 flush 仍统一为 CLEAR，区别只在触发原因和清除范围。
    always_comb begin
        if (wb_redirect.valid)
            actions.mem_wb = PIPE_CLEAR;
        else if (wb_wait)
            actions.mem_wb = PIPE_HOLD;
        else
            actions.mem_wb = PIPE_ADVANCE;
    end

    // 普通 WB 反压才保持 EX/MEM；EX 等待（含第二条 LSU）插空，使较老普通包继续排空。
    // LSU 的 PREP/WAIT/DRAIN 自持 owner，不再保持或屏蔽普通 MEM 包。
    always_comb begin
        if (wb_redirect.valid)
            actions.ex_mem = PIPE_CLEAR;
        else if (wb_wait)
            actions.ex_mem = PIPE_HOLD;
        else if (ex_redirect.valid || ex_serialize_req)
            actions.ex_mem = PIPE_ADVANCE;
        else if (execution_stall)
            actions.ex_mem = PIPE_CLEAR;
        else
            actions.ex_mem = PIPE_ADVANCE;
    end

    // EX 自身等待保持操作数；容量/WAW 只清空新入口，当前 EX 与更老指令仍可排空。
    always_comb begin
        if (wb_redirect.valid)
            actions.d2_ex = PIPE_CLEAR;
        else if (wb_wait)
            actions.d2_ex = PIPE_HOLD;
        else if (ex_redirect.valid || ex_serialize_req)
            actions.d2_ex = PIPE_CLEAR;
        else if (execution_stall)
            actions.d2_ex = PIPE_HOLD;
        else if (dispatch_stall)
            actions.d2_ex = PIPE_CLEAR;
        else
            actions.d2_ex = PIPE_ADVANCE;
    end

    // D1 的事件只清除它前面的 IF 包，不反向改变已经进入 D2 的老指令。
    always_comb begin
        if (wb_redirect.valid)
            actions.d1_d2 = PIPE_CLEAR;
        else if (wb_wait)
            actions.d1_d2 = PIPE_HOLD;
        else if (ex_redirect.valid || ex_serialize_req)
            actions.d1_d2 = PIPE_CLEAR;
        else if (execution_stall || dispatch_stall)
            actions.d1_d2 = PIPE_HOLD;
        else
            actions.d1_d2 = PIPE_ADVANCE;
    end

    // IF/D1 是最年轻的边界，依次接受所有较老阶段的清除与保持。
    always_comb begin
        if (wb_redirect.valid)
            actions.if_d1 = PIPE_CLEAR;
        else if (wb_wait)
            actions.if_d1 = PIPE_HOLD;
        else if (ex_redirect.valid || ex_serialize_req)
            actions.if_d1 = PIPE_CLEAR;
        else if (execution_stall || dispatch_stall)
            actions.if_d1 = PIPE_HOLD;
        else if (d1_redirect.valid || d1_serialize_req)
            actions.if_d1 = PIPE_CLEAR;
        else
            actions.if_d1 = PIPE_ADVANCE;
    end

    // IF 只在真正推进时响应；独立 LSU 等待不阻塞普通包或年轻控制流事件。
    always_comb begin
        fetch_ready = !(wb_redirect.valid || wb_wait ||
                        ex_redirect.valid || ex_serialize_req || execution_stall ||
                        dispatch_stall || d1_redirect.valid || d1_serialize_req);
        // 和 MEM/WB 的 ADVANCE 对齐；EX 等待时旧 MEM 转交一次，下一拍由 CLEAR 插空。
        mem_issue_enable = !wb_redirect.valid && !wb_wait;
    end
endmodule
