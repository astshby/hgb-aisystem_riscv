// Module: branch_result_register
// Description: Captures one EX branch result after operands are ready and holds it until advance.
module branch_result_register (
    input  logic                    clk, rst, cancel, advance,
    input  logic                    selected,
    input  logic                    operands_ready,
    input  logic                    computed_taken,
    input  core_types_pkg::xlen_t   computed_target,
    output logic                    taken,
    output core_types_pkg::xlen_t   target,
    output logic                    wait_for_result
);
    logic valid_q; // 当前 EX 指令的解析结果；推进或取消后释放，不能与下一条分支混用
    logic taken_q;
    core_types_pkg::xlen_t target_q;
    logic capture;

    // 只在所需 GPR 已就绪时捕获一次；较老访存/MDU 的未完成值不能成为分支快照。
    assign capture = selected && operands_ready && !valid_q && !rst && !cancel;
    assign wait_for_result = selected && (!valid_q || rst || cancel);
    // 输出只来自保存槽；未选中或等待时载荷无效，消费者必须按指令类别和资格屏蔽。
    // 不能在未选中时回退到原始计算，否则宽目标加法仍组合接到前端重定向。
    assign taken = taken_q;
    assign target = target_q;

    // 主流水仍只有一个 EX 包。结果可提前保存，较老 WB/MEM 等待期间保持不变。
    always_ff @(posedge clk) begin
        if (rst || cancel || advance)
            valid_q <= 1'b0;
        else if (capture)
            valid_q <= 1'b1;
    end

    // 载荷只在捕获沿更新；valid 清零即可作废，不给无效目标地址增加宽复位网。
    always_ff @(posedge clk) begin
        if (capture) begin
            taken_q <= computed_taken;
            target_q <= computed_target;
        end
    end
endmodule
