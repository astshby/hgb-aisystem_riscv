// Module: tb_mem_stage
// Description: Checks cache request backpressure, metadata flow, and MEM forwarding.
module tb_mem_stage;
    timeunit 1ns;
    timeprecision 1ps;

    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import riscv_priv_pkg::*;

    logic issue_enable;
    ex_mem_t in_packet;
    logic dmem_req_valid;
    logic dmem_req_write;
    xlen_t dmem_req_addr;
    xlen_t dmem_req_wdata;
    logic [DBUS_BYTES-1:0] dmem_req_wstrb;
    logic dmem_req_ready;
    mem_wb_t out_packet;
    logic request_stall;
    gpr_forward_t gpr_forward;
    csr_forward_t csr_forward;

    mem_stage dut (.*);

    initial begin
        issue_enable = 1'b1;
        dmem_req_ready = 1'b0;
        in_packet = '0;

        // 普通 ALU 指令不使用数据总线，并可直接从 MEM 前递。
        in_packet.valid = 1'b1;
        in_packet.rd = 5'd2;
        in_packet.result = xlen_t'(42);
        in_packet.uop.gpr_write = 1'b1;
        in_packet.uop.wb_sel = WB_ALU;
        #1;
        assert (!dmem_req_valid && !request_stall && out_packet.valid)
            else $fatal(1, "ALU packet must bypass memory request");
        assert (gpr_forward.valid && gpr_forward.addr == 5'd2 &&
                gpr_forward.data == xlen_t'(42))
            else $fatal(1, "missing MEM ALU forwarding");

        // CSR 新值在 MEM 透明传递，并作为后续 CSR 指令的旁路候选。
        in_packet = '0;
        in_packet.valid = 1'b1;
        in_packet.csr_we = 1'b1;
        in_packet.csr_addr = CSR_MSCRATCH;
        in_packet.csr_new = xlen_t'(32'h1234);
        #1;
        assert (csr_forward.valid && csr_forward.addr == CSR_MSCRATCH &&
                csr_forward.data == xlen_t'(32'h1234))
            else $fatal(1, "missing MEM CSR forwarding");

        // load 命中 ready 时立即进入 MEM/WB，但数据要到 WB 才能前递。
        in_packet = '0;
        in_packet.valid = 1'b1;
        in_packet.rd = 5'd2;
        in_packet.uop.gpr_write = 1'b1;
        in_packet.uop.mem_read = 1'b1;
        in_packet.uop.wb_sel = WB_LOAD;
        in_packet.result = xlen_t'(4);
        dmem_req_ready = 1'b1;
        #1;
        assert (dmem_req_valid && !dmem_req_write && !request_stall && out_packet.valid)
            else $fatal(1, "accepted load request");
        assert (!gpr_forward.valid && out_packet.result == xlen_t'(4))
            else $fatal(1, "load must wait for WB response");

        // 请求未被 Cache 接收时，MEM 保持该指令并请求反压。
        dmem_req_ready = 1'b0;
        #1;
        assert (dmem_req_valid && request_stall && !out_packet.valid)
            else $fatal(1, "load request backpressure");

        // 已带异常的访存不能产生存储器副作用。
        in_packet.exc.valid = 1'b1;
        #1;
        assert (!dmem_req_valid && !request_stall && out_packet.valid)
            else $fatal(1, "faulting load must not access memory");

        // 更老的 WB 指令阻塞时，MEM 不得发出年轻请求。
        in_packet.exc.valid = 1'b0;
        issue_enable = 1'b0;
        dmem_req_ready = 1'b1;
        #1;
        assert (!dmem_req_valid && !request_stall && !out_packet.valid)
            else $fatal(1, "disabled MEM issue");

        $display("PASS tb_mem_stage RV%0d", XLEN);
        $finish;
    end
endmodule
