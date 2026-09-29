// Module: wb_stage
// Description: Accepts read/write responses, qualifies precise faults, and emits commit trace.
// Load/Store 均在 WB 等待一次完成响应；总线错误在退休边界转换为精确异常。
module wb_stage (
    input  pipeline_pkg::mem_wb_t       in_packet,
    input  logic                        dmem_rsp_valid,
    input  core_types_pkg::xlen_t       dmem_rsp_rdata,
    input  logic                        dmem_rsp_error,
    output pipeline_pkg::mem_wb_t       commit_packet,
    output logic                        dmem_rsp_ready,
    output logic                        wait_for_response, //等待读/写完成响应
    output pipeline_pkg::gpr_forward_t  gpr_write, // GPR 写口同时作为 WB 前递来源
    output pipeline_pkg::csr_forward_t  csr_write, // 已完整且无异常的 CSR 提交通道
    output logic                        commit_valid,
    output core_types_pkg::xlen_t       commit_pc,
    output logic [31:0]                 commit_inst,
    output core_types_pkg::gpr_addr_t   commit_rd,
    output logic                        commit_rd_we,
    output core_types_pkg::xlen_t       commit_rd_data,
    output logic                        commit_exception
);
    import core_types_pkg::*;

    logic memory_response_needed; // 当前有效 Load/Store 是否需要在 WB 接收完成响应
    logic packet_complete;
    logic normal_commit;
    xlen_t load_data;
    xlen_t writeback_data;

    // load 在 WB 与同步 BRAM/Cache 的返回数据汇合，再完成字节选择和扩展。
    load_unit u_load_unit (
        .bus_data(dmem_rsp_rdata),
        .address(in_packet.result),
        .size(in_packet.uop.mem_size),
        .unsigned_load(in_packet.uop.load_unsigned),
        .load_data
    );

    // 数据响应只属于最老的 WB 访存；读写都必须等响应，不因请求接收而提前退休。
    always_comb begin
        memory_response_needed = in_packet.valid &&
                               (in_packet.uop.mem_read || in_packet.uop.mem_write) &&
                               !in_packet.exc.valid;
        dmem_rsp_ready = memory_response_needed;

        wait_for_response = memory_response_needed && !dmem_rsp_valid;
        packet_complete = !wait_for_response;
    end

    // 继承早期异常；仅已真实发出的访问可将错误响应转换为 access fault。
    always_comb begin
        commit_packet = in_packet;
        commit_packet.valid = in_packet.valid && packet_complete;
        if (memory_response_needed && dmem_rsp_valid && dmem_rsp_error) begin
            commit_packet.exc.valid = 1'b1;
            commit_packet.exc.cause = in_packet.uop.mem_write ?
                riscv_priv_pkg::EXC_STORE_ACCESS_FAULT : riscv_priv_pkg::EXC_LOAD_ACCESS_FAULT;
            commit_packet.exc.tval = in_packet.result;
        end
        // D1 已将非法指令转换为异常；异常提交仍有效，但不能写架构寄存器。
        normal_commit = commit_packet.valid && !commit_packet.exc.valid;
    end

    // WB写回，GPR 写口同时作为 WB 前递来源；x0 不产生真实写入。
    always_comb begin
        unique case (in_packet.uop.wb_sel)
            WB_LOAD:   writeback_data = load_data;
            WB_SEQ_PC: writeback_data = in_packet.seq_pc;
            WB_CSR:    writeback_data = in_packet.csr_old;
            default:   writeback_data = in_packet.result;
        endcase

        gpr_write.valid = normal_commit && in_packet.uop.gpr_write && (in_packet.rd != '0);
        gpr_write.addr = in_packet.rd;
        gpr_write.data = writeback_data;
    end

    // CSR 只有在 WB 包完整且无异常时提交，地址和值直接来自流水包。
    always_comb begin
        csr_write.valid = normal_commit && in_packet.csr_we;
        csr_write.addr = in_packet.csr_addr;
        csr_write.data = in_packet.csr_new;
    end

    // commit 仅在指令及其所需响应完整时产生。
    always_comb begin
        commit_valid = in_packet.valid && packet_complete;
        commit_pc = in_packet.pc;
        commit_inst = in_packet.inst;
        commit_rd = in_packet.rd;
        commit_rd_we = gpr_write.valid;
        commit_rd_data = writeback_data;
        commit_exception = commit_valid && commit_packet.exc.valid; // 包含早期异常与 WB 检出的总线访问错误
    end
endmodule
