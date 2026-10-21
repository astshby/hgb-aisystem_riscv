// Module: d2_stage
// Description: Adds register operands to the decoded packet before EX.
// 得到寄存器数据，一并传给 EX 阶段
module d2_stage (
    input  pipeline_pkg::d1_d2_t in_packet,
    input  core_types_pkg::xlen_t rs1_data,
    input  core_types_pkg::xlen_t rs2_data,
    input  pipeline_pkg::retire_id_t alloc_id,
    input  pipeline_pkg::gpr_dependency_t rs1_dependency, rs2_dependency,
    output pipeline_pkg::retire_alloc_t alloc_meta,
    output pipeline_pkg::d2_ex_t  out_packet
);
    import core_types_pkg::*;
    import pipeline_pkg::*;
    predictor_types_pkg::ras_op_e decoded_ras_op;
    ras_decode u_ras_decode (.inst(in_packet.inst), .op(decoded_ras_op));

    // 静态退休信息只在 D2 真正发射时入队；异常仍随执行包送至完成端。
    always_comb begin
        alloc_meta = '0;
        alloc_meta.pc = in_packet.pc;
        alloc_meta.seq_pc = in_packet.seq_pc;
        alloc_meta.inst = in_packet.inst;
        alloc_meta.rd = in_packet.rd;
        // 已有异常不会写 GPR，也不能成为一个新的同名生产者。
        alloc_meta.gpr_write = in_packet.uop.gpr_write && !in_packet.exc.valid;
        alloc_meta.csr_addr = in_packet.csr_addr;
        alloc_meta.sys_op = in_packet.uop.sys_op;
        alloc_meta.ras_op = in_packet.exc.valid ? predictor_types_pkg::RAS_NONE : decoded_ras_op;
        if (in_packet.uop.branch_op != BR_NONE) begin
            alloc_meta.branch_kind = in_packet.uop.branch_op;
            alloc_meta.pred_train = in_packet.pred.train;
        end
        if (in_packet.uop.branch_op != BR_NONE)
            alloc_meta.kind = RET_BRANCH;
        else if (in_packet.uop.mem_read)
            alloc_meta.kind = RET_LOAD;
        else if (in_packet.uop.mem_write)
            alloc_meta.kind = RET_STORE;
        else if (in_packet.uop.csr_valid)
            alloc_meta.kind = RET_CSR;
        else if (in_packet.uop.sys_op != SYS_NONE)
            alloc_meta.kind = RET_SERIAL;
        else if (in_packet.uop.fu == FU_MULDIV && !in_packet.exc.valid)
            alloc_meta.kind = RET_MDU;
        else
            alloc_meta.kind = RET_EXEC;
    end

    // 具体 regfile 连接在 core；CSR 立即数在 EX 使用 rs1 地址字段转换，避免覆盖真实读值。
    always_comb begin
        out_packet = '0;
        out_packet.valid = in_packet.valid;
        out_packet.retire_id = alloc_id;
        out_packet.pc = in_packet.pc;
        out_packet.seq_pc = in_packet.seq_pc;
        out_packet.inst = in_packet.inst;
        out_packet.rs1 = in_packet.rs1;
        out_packet.rs2 = in_packet.rs2;
        out_packet.rd = in_packet.rd;
        out_packet.rs1_data = rs1_data;
        out_packet.rs2_data = rs2_data;
        out_packet.rs1_dependency = rs1_dependency;
        out_packet.rs2_dependency = rs2_dependency;
        out_packet.imm = in_packet.imm;
        out_packet.csr_addr = in_packet.csr_addr;
        out_packet.uop = in_packet.uop;
        out_packet.pred = in_packet.pred;
        out_packet.exc = in_packet.exc;
    end
endmodule
