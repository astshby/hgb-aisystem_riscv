// Module: regfile
// Description: 32-entry two-read, one-write integer register file with x0 fixed to zero.
// 包含写穿透的通用寄存器，core.sv中连接，d2_stage，wb_stage中使用
module regfile (
    input  logic                         clk,
    input  core_types_pkg::gpr_addr_t   rs1_addr,
    input  core_types_pkg::gpr_addr_t   rs2_addr,
    output core_types_pkg::xlen_t       rs1_data,
    output core_types_pkg::xlen_t       rs2_data,
    input  logic                        write_enable,
    input  core_types_pkg::gpr_addr_t   write_addr,
    input  core_types_pkg::xlen_t       write_data
);
    import core_config_pkg::*;
    import core_types_pkg::*;

    // reg0 == 0,特殊处理
    xlen_t regs [1:GPR_NUM-1];

    always_comb begin
        rs1_data = (rs1_addr == '0) ? '0 : regs[rs1_addr];
        rs2_data = (rs2_addr == '0) ? '0 : regs[rs2_addr];
        // 写穿透
        if (write_enable && (write_addr != '0)) begin
            if (rs1_addr == write_addr)
                rs1_data = write_data;
            if (rs2_addr == write_addr)
                rs2_data = write_data;
        end
    end

    // 时序写入
    always_ff @(posedge clk) begin
        if (write_enable && (write_addr != '0))
            regs[write_addr] <= write_data;
    end
endmodule
