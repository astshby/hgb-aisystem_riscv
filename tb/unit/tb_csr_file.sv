// Module: tb_csr_file
// Description: Checks machine CSR state, counters, trap entry, and MRET state changes.
module tb_csr_file;
    timeunit 1ns;
    timeprecision 1ps;

    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import riscv_priv_pkg::*;

    logic clk = 1'b0;
    logic rst = 1'b1;
    csr_addr_t read_addr;
    xlen_t read_data;
    logic write_valid;
    csr_addr_t write_addr;
    xlen_t write_legal_data;
    logic retire_valid;
    logic trap_enter;
    xlen_t trap_pc;
    exc_cause_e trap_cause;
    xlen_t trap_tval;
    logic mret_commit;
    xlen_t mtvec;
    xlen_t mepc;
    xlen_t cycle_before;

    always #5 clk = ~clk;
    csr_file dut (.*);

    task automatic write_csr(input csr_addr_t address, input xlen_t data);
        @(negedge clk);
        write_valid = 1'b1;
        write_addr = address;
        write_legal_data = data;
        @(posedge clk);
        @(negedge clk);
        write_valid = 1'b0;
    endtask

    initial begin
        read_addr = '0;
        write_valid = 1'b0;
        write_addr = '0;
        write_legal_data = '0;
        retire_valid = 1'b0;
        trap_enter = 1'b0;
        trap_pc = '0;
        trap_cause = EXC_ILLEGAL_INST;
        trap_tval = '0;
        mret_commit = 1'b0;
        repeat (2) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        read_addr = CSR_MISA; #1;
        assert (read_data[8]) else $fatal(1, "MISA must advertise I");
        assert (read_data[12]) else $fatal(1, "MISA must advertise M");
        if (XLEN == 32)
            assert (read_data[31:30] == 2'b01) else $fatal(1, "RV32 MXL");
        else
            assert (read_data[63:62] == 2'b10) else $fatal(1, "RV64 MXL");

        write_csr(CSR_MSCRATCH, xlen_t'(32'h1234_5678));
        read_addr = CSR_MSCRATCH; #1;
        assert (read_data == xlen_t'(32'h1234_5678)) else $fatal(1, "MSCRATCH state");
        write_csr(CSR_MTVEC, xlen_t'(32'h100));
        assert (mtvec == xlen_t'(32'h100)) else $fatal(1, "MTVEC direct mode alignment");

        read_addr = CSR_MCYCLE; #1;
        cycle_before = read_data;
        @(posedge clk);
        @(negedge clk);
        assert (read_data > cycle_before) else $fatal(1, "MCYCLE increment");

        if (XLEN == 32) begin
            write_csr(CSR_MCYCLEH, xlen_t'(32'h1234_5678));
            read_addr = CSR_MCYCLEH; #1;
            assert (read_data == xlen_t'(32'h1234_5678))
                else $fatal(1, "MCYCLEH state");
            write_csr(CSR_MCYCLE, xlen_t'(32'h10));
            read_addr = CSR_MCYCLEH; #1;
            assert (read_data == xlen_t'(32'h1234_5678))
                else $fatal(1, "MCYCLE low write must preserve high half");
            write_csr(CSR_MINSTRETH, xlen_t'(32'h1357_9bdf));
            read_addr = CSR_MINSTRETH; #1;
            assert (read_data == xlen_t'(32'h1357_9bdf))
                else $fatal(1, "MINSTRETH state");
        end

        @(negedge clk);
        retire_valid = 1'b1;
        @(posedge clk);
        @(negedge clk);
        retire_valid = 1'b0;
        read_addr = CSR_MINSTRET; #1;
        if (XLEN == 32)
            assert (read_data == xlen_t'(1)) else $fatal(1, "MINSTRET low increment");
        else
            assert (read_data == xlen_t'(1)) else $fatal(1, "MINSTRET increment");

        // 先打开 MIE，验证 trap 保存到 MPIE，随后 MRET 能恢复原中断状态。
        write_csr(CSR_MSTATUS, xlen_t'(32'h1808));
        read_addr = CSR_MSTATUS; #1;
        assert (read_data[3] == 1'b1 && read_data[7] == 1'b0)
            else $fatal(1, "MSTATUS writable interrupt state");

        @(negedge clk);
        trap_enter = 1'b1;
        trap_pc = xlen_t'(32'h207);
        trap_cause = EXC_LOAD_ADDR_MISALIGNED;
        trap_tval = xlen_t'(32'h43);
        @(posedge clk);
        @(negedge clk);
        trap_enter = 1'b0;
        assert (mepc == xlen_t'(32'h204)) else $fatal(1, "MEPC trap capture");
        read_addr = CSR_MCAUSE; #1;
        assert (read_data == xlen_t'(EXC_LOAD_ADDR_MISALIGNED)) else $fatal(1, "MCAUSE capture");
        read_addr = CSR_MTVAL; #1;
        assert (read_data == xlen_t'(32'h43)) else $fatal(1, "MTVAL capture");
        read_addr = CSR_MSTATUS; #1;
        assert (read_data[3] == 1'b0 && read_data[7] == 1'b1)
            else $fatal(1, "trap interrupt state");

        mret_commit = 1'b1;
        @(posedge clk);
        @(negedge clk);
        mret_commit = 1'b0;
        read_addr = CSR_MSTATUS; #1;
        assert (read_data[3] == 1'b1 && read_data[7] == 1'b1)
            else $fatal(1, "MRET interrupt state");
        $display("PASS tb_csr_file RV%0d", XLEN);
        $finish;
    end
endmodule
