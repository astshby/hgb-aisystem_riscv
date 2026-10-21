// Module: tb_tcm_local_fabric
// Description: Checks locked-D handshakes with late DMA, I withdrawal and D-ready independence.
module tb_tcm_local_fabric;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import bus_types_pkg::*;
    logic clk = 0, rst = 1;
    always #5 clk = ~clk;
    logic [2:0] m_req_valid = '0, m_req_ready, m_bank = '0;
    logic [2:0] m_rsp_valid, m_rsp_ready = '1;
    bus_req_t m_request [3];
    bus_rsp_t m_response [3];
    logic [1:0] s_req_valid, s_req_ready = '1, s_rsp_valid = '0, s_rsp_ready;
    bus_req_t s_request [2];
    bus_rsp_t s_response [2];
    int accepted [3], completed [3];
    tcm_local_fabric dut (.*);
    always @(posedge clk) begin
        if (rst) begin
            for (int m = 0; m < 3; m++) begin accepted[m] = 0; completed[m] = 0; end
        end else begin
            assert ($countones(m_req_valid & m_req_ready) == $countones(s_req_valid & s_req_ready))
                else $fatal(1, "local fabric accepted a request without its source handshake");
            for (int m = 0; m < 3; m++) begin
                if (m_req_valid[m] && m_req_ready[m]) accepted[m]++;
                if (m_rsp_valid[m] && m_rsp_ready[m]) completed[m]++;
                assert (accepted[m] >= completed[m] && accepted[m]-completed[m] <= 1)
                    else $fatal(1, "local fabric outstanding/owner");
            end
        end
    end
    task automatic tick;
        @(posedge clk);
        @(negedge clk);
    endtask
    initial begin
        for (int m = 0; m < 3; m++) begin
            m_request[m] = '0;
            m_request[m].addr = xlen_t'(soc_addr_pkg::ITCM_BASE + 4*m);
            m_request[m].size = MEM_WORD;
        end
        for (int b = 0; b < 2; b++) s_response[b] = '0;
        repeat (3) tick();
        rst = 0;
        // D 先完成一笔，使轮询指针自然指向 DMA；不 force 内部状态。
        m_req_valid = 3'b010;
        tick();
        m_req_valid = '0;
        s_rsp_valid = 2'b01;
        tick();
        s_rsp_valid = '0;
        assert (accepted[1] == 1 && completed[1] == 1) else $fatal(1, "setup D request");
        s_req_ready = 2'b10;
        m_req_valid = 3'b010;
        tick();
        assert (s_req_valid[0] && s_request[0] == m_request[1] && !m_req_ready[1])
            else $fatal(1, "D was not locked under backpressure");
        // DMA 后到，但先前锁定的 D 必须同时获得 bank 和源端握手。
        m_req_valid = 3'b110;
        s_req_ready = '1;
        #1;
        assert (m_req_ready[1] && !m_req_ready[2] && s_request[0] == m_request[1])
            else $fatal(1, "late DMA suppressed locked D-ready");
        tick();
        m_req_valid = 3'b100;
        s_rsp_valid = 2'b01;
        #1;
        assert (m_rsp_valid[1] && m_req_ready[2]) else $fatal(1, "D/DMA response-edge handoff");
        tick();
        m_req_valid = '0;
        tick();
        s_rsp_valid = '0;
        assert (accepted[1] == 2 && completed[1] == 2 && accepted[2] == 1 && completed[2] == 1)
            else $fatal(1, "locked D/DMA request counts");

        // 空闲 D-ready 不读取 I-valid；IF 在未被接受时撤回，锁在下一沿释放。
        m_req_valid = 3'b010;
        #1;
        assert (m_req_ready[1]) else $fatal(1, "D ready without I");
        m_req_valid[0] = 1;
        #1;
        assert (m_req_ready[1]) else $fatal(1, "D ready depends on I valid");
        m_req_valid = 3'b001;
        s_req_ready = 2'b10;
        tick();
        m_req_valid = 3'b010;
        s_req_ready = '1;
        #1;
        assert (!m_req_ready[1] && !s_req_valid[0]) else $fatal(1, "withdrawn IF lock handed off combinationally");
        tick();
        #1;
        assert (m_req_ready[1]) else $fatal(1, "withdrawn IF lock did not release");
        tick();
        m_req_valid = '0;
        s_rsp_valid = 2'b01;
        tick();
        s_rsp_valid = '0;
        assert (accepted[0] == 0 && accepted[1] == completed[1] && accepted[2] == completed[2])
            else $fatal(1, "unaccepted IF acquired ownership");
        $display("PASS tb_tcm_local_fabric RV%0d locked_d_late_dma=1 withdrawal=1 data_ready_independent=1", XLEN);
        $finish;
    end
    initial begin
        repeat (1000) @(posedge clk);
        $fatal(1, "local fabric timeout");
    end
endmodule
