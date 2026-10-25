// Module: tcm_address_decode
// Description: Parallel local TCM eligibility without full-system target encoding or permission fan-in.
module tcm_address_decode (
    input bus_types_pkg::bus_req_t request,
    output logic itcm_ok,
    output logic dtcm_ok
);
    import core_config_pkg::*;
    import core_types_pkg::*;
    import soc_config_pkg::*;
    import soc_addr_pkg::*;
    // 全 XLEN 比较保留 RV64 高地址拒绝，不能先截成 32 位后命中本地 RAM。
    localparam logic [XLEN-1:0] ITCM_MASK = ~XLEN'(ITCM_BYTES - 1);
    localparam logic [XLEN-1:0] DTCM_MASK = ~XLEN'(DTCM_BYTES - 1);
    logic itcm_hit, dtcm_hit, size_ok, aligned, execute_ok;
    logic [2:0] alignment_mask;
    assign itcm_hit = (request.addr & ITCM_MASK) == XLEN'(ITCM_BASE);
    assign dtcm_hit = (request.addr & DTCM_MASK) == XLEN'(DTCM_BASE);
    always_comb begin
        unique case (request.size)
            MEM_BYTE: alignment_mask = 3'b000;
            MEM_HALF: alignment_mask = 3'b001;
            MEM_WORD: alignment_mask = 3'b011;
            MEM_DWORD: alignment_mask = 3'b111;
            default: alignment_mask = '0;
        endcase
    end
    assign aligned = (request.addr[2:0] & alignment_mask) == 0;
    assign size_ok = request.size != MEM_DWORD || XLEN == 64;
    assign execute_ok = !request.execute || (!request.write && request.size == MEM_WORD);
    // 固定、自然对齐的二次幂窗口无需先做目标编码；非法访问仍交原慢路径报告错误。
    assign itcm_ok = itcm_hit && aligned && size_ok && execute_ok;
    assign dtcm_ok = dtcm_hit && aligned && size_ok && !request.execute;
`ifndef SYNTHESIS
    initial begin
        assert (ITCM_BYTES >= 8 && (ITCM_BYTES & (ITCM_BYTES-1)) == 0 &&
                (ITCM_BASE & (ITCM_BYTES-1)) == 0 &&
                DTCM_BYTES >= 8 && (DTCM_BYTES & (DTCM_BYTES-1)) == 0 &&
                (DTCM_BASE & (DTCM_BYTES-1)) == 0)
            else $fatal(1, "local TCM decode requires aligned power-of-two windows");
    end
`endif
endmodule
