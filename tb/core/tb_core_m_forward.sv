// Module: tb_core_m_forward
// Description: Checks MDU operand capture and youngest-producer priority during delayed WB loads.
module tb_core_m_forward;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
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

    always #5 clk = ~clk;
    core dut (.*);
    sim_imem #(.DEPTH_WORDS(64)) u_imem (
        .clk, .rst, .req_valid(imem_req_valid), .req_addr(imem_req_addr),
        .req_ready(imem_req_ready), .rsp_valid(imem_rsp_valid),
        .rsp_data(imem_rsp_data), .rsp_ready(imem_rsp_ready)
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

    // 启动只允许一次。依赖 WB 的场景必须等返回，其余场景应能与 WB 等待重叠。
    always_ff @(posedge clk) begin
        if (rst) begin
            launches <= 0;
            overlap_seen <= 1'b0;
        end else if (dut.u_ex_stage.u_ex_mdu.req_valid && dut.u_ex_stage.u_ex_mdu.req_ready) begin
            launches <= launches + 1;
            if (dut.wb_wait)
                overlap_seen <= 1'b1;
            if (scenario == 5)
                assert (!dut.wb_wait) else $fatal(1, "dependent MDU launched before WB response");
        end
    end

    // 分别覆盖 rs1/rs2、MEM 覆盖 WB 同名写入、除法、真实 WB 依赖及 Load 到 x0。
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
                        assert (loads == 1 && launches == 1 && overlap_seen == (scenario != 5))
                            else $fatal(1, "M forward coverage case=%0d loads=%0d launches=%0d overlap=%b",
                                        scenario, loads, launches, overlap_seen);
                        break;
                    end
                end
            end
            assert (retired == 9) else $fatal(1, "M forward timeout case=%0d", scenario);
        end
        $display("PASS tb_core_m_forward RV%0d cases=7", XLEN);
        $finish;
    end
endmodule
