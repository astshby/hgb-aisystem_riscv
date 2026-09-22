// Module: mul_unit
// Description: Shared RISC-V multiplication semantics around a selectable unsigned backend.
// M扩展乘法专用模块；接收 start 与cancel，返回 done 与 计算结果。
// 写入a，b后按照无符号处理，然后根据符号和操作类型修正并返回结果。
module mul_unit #(
    parameter int IMPL = core_config_pkg::MUL_IMPL
) (
    input logic clk, rst, cancel, start,
    input core_types_pkg::muldiv_req_t request,
    output logic done,
    output core_types_pkg::xlen_t result
);
    import core_config_pkg::*;
    import core_types_pkg::*;
    // 输入的操作数与未处理的结果
    xlen_t operand_a, operand_b;
    logic [2*XLEN-1:0] unsigned_product;
    xlen_t signed_high;
    // 由于不能立刻完成，而a，b在值修正必要存在，所以必须要寄存器锁存输入，
    // 其中negetive是判断高位减法的
    xlen_t operand_a_q, operand_b_q;
    logic a_negative_q, b_negative_q;
    muldiv_op_e operation_q;
    op_width_e op_width_q;

    // W 形式只取低 32 位且0扩展。
    assign operand_a = (request.op_width == OP_WIDTH_WORD)
                     ? xlen_t'(request.operand_a[31:0]) : request.operand_a;
    assign operand_b = (request.op_width == OP_WIDTH_WORD)
                     ? xlen_t'(request.operand_b[31:0]) : request.operand_b;

    // 适配性修改
    // generate在综合与布线等阶段决定哪个硬件真实存在，必须返回固定值。（为了在仿真便于区分用来哪个，所以添标签）
    // 并且sv允许使用initial在gererate，用于在elabration阶段报错/警告，防止某些实际不可测情况/仿真的不存在端口。
    generate
        if (IMPL == MUL_DSP) begin : g_dsp
            mul_dsp u_backend (.clk, .rst, .cancel, .start, .operand_a, .operand_b,
                               .done, .product(unsigned_product));
        end else if (IMPL == MUL_BOOTH_WALLACE) begin : g_booth
            mul_booth_wallace u_backend (.clk, .rst, .cancel, .start, .operand_a, .operand_b,
                                         .done, .product(unsigned_product));
        end else if (IMPL == MUL_SHIFT) begin : g_shift
            mul_shift u_backend (.clk, .rst, .cancel, .start, .operand_a, .operand_b,
                                 .done, .product(unsigned_product));
        end else begin : g_invalid
            initial $fatal(1, "invalid multiplier implementation");
        end
    endgenerate

    // 低半与 signed 无关；高半用无符号积减去补码。
    always_comb begin
        signed_high = unsigned_product[2*XLEN-1:XLEN];
        if (a_negative_q) signed_high -= operand_b_q;
        if (b_negative_q) signed_high -= operand_a_q;
        result = (operation_q == MD_MUL) ? unsigned_product[XLEN-1:0] : signed_high;
        // W 符合取低32位符号扩展
        if (op_width_q == OP_WIDTH_WORD)
            result = {{(XLEN-32){unsigned_product[31]}}, unsigned_product[31:0]};
    end

    // 控制与符号在请求握手时锁存，后续不再观察输入请求或动态前递线。
    always_ff @(posedge clk) begin
        if (!rst && !cancel && start) begin
            operand_a_q <= operand_a;
            operand_b_q <= operand_b;
            operation_q <= request.operation;
            op_width_q <= request.op_width;
            a_negative_q <= operand_a[XLEN-1] &&
                ((request.operation == MD_MULH) || (request.operation == MD_MULHSU));
            b_negative_q <= operand_b[XLEN-1] && (request.operation == MD_MULH);
        end
    end
endmodule
