// Module: tb_fetch_response_capacity
// Description: Fetch FIFO capacity, sustained pair traffic and killed-response ownership at a full boundary.
module tb_fetch_response_capacity #(
    parameter bit EXPECT_LOCAL_CAPACITY = 1
);
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import riscv_priv_pkg::*;
    logic clk = 0, rst = 1, fetch_request_enable = 1, flush = 0;
    redirect_t redirect = '0;
    pred_info_t prediction = '0, prediction_1 = '0;
    xlen_t lookup_pc, lookup_pc_1, imem_req_addr, memory_addr_q, expected_pc;
    logic fetch_fire, fetch_second, imem_req_valid, imem_req_ready, imem_rsp_valid, imem_rsp_ready, busy;
    logic imem_rsp_error, imem_rsp_error_1, memory_active_q = 0, release_response = 1, inject_error = 0;
    logic [63:0] imem_rsp_data;
    if_d1_t out_packet, out_packet_1;
    logic [1:0] pop_count = 0;
    xlen_t target_pc, error_addr;
    int checks = 0, pairs = 0, requests = 0, responses = 0;
    fetch_pair_stage dut (.*);
    always #5 clk = ~clk;
    function automatic logic [31:0] instruction(input xlen_t pc);
        return 32'(pc) ^ 32'hd3c5067f;
    endfunction
    assign imem_rsp_valid = memory_active_q && release_response;
    assign imem_req_ready = !memory_active_q || (imem_rsp_valid && imem_rsp_ready);
    assign imem_rsp_data = {instruction(memory_addr_q+xlen_t'(4)),instruction(memory_addr_q)};
    assign imem_rsp_error = 0;
    assign imem_rsp_error_1 = inject_error && memory_addr_q == error_addr;
    // 存储端持有已接受地址，支持同沿返回旧响应并接受下一请求。
    always_ff @(posedge clk) begin
        if (rst) begin
            memory_active_q <= 0;
            memory_addr_q <= '0;
        end else begin
            if (imem_rsp_valid && imem_rsp_ready) memory_active_q <= 0;
            if (imem_req_valid && imem_req_ready) begin
                memory_active_q <= 1;
                memory_addr_q <= imem_req_addr;
            end
        end
    end
    always @(posedge clk) begin
        if (rst) expected_pc <= RESET_VECTOR;
        else if (redirect.valid) expected_pc <= redirect.pc;
        else begin
            for (int lane = 0; lane < 2; lane++) begin
                if_d1_t packet;
                xlen_t pc;
                packet = lane == 0 ? out_packet : out_packet_1;
                pc = expected_pc+xlen_t'(4*lane);
                if (int'(pop_count) > lane) begin
                    assert (packet.valid && packet.pc == pc && packet.seq_pc == pc+xlen_t'(4) &&
                            packet.inst == instruction(pc)) else $fatal(1,"fetch order/payload mismatch PC=%h expected=%h",packet.pc,pc);
                    assert (packet.exc.valid == (inject_error && pc == target_pc)) else $fatal(1,"fetch error ownership mismatch");
                    if (packet.exc.valid)
                        assert (packet.exc.cause == EXC_INST_ACCESS_FAULT && packet.exc.tval == pc) else $fatal(1,"fetch fault context");
                    checks++;
                end
            end
            expected_pc <= expected_pc+xlen_t'(4*int'(pop_count));
            if (pop_count == 2) pairs++;
        end
        if (!rst && imem_req_valid && imem_req_ready) requests++;
        if (!rst && imem_rsp_valid && imem_rsp_ready) responses++;
    end
    task automatic tick;
        @(posedge clk); @(negedge clk);
    endtask
    task automatic fill;
        pop_count = 0;
        while (int'(dut.occupancy) != FETCH_QUEUE_DEPTH) tick();
        #1; assert (imem_rsp_valid && !imem_rsp_ready) else $fatal(1,"full queue did not retain pending response");
    endtask
    initial begin
        target_pc = RESET_VECTOR+xlen_t'(32'h104);
        error_addr = target_pc & ~xlen_t'(7);
        repeat (3) @(negedge clk); rst = 0;
        fill();
        pop_count = 2;
        #1; assert (imem_rsp_ready == !EXPECT_LOCAL_CAPACITY)
            else $fatal(1,"response capacity policy mismatch");
        $display("CAPACITY RV%0d local=%0d occupancy=%0d pop=%0d ready=%0d",XLEN,EXPECT_LOCAL_CAPACITY,dut.occupancy,pop_count,imem_rsp_ready);
        tick();
        // 本地容量策略仅在满转出边界晚接一拍，后续仍连续双出/双入。
        repeat (8) begin
            #1; assert (out_packet.valid && out_packet_1.valid && imem_rsp_ready && imem_req_valid)
                else $fatal(1,"sustained pair throughput lost");
            tick();
        end
        fill();
        release_response = 0;
        redirect = '{valid:1,pc:target_pc,reason:REDIR_EX_BRANCH};
        tick(); redirect = '0;
        repeat (3) begin
            #1; assert (dut.occupancy == 0 && memory_active_q && dut.killed_q &&
                        imem_rsp_ready && !imem_req_valid) else $fatal(1,"killed response owner not retained");
            tick();
        end
        inject_error = 1; release_response = 1;
        tick(); // 排空旧响应，同沿接收重定向后高 word 请求。
        #1; assert (dut.occupancy == 0 && memory_addr_q == error_addr) else $fatal(1,"redirect request ownership");
        tick();
        #1; assert (dut.occupancy == 1 && out_packet.pc == target_pc && out_packet.exc.valid && !out_packet_1.valid)
            else $fatal(1,"high-word fault packet mismatch");
        pop_count = 1; tick(); pop_count = 0;
        assert (pairs == 9 && checks == 19) else $fatal(1,"fetch coverage missing");
        $display("PASS tb_fetch_response_capacity RV%0d local=%0d checks=%0d pairs=%0d requests=%0d responses=%0d",
                 XLEN,EXPECT_LOCAL_CAPACITY,checks,pairs,requests,responses);
        $finish;
    end
    initial begin #20us; $fatal(1,"fetch capacity timeout"); end
endmodule
