// Module: mdu_completion_adapter
// Description: Tags the existing single-result MDU with a retirement ID without adding a result stage.
module mdu_completion_adapter #(
    parameter int MUL_IMPL = core_config_pkg::MUL_IMPL,
    parameter int DIV_IMPL = core_config_pkg::DIV_IMPL
) (
    input logic clk, rst, cancel,
    input logic req_valid,
    output logic req_ready,
    input core_types_pkg::muldiv_req_t request,
    input pipeline_pkg::retire_id_t request_id,
    output logic completion_valid,
    input logic completion_ready,
    output pipeline_pkg::retire_completion_t completion
);
    pipeline_pkg::retire_id_t id_q;
    core_types_pkg::xlen_t result_data;
    logic result_available, req_fire;

    assign req_fire = req_valid && req_ready;
    // RESULT 的唯一载荷仍由原 MDU 寄存；此处只把可用结果与请求 ID 拼包。
    // cancel 不组合压掉 valid，避免完成 -> 队头 Trap -> cancel -> 完成的反馈环。
    assign completion_valid = !rst && result_available;
    always_comb begin
        completion = '0;
        completion.id = id_q;
        completion.result.gpr_data = result_data;
    end

    muldiv_unit #(.MUL_IMPL(MUL_IMPL), .DIV_IMPL(DIV_IMPL)) u_muldiv_unit (
        .clk, .rst, .cancel, .req_valid, .req_ready, .request,
        .result_available, .rsp_valid(),
        .rsp_ready(completion_ready), .rsp_data(result_data)
    );

    // 不另存 busy/valid/result；ID 仅在请求握手沿更新，无效 ID 无需复位。
    // 取消 RESULT 时本拍仍可交付，队列依 ID/flush 决定保留队头还是丢弃年轻完成。
    always_ff @(posedge clk) begin
        if (req_fire)
            id_q <= request_id;
    end
endmodule
