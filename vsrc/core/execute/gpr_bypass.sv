// Module: gpr_bypass
// Description: Selects the newest available GPR value for an EX operand.
// 输入mem，wb（使用，地址，数据）与自身的使用，地址，数据，输出前递后的数据
module gpr_bypass (
    input  core_types_pkg::gpr_addr_t source_addr,
    input  logic                      source_used,
    input  core_types_pkg::xlen_t     original_data,
    input  pipeline_pkg::gpr_forward_t mem_forward,
    input  pipeline_pkg::gpr_forward_t wb_forward,
    output core_types_pkg::xlen_t     forwarded_data
);
    always_comb begin
        forwarded_data = original_data;
        if (source_used && wb_forward.valid && (wb_forward.addr != '0) &&
            (wb_forward.addr == source_addr))
            forwarded_data = wb_forward.data;
        if (source_used && mem_forward.valid && (mem_forward.addr != '0) &&
            (mem_forward.addr == source_addr))
            forwarded_data = mem_forward.data;
    end
endmodule
