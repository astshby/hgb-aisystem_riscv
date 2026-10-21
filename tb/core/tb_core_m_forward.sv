// Module: tb_core_m_forward
// Description: Checks tagged MDU operands, conservative WAW serialization, and delayed Load overlap.
module tb_core_m_forward;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import rv_asm_pkg::*;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic imem_req_valid, imem_req_ready, imem_rsp_valid, imem_rsp_ready;
    xlen_t imem_req_addr;
    logic [31:0] imem_rsp_data;
    logic dmem_req_valid, dmem_req_ready, dmem_req_write;
    xlen_t dmem_req_addr, dmem_req_wdata, dmem_rsp_rdata;
    logic [DBUS_BYTES-1:0] dmem_req_wstrb;
    logic dmem_rsp_valid, dmem_rsp_ready;
    logic commit_valid, commit_rd_we, commit_exception;
    xlen_t commit_pc, commit_rd_data;
    logic [31:0] commit_inst;
    gpr_addr_t commit_rd;
    logic pending_q, overlap_seen;
    int delay_q, loads, launches;
    int scenario, retired;
    xlen_t expected;
    logic waw_seen, load_retired, completion_seen, m_retired;
    logic load_allocated, load_response_seen;
    retire_id_t m_id;

    always #5 clk = ~clk;
    logic imem_rsp_error = 1'b0;
    logic dmem_rsp_error = 1'b0;
    mem_size_e dmem_req_size;

    core dut (.commit_trace(), .imem_rsp_error_1(1'b0), .fence_i_commit(), .irq_software(1'b0), .irq_timer(1'b0), .irq_external(1'b0), .*);
    sim_imem #(.DEPTH_WORDS(64)) u_imem (
        .clk, .rst, .req_valid(imem_req_valid), .req_addr(imem_req_addr),
        .req_ready(imem_req_ready), .rsp_valid(imem_rsp_valid),
        .rsp_data(imem_rsp_data), .rsp_ready(imem_rsp_ready),
        .rsp_error(), .rsp_error_1()
    );

    // 单槽慢存储器；延迟足以覆盖全部乘除法后端，返回有效后保持到握手。
    assign dmem_req_ready = !pending_q && !dmem_rsp_valid;
    always_ff @(posedge clk) begin
        if (rst) begin
            pending_q <= 1'b0;
            delay_q <= 0;
            dmem_rsp_valid <= 1'b0;
            dmem_rsp_rdata <= '0;
            loads <= 0;
        end else begin
            if (dmem_rsp_valid && dmem_rsp_ready)
                dmem_rsp_valid <= 1'b0;
            if (dmem_req_valid && dmem_req_ready) begin
                assert (!dmem_req_write && dmem_req_addr == '0 && loads == 0)
                    else $fatal(1, "unexpected or repeated memory request");
                pending_q <= 1'b1;
                delay_q <= 2 * XLEN + 9;
                loads <= loads + 1;
            end
            if (pending_q) begin
                if (delay_q == 0) begin
                    pending_q <= 1'b0;
                    dmem_rsp_valid <= 1'b1;
                    dmem_rsp_rdata <= xlen_t'(41);
                end else
                    delay_q <= delay_q - 1;
            end
        end
    end

    // 每个场景只发射一笔 M；ID 包含槽号与代次，完成和退休不得混用旧生产者。
    // 严格 WAW 使场景 2/4 的 ADDI 等 Load 退休，仍须取得后写入的 7，而非 41。
    always @(posedge clk) begin
        if (rst) begin
            launches = 0;
            overlap_seen = 1'b0;
            waw_seen = 1'b0;
            load_retired = 1'b0;
            load_allocated = 1'b0; load_response_seen = 1'b0;
            completion_seen = 1'b0;
            m_retired = 1'b0;
            m_id = '0;
        end else begin
            if (dut.dispatch_valid && dut.dispatch_ready && dut.alloc_meta.pc == 24) load_allocated = 1;
            if (dut.dispatch_waw_stall && dut.d1_d2_q.valid && dut.d1_d2_q.pc == xlen_t'(28))
                waw_seen = 1'b1;
            if (commit_valid && commit_pc == xlen_t'(24)) load_retired = 1'b1;
            if ((scenario == 2 || scenario == 4) && dut.dispatch_valid && dut.dispatch_ready &&
                dut.d1_d2_q.pc == xlen_t'(28))
                assert (load_retired) else $fatal(1, "WAW writer dispatched before old Load retirement");
            if (dut.mdu_req_valid && dut.mdu_req_ready) begin
                assert (launches == 0 && dut.d2_ex_q.pc == xlen_t'(32))
                    else $fatal(1, "unexpected or repeated MDU request");
                launches++;
                m_id = dut.d2_ex_q.retire_id;
                // 非依赖 M 可在 LSU PREP 或 WAIT 发射；覆盖用真实 Load 分配/响应事件，不借全局 stall。
                if (load_allocated && !load_response_seen) overlap_seen = 1'b1;
                if (scenario == 2 || scenario == 4)
                    assert (load_retired) else $fatal(1, "WAW constrained MDU launched before Load retirement");
                if (scenario == 5)
                    assert (load_response_seen) else $fatal(1, "RAW MDU used Load before registered response");
                assert (dut.mdu_request.operand_a ==
                        ((scenario == 1) ? xlen_t'(3) : (scenario == 3) ? xlen_t'(84) :
                         (scenario == 5) ? xlen_t'(41) : xlen_t'(7)) &&
                        dut.mdu_request.operand_b ==
                        ((scenario == 1 || scenario == 3 || scenario == 5) ? xlen_t'(7) : xlen_t'(4)))
                    else $fatal(1, "MDU captured wrong producer case=%0d", scenario);
            end
            if (dut.mdu_complete_valid && dut.mdu_complete_ready) begin
                assert (launches == 1 && !completion_seen && dut.mdu_completion.id == m_id &&
                        dut.mdu_completion.result.gpr_data == expected)
                    else $fatal(1, "MDU completion ID/data mismatch case=%0d", scenario);
                completion_seen = 1'b1;
            end
            if (commit_valid && commit_pc == xlen_t'(32)) begin
                assert (completion_seen && !m_retired && dut.head_id == m_id)
                    else $fatal(1, "MDU retired without its tagged completion");
                m_retired = 1'b1;
            end
            if (dmem_rsp_valid && dmem_rsp_ready) load_response_seen = 1;
        end
    end

    // 分别覆盖 rs1/rs2、同名生产者串行、除法、真实 Load 依赖及 Load 到 x0。
    initial begin
        for (scenario = 0; scenario < 7; scenario++) begin
            @(negedge clk);
            rst = 1'b1;
            for (int i = 0; i < 64; i++) u_imem.mem[i] = nop();
            u_imem.mem[0] = enc_addi(6, 0, 3);
            u_imem.mem[1] = enc_addi(8, 0, (scenario == 3) ? 84 : 4);
            u_imem.mem[6] = enc_lw((scenario == 2 || scenario == 4) ? 6 :
                                      ((scenario == 6) ? 0 : 5), 0, 0);
            u_imem.mem[7] = enc_addi((scenario == 1) ? 8 : 6, 0, 7);
            u_imem.mem[8] = enc_mul(7, 6, 8);
            expected = xlen_t'(28);
            case (scenario)
                1: expected = xlen_t'(21);
                3: begin u_imem.mem[8] = enc_div(7, 8, 6); expected = xlen_t'(12); end
                4: begin u_imem.mem[8] = enc_div(7, 6, 8); expected = xlen_t'(1); end
                5: begin u_imem.mem[8] = enc_mul(7, 5, 6); expected = xlen_t'(287); end
                default: ;
            endcase
            u_imem.mem[9] = enc_jal(0, 0);
            repeat (4) @(posedge clk);
            @(negedge clk);
            rst = 1'b0;
            retired = 0;
            for (int cycle = 0; cycle < 1000; cycle++) begin
                @(negedge clk);
                if (commit_valid) begin
                    assert (!commit_exception && commit_pc == xlen_t'(retired * 4) &&
                            commit_inst == u_imem.mem[retired])
                        else $fatal(1, "M forward case=%0d out-of-order commit pc=%h", scenario, commit_pc);
                    retired++;
                    if (retired == 9) begin
                        assert (commit_rd_we && commit_rd == gpr_addr_t'(7) && commit_rd_data == expected)
                            else $fatal(1, "M forward case=%0d got=%h expected=%h", scenario, commit_rd_data, expected);
                        assert (loads == 1 && launches == 1 &&
                                overlap_seen == !(scenario == 2 || scenario == 4 || scenario == 5) &&
                                ((scenario != 2 && scenario != 4) || waw_seen))
                            else $fatal(1, "M forward coverage case=%0d loads=%0d launches=%0d overlap=%b",
                                        scenario, loads, launches, overlap_seen);
                        break;
                    end
                end
            end
            assert (retired == 9) else $fatal(1, "M forward timeout case=%0d", scenario);
            // 上面的下降沿检查观察待退休输出；再过实际退休沿核验一次完整 ID。
            @(negedge clk);
            assert (completion_seen && m_retired)
                else $fatal(1, "MDU final completion/retirement handshake missing");
        end
        $display("PASS tb_core_m_forward RV%0d cases=7", XLEN);
        $finish;
    end
endmodule
