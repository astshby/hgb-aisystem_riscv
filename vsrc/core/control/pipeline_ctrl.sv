// Module: pipeline_ctrl
// Description: Selects the oldest control event and assigns one action to each pipeline register.
// 接收已经确认的信号，传递流水线控制信息(流水线是否行进，是否清除，是否暂停)
module pipeline_ctrl (
    input  pipeline_pkg::redirect_t wb_redirect,
    input  pipeline_pkg::redirect_t ex_redirect,
    input  pipeline_pkg::redirect_t d1_redirect,
    input  logic                    ex_serialize_req, // EX 阶段发现需要按序提交的异常
    input  logic                    d1_serialize_req, // D1 阶段发现译码异常或 MRET，内化到流水线中直接处理
    input  logic                    wb_wait,
    input  logic                    mem_request_stall,
    input  logic                    mem_result_stall, // MEM 中的 M 指令已发射但结果未返回。
    input  logic                    execution_stall, // EX 操作数或 MDU 接收端尚未就绪。
    input  logic                    load_use_stall,
    output pipeline_pkg::redirect_t redirect, // 以上选择后都给 IF 阶段
    output logic                    serialize_start, // 给seralize_controller处理exc
    output logic                    fetch_ready,  // 由于imem，dmem是否由于后级阻塞本质也是流水线控制，内化此处处理
    output logic                    mem_issue_enable, // dmem是否由于后级阻塞
    output logic                    d1_flush, // D1阶段是否清除
    output pipeline_pkg::pipeline_actions_t actions
);
    import pipeline_pkg::*;

    // 每拍只选择一个事件，优先级严格按照流水线中指令由老到年轻排列。
    typedef enum logic [3:0] {
        CTRL_NONE,
        CTRL_WB_REDIRECT,
        CTRL_WB_WAIT,        // WB 阶段由于取不到load的值而阻塞
        CTRL_MEM_WAIT,       // 请求未被接收，或 M 结果尚未就绪
        CTRL_EX_REDIRECT,
        CTRL_EX_SERIALIZE,   // 序列化相对最低的：前面好的指令必须处理完
        CTRL_EX_WAIT,
        CTRL_LOAD_USE,
        CTRL_D1_REDIRECT,
        CTRL_D1_SERIALIZE
    } control_event_e;

    control_event_e selected_event;

    // 事件仲裁：等待旧指令时，年轻级的重定向或序列化必须延后处理。
    always_comb begin
        selected_event = CTRL_NONE;
        if (wb_redirect.valid)
            selected_event = CTRL_WB_REDIRECT;
        else if (wb_wait)
            selected_event = CTRL_WB_WAIT;
        else if (mem_request_stall || mem_result_stall)
            selected_event = CTRL_MEM_WAIT;
        else if (ex_redirect.valid)
            selected_event = CTRL_EX_REDIRECT;
        else if (ex_serialize_req)
            selected_event = CTRL_EX_SERIALIZE;
        else if (execution_stall)
            selected_event = CTRL_EX_WAIT;
        else if (load_use_stall)
            selected_event = CTRL_LOAD_USE;
        else if (d1_redirect.valid)
            selected_event = CTRL_D1_REDIRECT;
        else if (d1_serialize_req)
            selected_event = CTRL_D1_SERIALIZE;
    end

    // 输出最终选中的重定向或序列化异常事件。
    always_comb begin
        redirect = '0;
        serialize_start = 1'b0;
        d1_flush = 1'b0;
        unique case (selected_event)
            CTRL_WB_REDIRECT: begin
                redirect = wb_redirect;
                d1_flush = 1'b1;
            end
            CTRL_EX_REDIRECT: begin
                redirect = ex_redirect;
                d1_flush = 1'b1;
            end
            CTRL_D1_REDIRECT: redirect = d1_redirect;
            CTRL_EX_SERIALIZE: begin
                serialize_start = 1'b1;
                d1_flush = 1'b1;
            end
            CTRL_D1_SERIALIZE: serialize_start = 1'b1;
            default: ;
        endcase
    end

    // 流水线动作：bubble 与 flush 统一为 CLEAR，区别只在触发原因和清除范围。
    always_comb begin
        actions.if_d1 = PIPE_ADVANCE;
        actions.d1_d2 = PIPE_ADVANCE;
        actions.d2_ex = PIPE_ADVANCE;
        actions.ex_mem = PIPE_ADVANCE;
        actions.mem_wb = PIPE_ADVANCE;

        unique case (selected_event)
            CTRL_WB_REDIRECT: begin
                actions.if_d1 = PIPE_CLEAR;
                actions.d1_d2 = PIPE_CLEAR;
                actions.d2_ex = PIPE_CLEAR;
                actions.ex_mem = PIPE_CLEAR;
                actions.mem_wb = PIPE_CLEAR;
            end
            CTRL_WB_WAIT: begin
                actions.if_d1 = PIPE_HOLD;
                actions.d1_d2 = PIPE_HOLD;
                actions.d2_ex = PIPE_HOLD;
                actions.ex_mem = PIPE_HOLD;
                actions.mem_wb = PIPE_HOLD;
            end
            CTRL_MEM_WAIT: begin
                actions.if_d1 = PIPE_HOLD;
                actions.d1_d2 = PIPE_HOLD;
                actions.d2_ex = PIPE_HOLD;
                actions.ex_mem = PIPE_HOLD;
            end
            CTRL_EX_REDIRECT, CTRL_EX_SERIALIZE: begin
                actions.if_d1 = PIPE_CLEAR;
                actions.d1_d2 = PIPE_CLEAR;
                actions.d2_ex = PIPE_CLEAR;
            end
            CTRL_EX_WAIT: begin
                actions.if_d1 = PIPE_HOLD;
                actions.d1_d2 = PIPE_HOLD;
                actions.d2_ex = PIPE_HOLD;
                actions.ex_mem = PIPE_CLEAR;
            end
            CTRL_LOAD_USE: begin
                actions.if_d1 = PIPE_HOLD;
                actions.d1_d2 = PIPE_HOLD;
                actions.d2_ex = PIPE_CLEAR;
            end
            CTRL_D1_REDIRECT, CTRL_D1_SERIALIZE: begin
                actions.if_d1 = PIPE_CLEAR;
            end
            default: ;
        endcase
    end

    // IF 只在真正推进时响应；MEM 只受 WB 阻塞或重定向约束。
    always_comb begin
        fetch_ready = (actions.if_d1 == PIPE_ADVANCE);
        mem_issue_enable = !wb_redirect.valid && !wb_wait;
    end
endmodule
