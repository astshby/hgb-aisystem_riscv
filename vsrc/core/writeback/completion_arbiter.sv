// Module: completion_arbiter
// Description: Selects WB, LSU, then MDU and locks only the source owner during completion backpressure.
module completion_arbiter (
    input logic clk, rst, flush,
    input logic wb_valid,
    output logic wb_ready,
    input pipeline_pkg::retire_completion_t wb_completion,
    input logic lsu_valid,
    output logic lsu_ready,
    input pipeline_pkg::retire_completion_t lsu_completion,
    input logic mdu_valid,
    output logic mdu_ready,
    input pipeline_pkg::retire_completion_t mdu_completion,
    output logic complete_valid,
    input logic complete_ready,
    output pipeline_pkg::retire_completion_t completion
);
    typedef enum logic [1:0] {SOURCE_WB, SOURCE_LSU, SOURCE_MDU} source_e;
    logic locked_q;
    source_e locked_source_q, selected_source;

    // 无反压时 WB 优先、组合直通；锁定后新到达的高优先级源不能替换已展示的包。
    // 三个源各自保存载荷到自身 fire；本模块只保存 owner，不复制完成结果。
    always_comb begin
        if (locked_q) selected_source = locked_source_q;
        else if (wb_valid) selected_source = SOURCE_WB;
        else if (lsu_valid) selected_source = SOURCE_LSU;
        else selected_source = SOURCE_MDU;
        complete_valid = 1'b0;
        completion = '0;
        unique case (selected_source)
            SOURCE_WB: begin
                complete_valid = !rst && wb_valid;
                if (complete_valid) completion = wb_completion;
            end
            SOURCE_LSU: begin
                complete_valid = !rst && lsu_valid;
                if (complete_valid) completion = lsu_completion;
            end
            default: begin
                complete_valid = !rst && mdu_valid;
                if (complete_valid) completion = mdu_completion;
            end
        endcase
        wb_ready = !rst && selected_source == SOURCE_WB && complete_ready;
        lsu_ready = !rst && selected_source == SOURCE_LSU && complete_ready;
        mdu_ready = !rst && selected_source == SOURCE_MDU && complete_ready;
    end

    // flush 只在沿上释放锁，不能组合撤销可能产生该 flush 的完成包。
    // 独立外部取消必须与源/接收队列协调；队头事件仍可同拍握手，再清掉年轻状态。
    // 当前队列正常运行时一直 ready；即使接收反压，WB 仍由原 MEM/WB 包保持，
    // LSU 由唯一响应槽保持，MDU 由完成适配器保持；仲裁器不另存结果数据。
    always_ff @(posedge clk) begin
        if (rst || flush)
            locked_q <= 1'b0;
        else if (complete_valid)
            locked_q <= !complete_ready;
    end
    always_ff @(posedge clk) begin
        if (!locked_q && complete_valid && !complete_ready)
            locked_source_q <= selected_source;
    end
endmodule
