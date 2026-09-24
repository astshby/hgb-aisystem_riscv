// Module: tb_wb_stage
// Description: Checks WB response waiting, load formatting, writeback, and commit.
module tb_wb_stage;
    timeunit 1ns;
    timeprecision 1ps;

    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import riscv_priv_pkg::*;

    mem_wb_t in_packet;
    logic dmem_rsp_valid;
    xlen_t dmem_rsp_rdata;
    logic dmem_rsp_ready;
    logic wait_for_response;
    gpr_forward_t gpr_write;
    csr_forward_t csr_write;
    logic commit_valid;
    xlen_t commit_pc;
    logic [31:0] commit_inst;
    gpr_addr_t commit_rd;
    logic commit_rd_we;
    xlen_t commit_rd_data;
    logic commit_exception;

    wb_stage dut (.*);

    initial begin
        in_packet = '0;
        dmem_rsp_valid = 1'b0;
        dmem_rsp_rdata = '0;

        // 非 load 指令不等待数据响应。
        in_packet.valid = 1'b1;
        in_packet.rd = 5'd1;
        in_packet.result = xlen_t'(123);
        in_packet.uop.gpr_write = 1'b1;
        in_packet.uop.wb_sel = WB_ALU;
        #1;
        assert (!wait_for_response && !dmem_rsp_ready)
            else $fatal(1, "ALU writeback waited for memory");
        assert (commit_valid && gpr_write.valid && gpr_write.data == xlen_t'(123))
            else $fatal(1, "ALU writeback");

        // WB 为无异常且完整的 CSR 包产生一次架构写入。
        in_packet.csr_we = 1'b1;
        in_packet.csr_addr = CSR_MSCRATCH;
        in_packet.csr_new = xlen_t'(32'h1234);
        #1;
        assert (csr_write.valid && csr_write.addr == CSR_MSCRATCH &&
                csr_write.data == xlen_t'(32'h1234))
            else $fatal(1, "CSR commit channel");

        // load 元数据先到 WB，响应未到时必须保持流水线。
        in_packet.csr_we = 1'b0;
        in_packet.result = xlen_t'(1);
        in_packet.uop.mem_read = 1'b1;
        in_packet.uop.mem_size = MEM_BYTE;
        in_packet.uop.wb_sel = WB_LOAD;
        #1;
        assert (wait_for_response && dmem_rsp_ready)
            else $fatal(1, "WB must wait for load response");
        assert (!commit_valid && !gpr_write.valid && !csr_write.valid)
            else $fatal(1, "incomplete load committed");

        // 地址低位 1 选择第二个 byte，0x80 按 LB 符号扩展。
        dmem_rsp_valid = 1'b1;
        dmem_rsp_rdata = xlen_t'(32'h0000_8000);
        #1;
        assert (!wait_for_response && commit_valid && gpr_write.valid)
            else $fatal(1, "completed load writeback");
        assert (gpr_write.data == xlen_t'(-128))
            else $fatal(1, "signed load formatting in WB");

        in_packet.uop.load_unsigned = 1'b1;
        #1;
        assert (gpr_write.data == xlen_t'(128))
            else $fatal(1, "unsigned load formatting in WB");

        // 异常 load 没有真实请求，因此不等待响应，只提交异常信息。
        dmem_rsp_valid = 1'b0;
        in_packet.exc.valid = 1'b1;
        #1;
        assert (!wait_for_response && !dmem_rsp_ready && commit_valid)
            else $fatal(1, "faulting load response handling");
        assert (!gpr_write.valid && !csr_write.valid && commit_exception)
            else $fatal(1, "faulting load architectural effects");

        // 穷举有效位、异常、Load 与返回组合，检查精简后的提交/等待互斥关系。
        for (int bits = 0; bits < 32; bits++) begin
            in_packet = '0;
            in_packet.valid = bits[0];
            in_packet.exc.valid = bits[1];
            in_packet.uop.illegal = bits[1]; // 后级非法包必须携带 D1 已形成的异常。
            in_packet.uop.mem_read = bits[2];
            dmem_rsp_valid = bits[3];
            in_packet.rd = bits[4] ? gpr_addr_t'(1) : '0;
            in_packet.uop.gpr_write = 1'b1;
            in_packet.csr_we = 1'b1;
            #1;
            assert (wait_for_response == (bits[0] && !bits[1] && bits[2] && !bits[3]))
                else $fatal(1, "WB wait truth table %0d", bits);
            assert (commit_valid == (bits[0] && !wait_for_response) &&
                    commit_exception == (commit_valid && bits[1]) &&
                    csr_write.valid == (commit_valid && !bits[1]) &&
                    gpr_write.valid == (csr_write.valid && bits[4]))
                else $fatal(1, "WB commit truth table %0d", bits);
        end

        $display("PASS tb_wb_stage RV%0d", XLEN);
        $finish;
    end
endmodule
