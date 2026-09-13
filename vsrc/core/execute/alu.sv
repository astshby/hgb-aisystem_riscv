// Module: alu
// Description: Combinational RV32/RV64 integer arithmetic and logic unit.
// alu使用的operand实质经过了前递选择与数据选择，统一为a，b
module alu (
    input  core_types_pkg::xlen_t      operand_a,
    input  core_types_pkg::xlen_t      operand_b,
    input  core_types_pkg::alu_op_e    operation,
    input  core_types_pkg::op_width_e  op_width,  // 64/32位操作,需要给出op_width
    output core_types_pkg::xlen_t      result
);
    import core_config_pkg::*;
    import core_types_pkg::*;

    // 提前定义位移量（lui已经移动过，对应a=0）
    localparam int unsigned SHAMT_W = $clog2(XLEN);
    logic [SHAMT_W-1:0] shamt;
    logic [4:0] word_shamt;
    xlen_t xlen_result;
    logic [31:0] word_result;

    // XLEN 位运算结果。
    always_comb begin
        shamt = operand_b[SHAMT_W-1:0];
        unique case (operation)
            ALU_ADD:  xlen_result = operand_a + operand_b;
            ALU_SUB:  xlen_result = operand_a - operand_b;
            ALU_SLL:  xlen_result = operand_a << shamt;
            ALU_SLT:  xlen_result = xlen_t'($signed(operand_a) < $signed(operand_b)); //比较置位要扩展,$signed临时转换为有符号数
            ALU_SLTU: xlen_result = xlen_t'(operand_a < operand_b);
            ALU_XOR:  xlen_result = operand_a ^ operand_b;
            ALU_SRL:  xlen_result = operand_a >> shamt;
            ALU_SRA:  xlen_result = xlen_t'($signed(operand_a) >>> shamt); // >>> 表示算数右移，但是需要将operand_a转换为有符号数
            ALU_OR:   xlen_result = operand_a | operand_b;
            ALU_AND:  xlen_result = operand_a & operand_b;
            default:  xlen_result = '0;
        endcase
    end

    // RV64I W 类运算固定使用低 32 位和 5-bit shamt。
    // 本质上xlen=64就要新添加一个计算32位的结果的alu
    always_comb begin
        word_shamt = operand_b[4:0];
        unique case (operation)
            ALU_ADD: word_result = operand_a[31:0] + operand_b[31:0];
            ALU_SUB: word_result = operand_a[31:0] - operand_b[31:0];
            ALU_SLL: word_result = operand_a[31:0] << word_shamt;
            ALU_SRL: word_result = operand_a[31:0] >> word_shamt;
            ALU_SRA: word_result = $signed(operand_a[31:0]) >>> word_shamt;
            default: word_result = xlen_result[31:0];
        endcase
    end

    // W 类结果必须符号扩展，其余操作直接返回 XLEN 位结果。
    always_comb begin
        if (op_width == OP_WIDTH_WORD)
            result = {{(XLEN-32){word_result[31]}}, word_result};
        else
            result = xlen_result;
    end
endmodule
