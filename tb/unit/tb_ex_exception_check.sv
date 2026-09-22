// Module: tb_ex_exception_check
// Description: Checks EX-stage exception inheritance, priority, and alignment detection.
module tb_ex_exception_check;
    timeunit 1ns;
    timeprecision 1ps;

    import core_types_pkg::*;
    import pipeline_pkg::*;
    import riscv_priv_pkg::*;

    d2_ex_t in_packet;
    xlen_t effective_address;
    logic branch_taken;
    xlen_t branch_target;
    exception_t exception;

    ex_exception_check dut (.*);

    initial begin
        in_packet = '0;
        effective_address = '0;
        branch_taken = 1'b0;
        branch_target = '0;
        #1;
        assert (!exception.valid) else $fatal(1, "invalid packet exception");

        // 前级异常必须保持最高优先级，不能被 EX 新发现的异常覆盖。
        in_packet.valid = 1'b1;
        in_packet.exc.valid = 1'b1;
        in_packet.exc.cause = EXC_BREAKPOINT;
        in_packet.exc.tval = xlen_t'(32'h44);
        in_packet.uop.csr_valid = 1'b1;
        in_packet.csr_addr = CSR_MIE;
        #1;
        assert (exception.valid && exception.cause == EXC_BREAKPOINT &&
                exception.tval == xlen_t'(32'h44))
            else $fatal(1, "inherited exception priority");

        // 未实现的 CSR 访问按照 RISC-V 规则产生非法指令异常。
        in_packet = '0;
        in_packet.valid = 1'b1;
        in_packet.inst = 32'h3040_2073;
        in_packet.uop.csr_valid = 1'b1;
        in_packet.csr_addr = CSR_MIE;
        #1;
        assert (exception.valid && exception.cause == EXC_ILLEGAL_INST &&
                exception.tval == xlen_t'(in_packet.inst))
            else $fatal(1, "illegal CSR access");

        // Load/Store 使用经过前递和 ALU 计算后的有效地址判断对齐。
        in_packet = '0;
        in_packet.valid = 1'b1;
        in_packet.uop.mem_read = 1'b1;
        in_packet.uop.mem_size = MEM_WORD;
        effective_address = xlen_t'(32'h102);
        #1;
        assert (exception.valid && exception.cause == EXC_LOAD_ADDR_MISALIGNED &&
                exception.tval == effective_address)
            else $fatal(1, "misaligned load");

        in_packet.uop.mem_read = 1'b0;
        in_packet.uop.mem_write = 1'b1;
        #1;
        assert (exception.valid && exception.cause == EXC_STORE_ADDR_MISALIGNED)
            else $fatal(1, "misaligned store");

        effective_address = xlen_t'(32'h104);
        #1;
        assert (!exception.valid) else $fatal(1, "aligned store");

        // 条件分支/JALR 只有实际跳转时才访问并检查目标地址。
        in_packet = '0;
        in_packet.valid = 1'b1;
        in_packet.uop.branch_op = BR_JALR;
        branch_taken = 1'b1;
        branch_target = xlen_t'(32'h202);
        #1;
        assert (exception.valid && exception.cause == EXC_INST_ADDR_MISALIGNED &&
                exception.tval == branch_target)
            else $fatal(1, "misaligned control target");

        branch_taken = 1'b0;
        #1;
        assert (!exception.valid) else $fatal(1, "untaken branch target");

        // JAL 的无寄存器依赖目标已经在 D1 检查，EX 不重复处理。
        in_packet.uop.branch_op = BR_JAL;
        branch_taken = 1'b1;
        #1;
        assert (!exception.valid) else $fatal(1, "JAL belongs to D1 exception check");

        $display("PASS tb_ex_exception_check RV%0d", core_config_pkg::XLEN);
        $finish;
    end
endmodule
