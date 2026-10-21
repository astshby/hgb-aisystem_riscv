// Module: tb_ddr_port_arbiter
// Description: Independently checks accepted-owner routing, held payloads and round-robin progress.
module tb_ddr_port_arbiter;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import bus_types_pkg::*;
    logic clk = 0, rst = 1;
    always #5 clk = ~clk;
    logic cpu_req_valid, cpu_req_ready, cpu_rsp_valid, cpu_rsp_ready;
    logic dma_req_valid, dma_req_ready, dma_rsp_valid, dma_rsp_ready;
    logic req_valid, req_ready, rsp_valid, rsp_ready;
    bus_req_t cpu_request;
    bus_rsp_t cpu_response;
    ddr_req_t dma_request, request;
    ddr_rsp_t dma_response, response;
    bit cpu_enable = 0, dma_enable = 0, force_request_stall = 1;
    bit pending = 0, model_owner = 0, had_owner = 0, last_owner = 1;
    bit request_held = 0, response_held = 0;
    ddr_req_t held_request;
    ddr_rsp_t held_response;
    int cycle = 0, delay_q = 0, accepts [2] = '{0,0}, replies [2] = '{0,0};
    int offer_cycle [2] = '{-1,-1}, max_offer_wait [2] = '{0,0};
    int locked_checks = 0, held_responses = 0, fair_checks = 0;
    ddr_port_arbiter dut (.*);

    // 两端连续提供各 12 笔，载荷由 TB 构造；服务顺序不能从 DUT selected/owner 推导。
    assign cpu_req_valid = cpu_enable && accepts[0] < 12;
    assign dma_req_valid = dma_enable && accepts[1] < 12;
    assign req_ready = !rst && !force_request_stall && !pending && cycle % 4 != 0;
    assign cpu_rsp_ready = !rst && cycle % 5 >= 2;
    assign dma_rsp_ready = !rst && cycle % 7 >= 3;
    assign rsp_valid = !rst && pending && delay_q == 0;
    always_comb begin
        cpu_request = '0;
        cpu_request.addr = xlen_t'(32'h80000018);
        cpu_request.size = MEM_WORD;
        dma_request = '0;
        dma_request.addr = xlen_t'(32'h80001000);
        dma_request.size = 5;
        response = '0;
        for (int b = 0; b < 32; b++) response.rdata[b*8 +: 8] = 8'(b + (model_owner ? 64 : 0));
    end
    // 驱动 valid/ready/载荷的模型状态只在 NBA 更新；检查读取采样沿旧值，避免 TB 撤回当沿握手。
    always @(posedge clk) begin
        cycle <= cycle + 1;
        if (!rst) begin
            if (request_held) begin
                assert (req_valid && request == held_request) else $fatal(1, "DDR held grant/payload changed");
                locked_checks++;
            end
            if (response_held) begin
                assert (rsp_valid && response == held_response) else $fatal(1, "DDR held response changed");
                held_responses++;
            end
            request_held = req_valid && !req_ready; held_request = request;
            response_held = rsp_valid && !rsp_ready; held_response = response;
            if (cpu_req_valid && offer_cycle[0] < 0) offer_cycle[0] = cycle;
            if (dma_req_valid && offer_cycle[1] < 0) offer_cycle[1] = cycle;
            if (cpu_rsp_valid || dma_rsp_valid) begin
                assert (pending && cpu_rsp_valid != dma_rsp_valid && dma_rsp_valid == model_owner)
                    else $fatal(1, "response routed to a different accepted owner");
                if (model_owner) assert (dma_response == response) else $fatal(1, "wide response truncated");
                else begin
                    for (int b = 0; b < DBUS_BYTES; b++)
                        assert (cpu_response.rdata[b*8 +: 8] == 8'(24+b)) else $fatal(1, "CPU response lane mismatch");
                end
            end
            if (rsp_valid && rsp_ready) begin
                replies[int'(model_owner)] <= replies[int'(model_owner)] + 1;
                pending <= 0;
            end
            if (req_valid && req_ready) begin
                bit accepted_owner;
                accepted_owner = request.addr == xlen_t'(32'h80001000);
                assert (!pending && (cpu_req_valid && cpu_req_ready) != (dma_req_valid && dma_req_ready) &&
                        accepted_owner == (dma_req_valid && dma_req_ready))
                    else $fatal(1, "downstream fire not paired with exactly one upstream fire");
                if (!had_owner) assert (!accepted_owner) else $fatal(1, "late DMA replaced locked CPU offer");
                else if (cpu_req_valid && dma_req_valid) begin
                    assert (accepted_owner != last_owner) else $fatal(1, "round robin bypassed waiting peer");
                    fair_checks++;
                end
                assert (request.size == (accepted_owner ? 5 : 2)) else $fatal(1, "CPU narrow access widened");
                if (cycle-offer_cycle[int'(accepted_owner)] > max_offer_wait[int'(accepted_owner)])
                    max_offer_wait[int'(accepted_owner)] = cycle-offer_cycle[int'(accepted_owner)];
                offer_cycle[int'(accepted_owner)] = -1;
                accepts[int'(accepted_owner)] <= accepts[int'(accepted_owner)] + 1;
                model_owner <= accepted_owner;
                last_owner = accepted_owner; had_owner = 1;
                pending <= 1; delay_q <= 3;
            end else if (pending && delay_q != 0) delay_q <= delay_q - 1;
            for (int m = 0; m < 2; m++)
                assert (accepts[m] >= replies[m] && accepts[m]-replies[m] <= 1)
                    else $fatal(1, "owner accepted twice before reply");
        end
    end
    task automatic tick;
        @(posedge clk); @(negedge clk);
    endtask
    initial begin
        repeat (4) tick(); rst = 0; cpu_enable = 1;
        repeat (3) tick(); dma_enable = 1;
        repeat (3) tick(); force_request_stall = 0;
        for (int i = 0; i < 600 && replies[0]+replies[1] < 24; i++) tick();
        assert (accepts[0] == 12 && accepts[1] == 12 && replies[0] == 12 && replies[1] == 12 &&
                fair_checks >= 20 && locked_checks >= 5 && held_responses > 0 &&
                max_offer_wait[0] < 40 && max_offer_wait[1] < 40)
            else $fatal(1, "arbiter coverage/progress failure req=%p rsp=%p fair=%0d held=%0d/%0d waits=%p",
                        accepts, replies, fair_checks, locked_checks, held_responses, max_offer_wait);
        $display("PASS tb_ddr_port_arbiter RV%0d CPU=%0d DMA=%0d fair=%0d req_hold=%0d rsp_hold=%0d max_offer=%p",
                 XLEN, replies[0], replies[1], fair_checks, locked_checks, held_responses, max_offer_wait);
        $finish;
    end
endmodule
