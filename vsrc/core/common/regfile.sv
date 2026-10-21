// Module: regfile
// Description: Integer register file with optional four-read/two-write ports and x0 fixed to zero.
// 包含退休写穿透的通用寄存器，core.sv连接D2读口与commit_control架构写口。
module regfile (
    input  logic                         clk,
    input  core_types_pkg::gpr_addr_t   rs1_addr,
    input  core_types_pkg::gpr_addr_t   rs2_addr,
    output core_types_pkg::xlen_t       rs1_data,
    output core_types_pkg::xlen_t       rs2_data,
    input  logic                        write_enable,
    input  core_types_pkg::gpr_addr_t   write_addr,
    input  core_types_pkg::xlen_t       write_data,
    input  core_types_pkg::gpr_addr_t   rs1_addr_1,
    input  core_types_pkg::gpr_addr_t   rs2_addr_1,
    output core_types_pkg::xlen_t       rs1_data_1,
    output core_types_pkg::xlen_t       rs2_data_1,
    input  logic                        write_enable_1,
    input  core_types_pkg::gpr_addr_t   write_addr_1,
    input  core_types_pkg::xlen_t       write_data_1
);
    import core_config_pkg::*;
    import core_types_pkg::*;

    // reg0 == 0,特殊处理
    xlen_t regs [1:GPR_NUM-1];

    always_comb begin
        rs1_data = (rs1_addr == '0) ? '0 : regs[rs1_addr];
        rs2_data = (rs2_addr == '0) ? '0 : regs[rs2_addr];
        rs1_data_1 = (ISSUE_WIDTH == 2 && rs1_addr_1 != '0) ? regs[rs1_addr_1] : '0;
        rs2_data_1 = (ISSUE_WIDTH == 2 && rs2_addr_1 != '0) ? regs[rs2_addr_1] : '0;
        // 写穿透
        if (write_enable && (write_addr != '0)) begin
            if (rs1_addr == write_addr)
                rs1_data = write_data;
            if (rs2_addr == write_addr)
                rs2_data = write_data;
            if (ISSUE_WIDTH == 2 && rs1_addr_1 == write_addr)
                rs1_data_1 = write_data;
            if (ISSUE_WIDTH == 2 && rs2_addr_1 == write_addr)
                rs2_data_1 = write_data;
        end
        // 两口代表同沿按序退休，年轻口最后生效；四个读口都看到最终架构值。
        if (ISSUE_WIDTH == 2 && write_enable_1 && write_addr_1 != '0) begin
            if (rs1_addr == write_addr_1)
                rs1_data = write_data_1;
            if (rs2_addr == write_addr_1)
                rs2_data = write_data_1;
            if (rs1_addr_1 == write_addr_1)
                rs1_data_1 = write_data_1;
            if (rs2_addr_1 == write_addr_1)
                rs2_data_1 = write_data_1;
        end
    end

    // 时序写入
    always_ff @(posedge clk) begin
        if (write_enable && (write_addr != '0))
            regs[write_addr] <= write_data;
        if (ISSUE_WIDTH == 2 && write_enable_1 && write_addr_1 != '0)
            regs[write_addr_1] <= write_data_1;
    end
endmodule
