// Module: scoreboard_execute
// Description: Computes one integer lane, address descriptor and precise early exception.
module scoreboard_execute (
    input pipeline_pkg::d2_ex_t packet,
    input logic branch_taken,
    input core_types_pkg::xlen_t branch_target,
    input core_types_pkg::xlen_t csr_old_data,
    output pipeline_pkg::retire_completion_t completion,
    output pipeline_pkg::lsu_descriptor_t descriptor
);
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    xlen_t operand_a, operand_b, alu_result, address;
    xlen_t csr_operand, csr_proposed, csr_legal;
    exception_t exception;
    xlen_t store_wdata;
    logic [DBUS_BYTES-1:0] store_wstrb;
    always_comb begin
        unique case (packet.uop.op_a_sel)
            OP_A_RS1: operand_a = packet.rs1_data;
            OP_A_PC: operand_a = packet.pc;
            default: operand_a = '0;
        endcase
        operand_b = packet.uop.op_b_sel == OP_B_IMM ? packet.imm : packet.rs2_data;
        csr_operand = packet.uop.csr_imm ? xlen_t'(packet.rs1) : packet.rs1_data;
    end
    assign address = packet.rs1_data + packet.imm;
    alu u_alu (.operation(packet.uop.alu_op), .operand_a, .operand_b,
               .op_width(packet.uop.op_width), .result(alu_result));
    csr_exec u_csr_exec (.command(packet.uop.csr_cmd), .old_value(csr_old_data),
                        .operand(csr_operand), .new_value(csr_proposed));
    csr_warl u_csr_warl (.address(packet.csr_addr), .proposed_value(csr_proposed), .legal_value(csr_legal));
    ex_exception_check u_exception (
        .in_packet(packet), .operands_ready(1'b1), .branch_ready(1'b1),
        .effective_address(address), .branch_taken, .branch_target, .exception
    );
    store_unit u_store (.store_data(packet.rs2_data), .address, .size(packet.uop.mem_size),
                        .bus_wdata(store_wdata), .bus_wstrb(store_wstrb));
    always_comb begin
        completion = '0;
        completion.id = packet.retire_id;
        completion.result.next_pc = packet.seq_pc;
        completion.result.exc = exception;
        completion.result.csr_write = packet.uop.csr_valid && packet.uop.csr_write && !exception.valid;
        completion.result.csr_data = csr_legal;
        if (packet.uop.branch_op != BR_NONE) begin
            completion.result.branch = '{taken:branch_taken, target:branch_target};
            completion.result.next_pc = branch_taken ? branch_target : packet.seq_pc;
        end
        unique case (packet.uop.wb_sel)
            WB_SEQ_PC: completion.result.gpr_data = packet.seq_pc;
            WB_CSR: completion.result.gpr_data = csr_old_data;
            default: completion.result.gpr_data = alu_result;
        endcase
        descriptor = '{id:packet.retire_id, address:address, write:packet.uop.mem_write,
            size:packet.uop.mem_size, unsigned_load:packet.uop.load_unsigned,
            wdata:store_wdata, wstrb:store_wstrb};
    end
endmodule
