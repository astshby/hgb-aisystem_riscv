// Module: mdu_issue_control
// Description: Qualifies MDU operands using the youngest older producer's readiness.
// 与 GPR 前递保持 MEM 优先于 WB 的顺序；无依赖时允许提前开始运算。
module mdu_issue_control (
    input  pipeline_pkg::d2_ex_t  ex_packet,
    input  pipeline_pkg::ex_mem_t mem_packet,
    input  pipeline_pkg::gpr_forward_t mem_forward,
    input  pipeline_pkg::mem_wb_t wb_packet,
    input  logic                  wb_wait,
    output logic                  mdu_operands_ready
);
    import core_types_pkg::*;

    // x0/未使用源不等待。MEM 中较新的写入覆盖 WB 同名写入，不能先按 WB 判停顿。
    function automatic logic operand_ready(input logic used, input gpr_addr_t addr);
        if (!used || addr == '0)
            return 1'b1;
        if (mem_packet.valid && mem_packet.uop.gpr_write && !mem_packet.exc.valid &&
            mem_packet.rd == addr)
            return mem_forward.valid;
        return !(wb_wait && wb_packet.rd == addr);
    endfunction

    // 只有实际选中的生产者尚无结果时才阻止请求，避免 MDU 锁存旧操作数。
    always_comb begin
        mdu_operands_ready = operand_ready(ex_packet.uop.rs1_used, ex_packet.rs1) &&
                             operand_ready(ex_packet.uop.rs2_used, ex_packet.rs2);
    end
endmodule
