// Module: csr_bypass
// Description: Selects the newest in-flight value for a CSR read.
// csr旁路检测，类似于流水线中的旁路逻辑。
module csr_bypass (
    input  core_types_pkg::csr_addr_t read_addr,
    input  core_types_pkg::xlen_t     committed_data,
    input  pipeline_pkg::csr_forward_t mem_forward,
    input  pipeline_pkg::csr_forward_t wb_forward,
    output core_types_pkg::xlen_t     bypass_data
);
    // EX/MEM 中的指令比 MEM/WB 更新，因此最后覆盖并获得最高优先级。
    always_comb begin
        bypass_data = committed_data;
        if (wb_forward.valid && (wb_forward.addr == read_addr))
            bypass_data = wb_forward.data;
        if (mem_forward.valid && (mem_forward.addr == read_addr))
            bypass_data = mem_forward.data;
    end
endmodule
