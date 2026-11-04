// Module: tb_scoreboard_boot_prefix
// Description: Checks reset ROM dual intake, dependent JALR, ITCM entry and ordered retirement.
module tb_scoreboard_boot_prefix;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import scoreboard_pkg::*;
    logic clk = 0, rst = 1;
    logic imem_req_valid, imem_req_ready, imem_rsp_valid = 0, imem_rsp_ready;
    xlen_t imem_req_addr;
    logic [63:0] imem_rsp_data = 0;
    logic [1:0] mem_req_valid, mem_rsp_ready, issue_fire;
    memory_request_t mem_request [2];
    memory_response_t mem_response [2] = '{default:'0};
    retire_trace_t trace [2];
    int retired = 0, pair_intake = 0, single_intake = 0, empty_intake = 0;
    xlen_t expected_pc = 0;
    always #5ns clk = ~clk;
    scoreboard_core dut (
        .clk, .rst, .irq_software(1'b0), .irq_timer(1'b0), .irq_external(1'b0),
        .imem_req_valid, .imem_req_addr, .imem_req_ready, .imem_rsp_valid,
        .imem_rsp_data, .imem_rsp_error(1'b0), .imem_rsp_error_1(1'b0), .imem_rsp_ready,
        .mem_req_valid, .mem_req_ready(2'b11), .mem_request,
        .mem_rsp_valid(2'b00), .mem_rsp_ready, .mem_response,
        .commit_valid(), .commit_pc(), .commit_inst(), .commit_rd(), .commit_rd_we(),
        .commit_rd_data(), .commit_exception(), .fence_i_commit(), .commit_trace(trace), .issue_fire
    );
    // ROM跳板与ITCM独立编址，错误路径用ebreak污染，任何错误退休都会终止测试。
    function automatic logic [31:0] instruction(input xlen_t pc);
        case (pc)
            XLEN'(32'h00000000): return 32'h010002b7; // lui t0,0x1000
            XLEN'(32'h00000004): return 32'h00028067; // jalr x0,0(t0)
            XLEN'(32'h01000000): return 32'h0080006f; // jal x0,+8：单条前缀
            XLEN'(32'h01000008): return 32'h00100313; // addi t1,x0,1
            XLEN'(32'h0100000c): return 32'h00200393; // addi t2,x0,2
            XLEN'(32'h01000010): return 32'h00730433; // add s0,t1,t2
            XLEN'(32'h01000014): return 32'h00400413; // addi s0,x0,4：WAW
            XLEN'(32'h01000018): return 32'h0000006f; // jal x0,0
            default: return 32'h00100073;
        endcase
    endfunction
    assign imem_req_ready = !rst && (!imem_rsp_valid || imem_rsp_ready);
    always_ff @(posedge clk) begin
        if (rst) imem_rsp_valid <= 0;
        else begin
            if (imem_rsp_valid && imem_rsp_ready) imem_rsp_valid <= 0;
            if (imem_req_valid && imem_req_ready) begin
                imem_rsp_valid <= 1;
                imem_rsp_data <= {instruction(imem_req_addr + XLEN'(4)), instruction(imem_req_addr)};
            end
        end
    end
    always @(posedge clk) if (!rst) begin
        // 直接检查实际译码入口，防止只检验一份独立表达式而漏掉DUT连接。
        case (dut.fetch_pop_count)
            0: begin
                assert (!dut.decode_intake[0].valid && !dut.decode_intake[1].valid) else $fatal;
                empty_intake++;
            end
            1: begin
                assert (dut.decode_intake[0].valid && !dut.decode_intake[1].valid) else $fatal;
                single_intake++;
            end
            2: begin
                assert (dut.decode_intake[0].valid && dut.decode_intake[1].valid) else $fatal;
                pair_intake++;
            end
            default: $fatal(1, "invalid fetch prefix");
        endcase
        assert (mem_req_valid == 0) else $fatal(1, "unexpected data request");
        for (int lane = 0; lane < 2; lane++) begin
            if (trace[lane].valid) begin
                assert (!trace[lane].exception && trace[lane].pc == expected_pc &&
                        trace[lane].inst == instruction(expected_pc))
                    else $fatal(1, "boot retirement pc=%h expected=%h exc=%b", trace[lane].pc, expected_pc, trace[lane].exception);
                if (expected_pc == XLEN'(32'h01000010))
                    assert (trace[lane].rd_we && trace[lane].rd == 8 && trace[lane].rd_data == 3)
                        else $fatal(1, "RAW forwarding mismatch");
                if (expected_pc == XLEN'(32'h01000014))
                    assert (trace[lane].rd_we && trace[lane].rd == 8 && trace[lane].rd_data == 4)
                        else $fatal(1, "WAW retirement mismatch");
                retired++;
                case (expected_pc)
                    0: expected_pc = 4;
                    4: expected_pc = XLEN'(32'h01000000);
                    XLEN'(32'h01000000): expected_pc = XLEN'(32'h01000008);
                    XLEN'(32'h01000018): expected_pc = XLEN'(32'h01000018);
                    default: expected_pc += XLEN'(4);
                endcase
            end
        end
        if (retired >= 10) begin
            assert (pair_intake > 0 && single_intake > 0 && empty_intake > 0) else $fatal(1,"prefix coverage");
            $display("PASS tb_scoreboard_boot_prefix RV%0d retired=%0d intake_0=%0d intake_1=%0d intake_2=%0d ROM=0,4 ITCM=01000000 RAW/WAW", XLEN, retired, empty_intake, single_intake, pair_intake);
            $finish;
        end
    end
    initial begin
        repeat (5) @(negedge clk);
        rst = 0;
        repeat (2000) @(negedge clk);
        $fatal(1, "board boot prefix timeout retired=%0d", retired);
    end
endmodule
