// Module: tb_core_retire_queue
// Description: Checks nonblocking queue capacity, strict-head LSU admission, CSR age and cancelled MMIO effects.
module tb_core_retire_queue;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import riscv_priv_pkg::*;
    import rv_asm_pkg::*;
    localparam int NORMAL_BASE = 48;

    logic clk = 1'b0, rst = 1'b1;
    logic imem_req_valid, imem_req_ready, imem_rsp_valid, imem_rsp_ready, imem_rsp_error;
    xlen_t imem_req_addr;
    logic [31:0] imem_rsp_data;
    logic dmem_req_valid, dmem_req_ready, dmem_req_write;
    mem_size_e dmem_req_size;
    xlen_t dmem_req_addr, dmem_req_wdata, dmem_rsp_rdata;
    logic [DBUS_BYTES-1:0] dmem_req_wstrb;
    logic dmem_rsp_valid, dmem_rsp_ready, dmem_rsp_error;
    logic commit_valid, commit_rd_we, commit_exception, fence_i_commit;
    xlen_t commit_pc, commit_rd_data;
    logic [31:0] commit_inst;
    gpr_addr_t commit_rd;
    logic [7:0] memory[2048];
    logic pending_q, error_q;
    xlen_t data_q;
    int delay_q, scenario, requests, mmio_reads, stores;
    int expected_pc, retired, fences, mrets;
    logic done;

    always #5 clk = ~clk;
    core dut (.commit_trace(), .imem_rsp_error_1(1'b0), .irq_software(1'b0), .irq_timer(1'b0), .irq_external(1'b0), .*);
    assign imem_req_ready = !imem_rsp_valid || imem_rsp_ready;
    assign dmem_req_ready = !pending_q && (!dmem_rsp_valid || dmem_rsp_ready);

    // 请求一经接纳便保持响应至握手；不通过强制流水状态制造非法取消场景。
    always_ff @(posedge clk) begin
        if (rst) begin
            imem_rsp_valid <= 1'b0;
            imem_rsp_error <= 1'b0;
        end else begin
            if (imem_rsp_valid && imem_rsp_ready) imem_rsp_valid <= 1'b0;
            if (imem_req_valid && imem_req_ready) begin
                imem_rsp_valid <= 1'b1;
                for (int lane = 0; lane < 4; lane++)
                    imem_rsp_data[lane*8 +: 8] <= memory[int'(imem_req_addr)+lane];
            end
        end
    end
    always_ff @(posedge clk) begin
        if (rst) begin
            pending_q <= 1'b0;
            error_q <= 1'b0;
            data_q <= '0;
            delay_q <= 0;
            dmem_rsp_valid <= 1'b0;
            dmem_rsp_error <= 1'b0;
            dmem_rsp_rdata <= '0;
            requests <= 0;
            mmio_reads <= 0;
            stores <= 0;
        end else begin
            if (dmem_rsp_valid && dmem_rsp_ready) dmem_rsp_valid <= 1'b0;
            if (pending_q) begin
                if (delay_q == 0) begin
                    pending_q <= 1'b0;
                    dmem_rsp_valid <= 1'b1;
                    dmem_rsp_error <= error_q;
                    dmem_rsp_rdata <= data_q;
                end else delay_q <= delay_q - 1;
            end
            if (dmem_req_valid && dmem_req_ready) begin
                assert (dmem_req_size == MEM_WORD) else $fatal(1, "retirement test lost access size");
                pending_q <= 1'b1;
                delay_q <= 7;
                error_q <= scenario != 0;
                requests <= requests + 1;
                if (!dmem_req_write && dmem_req_addr == 516) mmio_reads <= mmio_reads + 1;
                if (dmem_req_write) stores <= stores + 1;
                for (int lane = 0; lane < DBUS_BYTES; lane++) begin
                    data_q[lane*8 +: 8] <= memory[(int'(dmem_req_addr) & ~(DBUS_BYTES-1))+lane];
                    if (scenario == 0 && dmem_req_write && dmem_req_wstrb[lane])
                        memory[(int'(dmem_req_addr) & ~(DBUS_BYTES-1))+lane] <= dmem_req_wdata[lane*8 +: 8];
                end
            end
        end
    end

    // 程序顺序与预期数值独立于 DUT queue/next_pc；CSR 自己不能计为较老指令。
    always @(posedge clk) begin
        if (rst) begin
            expected_pc = 0;
            retired = 0;
            fences = 0;
            mrets = 0;
            done = 1'b0;
        end else if (commit_valid && !done) begin
            assert (commit_pc == xlen_t'(expected_pc))
                else $fatal(1, "Program age scenario=%0d pc=%h expected=%0d", scenario, commit_pc, expected_pc);
            if (scenario == 0) begin
                assert (!commit_exception) else $fatal(1, "Normal program trapped");
                // 真正 DIV 持有队头期间，九条不同 rd 的独立 ADDI 可以完成并填满八槽。
                // 所有容量都检查实际退休值，不能仅等待一个计数器达到目标。
                if (expected_pc < NORMAL_BASE) begin
                    if (expected_pc == 8)
                        assert (commit_rd_we && commit_rd == 18 &&
                                commit_rd_data == (xlen_t'('1) / xlen_t'(3)))
                            else $fatal(1, "Capacity DIV result");
                    else if (expected_pc >= 12)
                        assert (commit_rd_we && commit_rd == gpr_addr_t'(19 + (expected_pc-12)/4) &&
                                commit_rd_data == xlen_t'(100 + (expected_pc-12)/4))
                            else $fatal(1, "Independent capacity ALU result");
                end
                case (expected_pc - NORMAL_BASE)
                    12: assert (commit_rd_we && commit_rd_data == 11) else $fatal(1, "Load result");
                    16: assert (commit_rd_we && commit_rd_data == 12) else $fatal(1, "Load-use result");
                    24, 52: assert (commit_rd_we && commit_rd_data == xlen_t'(retired))
                        else $fatal(1, "MINSTRET counted self or failed older drain pc=%0d got=%0d retired=%0d",
                                    expected_pc, commit_rd_data, retired);
                    28: assert (commit_rd_we && commit_rd_data == 1) else $fatal(1, "MDU canonical result");
                    44: assert (commit_rd_we && commit_rd_data == 0) else $fatal(1, "CSR old value");
                    48: assert (commit_rd_we && commit_rd_data == 5) else $fatal(1, "CSR forwarded value");
                    56, 64: begin
                        fences++;
                        assert (dut.wb_redirect.valid && fence_i_commit == (expected_pc == NORMAL_BASE + 64))
                            else $fatal(1, "Fence retirement boundary");
                    end
                    84: begin
                        assert (commit_rd_we && commit_rd_data == 1 && requests == 3 &&
                                stores == 2 && mmio_reads == 0 && fences == 2)
                            else $fatal(1, "Normal/wrong-path side-effect count");
                        done = 1'b1;
                    end
                    default: ;
                endcase
                expected_pc = expected_pc == NORMAL_BASE + 72 ? NORMAL_BASE + 84 : expected_pc + 4;
            end else if (expected_pc == 12) begin
                assert (commit_exception && !commit_rd_we && dut.trap_cause == EXC_LOAD_ACCESS_FAULT &&
                        dut.trap_tval == 512 && requests == 1 && !dmem_req_valid)
                    else $fatal(1, "Old access fault did not suppress younger MMIO/Store");
                expected_pc = 256;
            end else begin
                assert (!commit_exception) else $fatal(1, "Unexpected fault in handler setup");
                if (expected_pc == 256) begin
                    assert (commit_rd_we && commit_rd_data == 288 && requests == 1 && stores == 0 && mmio_reads == 0)
                        else $fatal(1, "Cancelled MMIO read/Store escaped before recovery");
                end
                if (expected_pc == 264) begin
                    mrets++;
                    assert (dut.wb_redirect.valid && dut.wb_redirect.reason == REDIR_MRET &&
                            dut.wb_redirect.pc == 288 && requests == 1)
                        else $fatal(1, "MRET failed to restore the safe post-trap PC");
                end
                if (expected_pc == 288) begin
                    assert (commit_rd_we && commit_rd == 7 && commit_rd_data == 1 &&
                            requests == 1 && stores == 0 && mmio_reads == 0 && mrets == 1)
                        else $fatal(1, "Post-MRET retirement or cancelled side effects changed");
                    done = 1'b1;
                end
                expected_pc = expected_pc == 264 ? 288 : expected_pc + 4;
            end
            retired++;
        end
    end

    task automatic put_inst(input int address, input logic [31:0] inst);
        for (int lane = 0; lane < 4; lane++) memory[address+lane] = inst[lane*8 +: 8];
    endtask
    initial begin
        for (scenario = 0; scenario < 3; scenario++) begin
            @(negedge clk);
            rst = 1'b1;
            for (int address = 0; address < 2048; address += 4) put_inst(address, nop());
            if (scenario == 0) begin
                put_inst(0, enc_addi(16, 0, -1));
                put_inst(4, enc_addi(17, 0, 3));
                put_inst(8, enc_divu(18, 16, 17));
                for (int i = 0; i < 9; i++) put_inst(12+i*4, enc_addi(5'(19+i), 0, 100+i));
                put_inst(NORMAL_BASE, enc_addi(1, 0, 512));
                put_inst(NORMAL_BASE+4, enc_addi(2, 0, 11));
                put_inst(NORMAL_BASE+8, enc_sw(2, 1, 0));
                put_inst(NORMAL_BASE+12, enc_lw(3, 1, 0));
                put_inst(NORMAL_BASE+16, enc_addi(4, 3, 1));
                put_inst(NORMAL_BASE+20, enc_addi(5, 4, 1));
                put_inst(NORMAL_BASE+24, enc_csrrs(6, CSR_MINSTRET, 0));
                put_inst(NORMAL_BASE+28, enc_divu(7, 5, 2));
                put_inst(NORMAL_BASE+32, enc_addi(8, 7, 3));
                put_inst(NORMAL_BASE+36, enc_addi(9, 8, 1));
                put_inst(NORMAL_BASE+40, enc_sw(9, 1, 4));
                put_inst(NORMAL_BASE+44, enc_csrrw(10, CSR_MSCRATCH, 9));
                put_inst(NORMAL_BASE+48, enc_csrrs(11, CSR_MSCRATCH, 0));
                put_inst(NORMAL_BASE+52, enc_csrrs(12, CSR_MINSTRET, 0));
                put_inst(NORMAL_BASE+56, 32'h0ff0_000f);
                put_inst(NORMAL_BASE+60, enc_addi(13, 12, 1));
                put_inst(NORMAL_BASE+64, 32'h0000_100f);
                put_inst(NORMAL_BASE+68, enc_addi(14, 0, 1));
                put_inst(NORMAL_BASE+72, enc_jal(0, 12));
                put_inst(NORMAL_BASE+76, enc_sw(0, 1, 8));
                put_inst(NORMAL_BASE+80, enc_lw(0, 1, 4));
                put_inst(NORMAL_BASE+84, enc_addi(15, 0, 1));
                put_inst(NORMAL_BASE+88, enc_jal(0, 0));
            end else begin
                put_inst(0, enc_addi(1, 0, 256));
                put_inst(4, enc_csrrw(0, CSR_MTVEC, 1));
                put_inst(8, enc_addi(2, 0, 512));
                put_inst(12, enc_lw(3, 2, 0));
                // 场景 1 的读具有清状态副作用，不能把“读”当作可随意投机的访问。
                put_inst(16, scenario == 1 ? enc_lw(4, 2, 4) : enc_sw(0, 2, 4));
                put_inst(256, enc_addi(6, 0, 288));
                put_inst(260, enc_csrrw(0, CSR_MEPC, 6));
                put_inst(264, enc_mret());
                put_inst(288, enc_addi(7, 0, 1));
                put_inst(292, enc_jal(0, 0));
            end
            repeat (4) @(posedge clk);
            @(negedge clk);
            rst = 1'b0;
            for (int cycles = 0; cycles < 1200 && !done; cycles++) @(negedge clk);
            assert (done) else $fatal(1, "Queue program timeout scenario=%0d", scenario);
        end
        assert (dut.u_retire_contract_monitor.strict_head_requests == 5)
            else $fatal(1, "Strict-head LSU request count changed");
        // MDU 已离开原 MEM/WB，真实独立 ALU 必须填满配置容量，不能退回三段占用上限。
        assert (dut.u_retire_contract_monitor.maximum_occupancy == RETIRE_ENTRIES &&
                dut.u_retire_contract_monitor.full_frontend_stalls > 0)
            else $fatal(1, "Nonblocking execution did not fill/backpressure the retirement queue");
        assert (dut.u_retire_contract_monitor.alu_during_mdu > 0 &&
                dut.u_retire_contract_monitor.buffered_retirements > 0 &&
                dut.u_retire_contract_monitor.bypass_retirements > 0)
            else $fatal(1, "Missing independent completion, buffered retirement or completion bypass coverage");
        $display("PASS tb_core_retire_queue RV%0d entries=%0d scenarios=3 strict_head=%0d full_stalls=%0d max_occupancy=%0d alu_during_mdu=%0d buffered_retire=%0d bypass_retire=%0d",
                 XLEN, RETIRE_ENTRIES, dut.u_retire_contract_monitor.strict_head_requests,
                 dut.u_retire_contract_monitor.full_frontend_stalls, dut.u_retire_contract_monitor.maximum_occupancy,
                 dut.u_retire_contract_monitor.alu_during_mdu, dut.u_retire_contract_monitor.buffered_retirements,
                 dut.u_retire_contract_monitor.bypass_retirements);
        $finish;
    end
endmodule
