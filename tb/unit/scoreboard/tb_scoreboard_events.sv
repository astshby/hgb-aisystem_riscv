// Module: tb_scoreboard_events
// Description: Checks drained IRQ PC and precise instruction, load store faults and misaligned branch targets in the renamed backend.
module tb_scoreboard_events;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import scoreboard_pkg::*;
    import riscv_priv_pkg::*;
    import rv_asm_pkg::*;
    logic clk = 0, rst = 1, irq_software = 0;
    logic imem_req_valid, imem_req_ready, imem_rsp_valid, imem_rsp_ready, imem_rsp_error, imem_rsp_error_1;
    xlen_t imem_req_addr;
    logic [63:0] imem_rsp_data;
    logic [1:0] mem_req_valid, mem_req_ready, mem_rsp_valid, mem_rsp_ready, issue_fire;
    memory_request_t mem_request [2];
    memory_response_t mem_response [2], pending_response [2];
    logic [1:0] pending;
    int delay_count [2];
    logic commit_valid, commit_rd_we, commit_exception, fence_i_commit;
    xlen_t commit_pc, commit_rd_data;
    logic [31:0] commit_inst;
    gpr_addr_t commit_rd;
    retire_trace_t commit_trace [2];
    logic [31:0] rom [512];
    int scenario, length, fault_pc, cycles, request_count, store_count, irq_count, traps;
    bit done, irq_requested, mret_seen;
    xlen_t expected_resume, saved_resume;
    scoreboard_core dut (.irq_timer(1'b0), .irq_external(1'b0), .*);
    always #5 clk = ~clk;
    assign imem_req_ready = !rst && (!imem_rsp_valid || imem_rsp_ready);
    for (genvar lane = 0; lane < 2; lane++) begin : g_ready
        assign mem_req_ready[lane] = !rst && !pending[lane] && !mem_rsp_valid[lane];
    end
    always_ff @(posedge clk) begin
        if (rst) begin
            imem_rsp_valid <= 0; imem_rsp_error <= 0; imem_rsp_error_1 <= 0;
            mem_rsp_valid <= 0; pending <= 0;
            delay_count[0] <= 0; delay_count[1] <= 0;
        end else begin
            if (imem_rsp_ready) imem_rsp_valid <= 0;
            if (imem_req_valid && imem_req_ready) begin
                assert (imem_req_addr < 2040) else $fatal(1, "unexpected fetch PC=%h", imem_req_addr);
                imem_rsp_valid <= 1;
                imem_rsp_data <= {rom[int'(imem_req_addr)/4 + 1], rom[int'(imem_req_addr)/4]};
                imem_rsp_error <= scenario == 4 && int'(imem_req_addr) == fault_pc;
                imem_rsp_error_1 <= scenario == 4 && int'(imem_req_addr) + 4 == fault_pc;
            end
            for (int lane = 0; lane < 2; lane++) begin
                if (mem_rsp_ready[lane]) mem_rsp_valid[lane] <= 0;
                if (pending[lane]) begin
                    if (delay_count[lane] != 0) delay_count[lane] <= delay_count[lane] - 1;
                    else if (!mem_rsp_valid[lane] || mem_rsp_ready[lane]) begin
                        mem_rsp_valid[lane] <= 1; mem_response[lane] <= pending_response[lane]; pending[lane] <= 0;
                    end
                end
                if (mem_req_valid[lane] && mem_req_ready[lane]) begin
                    pending[lane] <= 1;
                    delay_count[lane] <= 7 + lane;
                    pending_response[lane] <= '{id:mem_request[lane].id, data:xlen_t'(41),
                                                error:scenario inside {2,3}};
                end
            end
        end
    end
    task automatic emit(input logic [31:0] inst);
        rom[length] = inst; length++;
    endtask
    always @(posedge clk) if (!rst && !done) begin
        cycles++;
        for (int lane = 0; lane < 2; lane++) begin
            if (mem_req_valid[lane] && mem_req_ready[lane]) begin
                request_count++;
                if (mem_request[lane].write) store_count++;
            end
            if (commit_trace[lane].valid && !commit_trace[lane].exception) begin
                expected_resume = commit_trace[lane].next_pc;
                if (scenario == 0 && commit_trace[lane].rd_we && commit_trace[lane].rd == 20)
                    assert (commit_trace[lane].rd_data == saved_resume) else $fatal(1, "MEPC read differs from drained PC");
                if (scenario == 0 && commit_trace[lane].inst == enc_mret()) begin
                    assert (commit_trace[lane].next_pc == saved_resume) else $fatal(1, "MRET trace target");
                    mret_seen = 1;
                end
                if (scenario == 0 && commit_trace[lane].rd_we && commit_trace[lane].rd == 31 &&
                    commit_trace[lane].rd_data == 85) done = 1;
            end
            if (commit_trace[lane].valid && commit_trace[lane].exception)
                assert (commit_trace[lane].next_pc == 1024) else $fatal(1, "trap trace target");
        end
        if (dut.trap_enter) begin
            traps++;
            if (scenario == 0) begin
                assert (dut.trap_cause == ((xlen_t'(1) << (XLEN-1)) | xlen_t'(3)) &&
                        dut.trap_pc == expected_resume && dut.rob_occupancy == 0 && dut.iq_occupancy == 0 && !dut.issue_busy)
                    else $fatal(1, "IRQ did not use drained last retirement PC got=%h expected=%h", dut.trap_pc, expected_resume);
                saved_resume = expected_resume; irq_count++;
            end else begin
                assert (dut.trap_pc == xlen_t'(fault_pc)) else $fatal(1, "fault PC scenario=%0d", scenario);
                unique case (scenario)
                    1: assert (dut.trap_cause == xlen_t'(EXC_ILLEGAL_INST) &&
                               dut.trap_tval == xlen_t'(32'hffffffff)) else $fatal;
                    2: assert (dut.trap_cause == xlen_t'(EXC_LOAD_ACCESS_FAULT) &&
                               dut.trap_tval == 512) else $fatal;
                    3: assert (dut.trap_cause == xlen_t'(EXC_STORE_ACCESS_FAULT) &&
                               dut.trap_tval == 512) else $fatal;
                    4: assert (dut.trap_cause == xlen_t'(EXC_INST_ACCESS_FAULT) &&
                               dut.trap_tval == xlen_t'(fault_pc)) else $fatal;
                    5: assert (dut.trap_cause == xlen_t'(EXC_INST_ADDR_MISALIGNED) &&
                               dut.trap_tval == 514) else $fatal(1, "misaligned JALR lost precise exception");
                    6, 7: assert (dut.trap_cause == xlen_t'(EXC_INST_ADDR_MISALIGNED) &&
                               dut.trap_tval == xlen_t'(fault_pc + 2)) else $fatal(1, "misaligned taken branch lost precise exception");
                    default: $fatal;
                endcase
                assert (request_count == (scenario inside {2,3} ? 1 : 0) &&
                        store_count == (scenario == 3 ? 1 : 0)) else $fatal(1, "younger memory side effect");
                done = 1;
            end
        end
        assert (cycles < 4000) else $fatal(1, "event scenario timeout=%0d", scenario);
    end
    always @(posedge clk) if (!rst && dut.wb_redirect.valid) begin
        assert (dut.completion_valid == 0 && dut.issue_count == 0 && dut.issue_enqueue_count == 0)
            else $fatal(1, "flush allowed completion or issue transfer");
    end
    initial begin
        for (scenario = 0; scenario < 8; scenario++) begin
            rst = 1; irq_software = 0; done = 0; irq_requested = 0; mret_seen = 0;
            cycles = 0; traps = 0; request_count = 0; store_count = 0; irq_count = 0;
            expected_resume = 0; saved_resume = 0; length = 0;
            for (int idx = 0; idx < 512; idx++) rom[idx] = nop();
            emit(enc_addi(1, 0, 1024)); emit(enc_csrrw(0, CSR_MTVEC, 1));
            if (scenario == 0) begin
                emit(enc_addi(2, 0, 8)); emit(enc_csrrw(0, CSR_MIE, 2)); emit(enc_csrrs(0, CSR_MSTATUS, 2));
            end
            emit(enc_addi(4, 0, 2003)); emit(enc_addi(5, 0, 7)); emit(enc_divu(6, 4, 5));
            if (scenario == 5) emit(enc_addi(10, 0, 514));
            fault_pc = length * 4;
            unique case (scenario)
                0: emit(enc_lw(7, 0, 512));
                1: emit(32'hffffffff);
                2: emit(enc_lw(7, 0, 512));
                3: emit(enc_sw(6, 0, 512));
                5: emit(enc_jalr(7, 10, 0));
                6: emit(enc_beq(0, 0, 2));
                7: emit(enc_jal(7, 2));
                default: emit(enc_addi(7, 0, 1));
            endcase
            for (int idx = 0; idx < 20; idx++) emit(enc_addi(gpr_addr_t'(8+idx%8), 0, idx));
            if (scenario != 0) begin emit(enc_sw(6, 0, 516)); emit(enc_divu(6, 4, 5)); end
            emit(enc_addi(31, 0, 85)); emit(enc_jal(0, 0));
            rom[256] = enc_csrrs(20, CSR_MEPC, 0);
            rom[257] = enc_csrrs(21, CSR_MCAUSE, 0);
            rom[258] = enc_addi(22, 0, 1);
            rom[259] = enc_mret();
            repeat (3) @(negedge clk); rst = 0;
            while (!done) begin
                @(posedge clk);
                if (scenario == 0 && dut.mdu_req_valid && dut.mdu_req_ready) irq_requested = 1;
                @(negedge clk);
                if (scenario == 0 && irq_requested && irq_count == 0) irq_software = 1;
                if (irq_count != 0) irq_software = 0;
            end
            assert (traps == 1 && (scenario != 0 || (irq_count == 1 && mret_seen)))
                else $fatal(1, "event coverage missing scenario=%0d traps=%0d mret=%0d", scenario, traps, mret_seen);
            $display("EVENT scenario=%0d cycles=%0d requests=%0d stores=%0d irq=%0d", scenario, cycles, request_count, store_count, irq_count);
            rst = 1; @(negedge clk);
        end
        $display("PASS tb_scoreboard_events XLEN=%0d scenarios=8 IRQ illegal load_error store_error fetch_error jalr_align branch_align jal_align", XLEN);
        $finish;
    end
endmodule
