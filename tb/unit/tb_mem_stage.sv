// Module: tb_mem_stage
// Description: Checks ordinary metadata flow, MEM forwarding under stalls, and early LSU exceptions.
module tb_mem_stage;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import riscv_priv_pkg::*;
    logic issue_enable;
    ex_mem_t in_packet;
    mem_wb_t out_packet;
    gpr_forward_t gpr_forward;
    csr_forward_t csr_forward;
    int checks = 0;
    mem_stage dut (.*);

    initial begin
        // 原请求反压/严格队头属性迁至 tb_lsu_transaction；MEM 不再拥有外部请求。
        // 普通 ALU、链接地址及 CSR 旧值仍可直接从寄存 MEM 包前递。
        for (int selection = 0; selection < 5; selection++) begin
            xlen_t expected;
            in_packet = '0;
            in_packet.valid = 1;
            in_packet.retire_id = retire_id_t'(selection + 1);
            in_packet.rd = 2;
            in_packet.result = xlen_t'(64'hfedc_ba98_1234_5678);
            in_packet.seq_pc = xlen_t'(64'h8765_4321_0000_0014);
            // 实际方向与全宽目标独立携带；未跳转时 next_pc 不能覆盖潜在目标。
            in_packet.branch = '{taken:selection[0], target:xlen_t'(64'hdead_beef_8000_0020) + xlen_t'(selection * 4)};
            in_packet.next_pc = selection[0] ? in_packet.branch.target : in_packet.seq_pc;
            in_packet.csr_old = xlen_t'(42);
            in_packet.uop.gpr_write = 1;
            in_packet.uop.wb_sel = wb_sel_e'(selection);
            in_packet.csr_we = 1;
            in_packet.csr_addr = CSR_MSCRATCH;
            in_packet.csr_new = xlen_t'(32'h1234);
            case (wb_sel_e'(selection))
                WB_SEQ_PC: expected = in_packet.seq_pc;
                WB_CSR: expected = in_packet.csr_old;
                default: expected = in_packet.result;
            endcase
            for (int enabled = 0; enabled < 2; enabled++) begin
                issue_enable = 1'(enabled);
                #1;
                // WB/LSU 等待只禁止推进，不应隐藏 MEM 已经完成的普通结果。
                assert (out_packet.valid == issue_enable && out_packet.retire_id == in_packet.retire_id &&
                        out_packet.result == in_packet.result && out_packet.csr_new == in_packet.csr_new &&
                        out_packet.branch == in_packet.branch && out_packet.next_pc == in_packet.next_pc &&
                        gpr_forward.valid == (wb_sel_e'(selection) != WB_LOAD) &&
                        gpr_forward.data == expected && csr_forward.valid &&
                        csr_forward.addr == CSR_MSCRATCH && csr_forward.data == xlen_t'(32'h1234))
                    else $fatal(1, "MEM packet/forward selection=%0d enabled=%0d", selection, enabled);
                checks++;
            end
            // 已带异常的访存沿普通流水送异常；地址或 CSR 候选不能被前递使用。
            in_packet.exc = '{valid:1'b1, cause:EXC_LOAD_ADDR_MISALIGNED, tval:xlen_t'(3)};
            #1;
            assert (out_packet.valid && out_packet.exc == in_packet.exc &&
                    !gpr_forward.valid && !csr_forward.valid)
                else $fatal(1, "early exception forwarded a value or lost metadata");
            in_packet.valid = 0;
            #1;
            assert (!out_packet.valid && !gpr_forward.valid && !csr_forward.valid)
                else $fatal(1, "empty MEM retains ownership");
        end
        $display("PASS tb_mem_stage RV%0d metadata_forward=%0d exceptions=5 empty=5", XLEN, checks);
        $finish;
    end
endmodule
