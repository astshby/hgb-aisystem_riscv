// Module: tb_core_interrupt
// Description: Checks precise interrupt draining across loads, stores, MDU, branches, and faults.
module tb_core_interrupt;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import riscv_priv_pkg::*;
    import rv_asm_pkg::*;
    logic clk = 1'b0, rst = 1'b1;
    logic imem_req_valid, imem_req_ready, imem_rsp_valid, imem_rsp_ready, imem_rsp_error;
    xlen_t imem_req_addr;
    logic [31:0] imem_rsp_data;
    logic dmem_req_valid, dmem_req_ready, dmem_req_write;
    mem_size_e dmem_req_size;
    xlen_t dmem_req_addr, dmem_req_wdata, dmem_rsp_rdata;
    logic [DBUS_BYTES-1:0] dmem_req_wstrb;
    logic dmem_rsp_valid, dmem_rsp_ready, dmem_rsp_error;
    logic commit_valid, commit_rd_we, commit_exception;
    xlen_t commit_pc, commit_rd_data;
    logic [31:0] commit_inst;
    gpr_addr_t commit_rd;


    logic irq_software = 0, irq_timer = 0, irq_external = 0;
    logic [7:0] memory [2048];
    logic pending_q, pending_error_q;
    xlen_t pending_data_q, expected_pc, saved_pc;
    int delay_q, scenario, cycles, interrupts, traps, stores, irq_started_cycle;
    logic requested, mret_seen, done;
    always #5 clk = ~clk;
    core dut (.fence_i_commit(), .*);
    assign imem_req_ready = !imem_rsp_valid || imem_rsp_ready;
    assign dmem_req_ready = !pending_q && (!dmem_rsp_valid || dmem_rsp_ready);

    always_ff @(posedge clk) begin
        if (rst) begin
            imem_rsp_valid <= 0;
            imem_rsp_error <= 0;
        end else begin
            if (imem_rsp_valid && imem_rsp_ready) imem_rsp_valid <= 0;
            if (imem_req_valid && imem_req_ready) begin
                imem_rsp_valid <= 1;
                for (int b = 0; b < 4; b++)
                    imem_rsp_data[b*8 +: 8] <= memory[int'(imem_req_addr)+b];
            end
        end
    end
    // 请求已接受不等于完成；每次数据访问延迟返回，Store 副作用只发生一次。
    always_ff @(posedge clk) begin
        if (rst) begin
            pending_q <= 0;
            pending_error_q <= 0;
            pending_data_q <= '0;
            delay_q <= 0;
            dmem_rsp_valid <= 0;
            dmem_rsp_rdata <= 0;
            dmem_rsp_error <= 0;
        end else begin
            if (dmem_rsp_valid && dmem_rsp_ready) dmem_rsp_valid <= 0;
            if (pending_q) begin
                if (delay_q == 0) begin
                    pending_q <= 0;
                    dmem_rsp_valid <= 1;
                    dmem_rsp_rdata <= pending_data_q;
                    dmem_rsp_error <= pending_error_q;
                end else delay_q <= delay_q - 1;
            end
            if (dmem_req_valid && dmem_req_ready) begin
                pending_q <= 1;
                delay_q <= 9;
                pending_error_q <= scenario == 6 && !dmem_req_write;
                for (int b = 0; b < DBUS_BYTES; b++) begin
                    pending_data_q[b*8 +: 8] <= memory[(int'(dmem_req_addr) & ~(DBUS_BYTES-1))+b];
                    if (dmem_req_write && dmem_req_wstrb[b])
                        memory[(int'(dmem_req_addr) & ~(DBUS_BYTES-1))+b] <= dmem_req_wdata[b*8 +: 8];
                end
            end
        end
    end

    // 独立程序参考后继 PC，不以被测 next_pc 字段作为期望值。
    always @(posedge clk) begin
        if (rst) begin
            expected_pc = RESET_VECTOR;
            saved_pc = '0;
            interrupts = 0;
            traps = 0;
            stores = 0;
            mret_seen = 0;
        end else begin
            if (dmem_req_valid && dmem_req_ready && dmem_req_write) begin
                assert (dmem_req_addr == 516 || dmem_req_addr == 524)
                    else $fatal(1, "wrong-path store escaped");
                stores++;
            end
            if (dut.trap_enter) begin
                if (dut.trap_cause[XLEN-1]) begin
                    assert (!pending_q && !dmem_rsp_valid && !commit_valid)
                        else $fatal(1, "interrupt crossed in-flight work");
                    assert (dut.trap_pc == expected_pc && dut.trap_tval == 0 &&
                            dut.trap_cause == ((xlen_t'(1) << (XLEN-1)) | xlen_t'(7)))
                        else $fatal(1, "interrupt resume mismatch scenario=%0d pc=%h want=%h",
                                    scenario, dut.trap_pc, expected_pc);
                    saved_pc = expected_pc;
                    interrupts++;
                end else begin
                    assert (scenario == 6 && dut.trap_cause == xlen_t'(EXC_LOAD_ACCESS_FAULT) &&
                            dut.trap_pc == 24 && interrupts == 0 && stores == 0)
                        else $fatal(1, "sync fault lost priority");
                    traps++;
                end
                expected_pc = 256;
            end else if (commit_valid) begin
                assert (!commit_exception && commit_pc == expected_pc)
                    else $fatal(1, "retirement sequence scenario=%0d pc=%h want=%h", scenario, commit_pc, expected_pc);
                if (commit_pc == 32)
                    assert (commit_rd_data == 9) else $fatal(1, "MDU result corrupted by IRQ");
                case (int'(commit_pc))
                    40: expected_pc = (scenario < 7) ? 56 : 44;
                    60: expected_pc = (scenario < 7) ? 96 : 64;
                    104: expected_pc = 104;
                    268: begin expected_pc = saved_pc; mret_seen = 1; end
                    default: expected_pc = commit_pc + 4;
                endcase
            end
        end
    end
    task automatic put_inst(input int address, input logic [31:0] inst);
        for (int b = 0; b < 4; b++) memory[address+b] = inst[b*8 +: 8];
    endtask

    initial begin
        for (scenario = 0; scenario < 11; scenario++) begin
            @(negedge clk);
            rst = 1;
            irq_timer = 0;
            requested = 0;
            done = 0;
            for (int a = 0; a < 2048; a += 4) put_inst(a, nop());
            put_inst(512, 63);
            put_inst(0, enc_addi(1, 0, 256));
            put_inst(4, enc_csrrw(0, CSR_MTVEC, 1));
            put_inst(8, enc_addi(2, 0, 128));
            put_inst(12, enc_csrrw(0, CSR_MIE, 2));
            put_inst(16, enc_csrrwi(0, CSR_MSTATUS, 8));
            put_inst(20, enc_addi(3, 0, 512));
            put_inst(24, enc_lw(4, 3, 0));
            put_inst(28, enc_addi(5, 0, 7));
            put_inst(32, enc_div(6, 4, 5));
            put_inst(36, enc_sw(6, 3, 4));
            put_inst(40, enc_beq(5, 5, 16));
            put_inst(44, enc_sw(0, 3, 8));
            put_inst(56, enc_addi(7, 0, 96));
            put_inst(60, enc_jalr(0, 7, 0));
            put_inst(64, enc_sw(0, 3, 8));
            put_inst(96, enc_addi(8, 0, 1));
            put_inst(100, enc_sw(8, 3, 12));
            put_inst(104, enc_jal(0, 0));
            // 撤销场景必须直线退休，不能让 taken branch 恰好掩盖 IF 丢包。
            if (scenario >= 7) begin
                put_inst(40, scenario == 10 ? enc_csrrci(0, CSR_MSTATUS, 8) : nop());
                put_inst(44, nop());
                put_inst(60, nop());
                put_inst(64, nop());
            end
            put_inst(256, enc_csrrs(10, CSR_MCAUSE, 0));
            put_inst(260, enc_csrrs(11, CSR_MEPC, 0));
            put_inst(264, enc_addi(12, 0, 1));
            put_inst(268, enc_mret());
            repeat (4) @(posedge clk);
            @(negedge clk);
            rst = 0;
            for (cycles = 0; cycles < 700; cycles++) begin
                @(negedge clk);
                if (!requested) begin
                    if (((scenario == 0 || scenario == 6) && dut.wb_wait && dut.mem_wb_q.pc == 24) ||
                        (scenario == 1 && dut.mem_result_stall) ||
                        (scenario == 2 && dut.if_d1_q.valid && dut.if_d1_q.pc == 40) ||
                        (scenario == 3 && dut.if_d1_q.valid && dut.if_d1_q.pc == 60) ||
                        (scenario == 4 && dut.if_d1_q.valid && dut.if_d1_q.pc == 104) ||
                        (scenario == 5 && dut.wb_wait && dut.mem_wb_q.pc == 36) ||
                        (scenario == 7 && dut.wb_wait && dut.mem_wb_q.pc == 24) ||
                        (scenario == 8 && dut.wb_wait && dut.mem_wb_q.pc == 36) ||
                        (scenario == 9 && dut.mem_result_stall) ||
                        (scenario == 10 && dut.d2_ex_q.valid && dut.d2_ex_q.pc == 40)) begin
                        irq_timer = 1;
                        requested = 1;
                        irq_started_cycle = cycles;
                    end
                end
                if (interrupts != 0) irq_timer = 0;
                // IRQ 脉冲在 Load/Store/MDU 排空前撤销；场景 10 保持电平，由 CSR 关闭 MIE。
                if (scenario >= 7 && scenario <= 9 && requested && cycles > irq_started_cycle)
                    irq_timer = 0;
                if (scenario >= 7 && commit_valid && commit_pc == 104) begin
                    assert (requested && interrupts == 0 && traps == 0 && stores == 2)
                        else $fatal(1, "withdrawn/masked IRQ lost work scenario=%0d", scenario);
                    done = 1;
                    break;
                end
                if (scenario == 6 && traps == 1) begin
                    done = 1;
                    break;
                end
                if (mret_seen && commit_valid && commit_pc == 104) begin
                    assert (interrupts == 1 && stores == 2 && requested)
                        else $fatal(1, "lost/duplicate interrupt or store");
                    done = 1;
                    break;
                end
            end
            assert (done) else $fatal(1, "IRQ scenario timeout %0d", scenario);
        end
        $display("PASS tb_core_interrupt RV%0d scenarios=11", XLEN);
        $finish;
    end
endmodule
