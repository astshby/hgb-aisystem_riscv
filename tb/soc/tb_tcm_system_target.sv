// Module: tb_tcm_system_target
// Description: AXI TCM permissions, registered write ownership, burst routing and response backpressure.
module tb_tcm_system_target;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import axi_types_pkg::*;
    import bus_types_pkg::*;
    import soc_addr_pkg::*;
    import soc_config_pkg::*;
    logic clk = 0, rst = 1;
    axi_req_t axi_req = '0;
    axi_rsp_t axi_rsp;
    logic [1:0] req_valid, req_ready, rsp_valid, rsp_ready;
    bus_req_t request [2];
    logic [63:0] rsp_data [2];
    logic [1:0] pending_q;
    int delay_q [2];
    int cycles = 0, checks = 0, reads = 0, writes = 0, errors = 0;
    int bank_reads [2], bank_writes [2];
    logic [31:0] bases [4];

    always #5 clk = ~clk;
    tcm_system_target dut (.*);
    // 两块独立本地响应模型插入不同反压；不使用 DUT 的地址译码来决定许可。
    for (genvar b = 0; b < 2; b++) begin : g_response
        assign req_ready[b] = !rst && !pending_q[b] && cycles % (23+b) > 11;
        assign rsp_valid[b] = pending_q[b] && delay_q[b] == 0;
        bus_req_t held_request_q;
        logic stalled_q = 0;
        always @(posedge clk) begin
            if (!rst && stalled_q)
                assert (req_valid[b] && request[b] == held_request_q)
                    else $fatal(1, "local TCM request changed under backpressure bank=%0d", b);
            stalled_q = !rst && req_valid[b] && !req_ready[b];
            held_request_q = request[b];
        end
        always_ff @(posedge clk) begin
            if (rst) begin
                pending_q[b] <= 0;
                delay_q[b] <= 0;
                rsp_data[b] <= 0;
                bank_reads[b] <= 0;
                bank_writes[b] <= 0;
            end else begin
                if (delay_q[b] != 0) delay_q[b] <= delay_q[b]-1;
                if (rsp_valid[b] && rsp_ready[b]) pending_q[b] <= 0;
                if (req_valid[b] && req_ready[b]) begin
                    assert (!pending_q[b]) else $fatal(1, "local request ownership overwritten");
                    pending_q[b] <= 1;
                    delay_q[b] <= 2+b;
                    rsp_data[b] <= 64'h5a73c209d41e860f ^ 64'(request[b].addr);
                    if (request[b].write) bank_writes[b] <= bank_writes[b]+1;
                    else bank_reads[b] <= bank_reads[b]+1;
                end
            end
        end
    end
    always @(posedge clk) begin
        cycles <= cycles+1;
        if (!rst) begin
            assert ($onehot0(req_valid)) else $fatal(1, "TCM request reached two regions");
            checks++;
        end
    end
    task automatic read_case(input logic [31:0] address, input int size, beats,
                             input bit execute, input axi_resp_e expected);
        axi_r_t held;
        axi_id_t id;
        id = axi_id_t'(reads+3);
        @(negedge clk);
        axi_req.ar_valid = 1;
        axi_req.ar = '{id:id,addr:address,len:8'(beats-1),size:3'(size),burst:1,
                       prot:execute ? 3'b100 : 3'b000,default:'0};
        do @(posedge clk); while (!axi_rsp.ar_ready);
        @(negedge clk); axi_req.ar_valid = 0;
        for (int beat = 0; beat < beats; beat++) begin
            while (!axi_rsp.r_valid) @(negedge clk);
            held = axi_rsp.r;
            repeat (4) begin
                @(negedge clk);
                assert (axi_rsp.r_valid && axi_rsp.r == held) else $fatal(1, "TCM R changed under backpressure");
            end
            assert (axi_rsp.r.id == id && axi_rsp.r.resp == expected && axi_rsp.r.last == (beat == beats-1))
                else $fatal(1, "TCM R frame address=%h size=%0d execute=%0d response=%0d expected=%0d",
                            address,size,execute,axi_rsp.r.resp,expected);
            axi_req.r_ready = 1;
            @(posedge clk); @(negedge clk); axi_req.r_ready = 0;
        end
        reads++;
        if (expected != AXI_OKAY) errors++;
    endtask
    task automatic write_case(input logic [31:0] address, input int size, beats,
                              input bit data_first, input axi_resp_e expected);
        axi_b_t held;
        axi_id_t id;
        id = axi_id_t'(writes+7);
        @(negedge clk);
        axi_req.aw = '{id:id,addr:address,len:8'(beats-1),size:3'(size),burst:1,default:'0};
        // AW/W 分开握手，覆盖数据先到、地址先到及多拍拆分。
        if (!data_first) begin
            axi_req.aw_valid = 1;
            do @(posedge clk); while (!axi_rsp.aw_ready);
            @(negedge clk); axi_req.aw_valid = 0;
        end
        for (int beat = 0; beat < beats; beat++) begin
            axi_req.w_valid = 1;
            axi_req.w = '{data:{8{32'h91c4e207 ^ 32'(beat)}},
                          strb:(32'hffffffff >> (32-(1 << size))) << ((address + (32'(beat) << size)) % 32),last:beat == beats-1};
            do @(posedge clk); while (!axi_rsp.w_ready);
            @(negedge clk); axi_req.w_valid = 0;
            if (data_first && beat == 0) begin
                repeat (3) @(negedge clk);
                axi_req.aw_valid = 1;
                do @(posedge clk); while (!axi_rsp.aw_ready);
                @(negedge clk); axi_req.aw_valid = 0;
            end
        end
        while (!axi_rsp.b_valid) @(negedge clk);
        held = axi_rsp.b;
        repeat (5) begin
            @(negedge clk);
            assert (axi_rsp.b_valid && axi_rsp.b == held) else $fatal(1, "TCM B changed under backpressure");
        end
        assert (axi_rsp.b.id == id && axi_rsp.b.resp == expected)
            else $fatal(1, "TCM B address=%h size=%0d response=%0d expected=%0d",address,size,axi_rsp.b.resp,expected);
        axi_req.b_ready = 1;
        @(posedge clk); @(negedge clk); axi_req.b_ready = 0;
        writes++;
        if (expected != AXI_OKAY) errors++;
    endtask
    initial begin
        bases = '{ITCM_BASE,DTCM_BASE,ROM_BASE,UART0_BASE};
        repeat (4) @(negedge clk); rst = 0;
        for (int region = 0; region < 4; region++) begin
            for (int size = 0; size <= 5; size++) begin
                read_case(bases[region],size,1,0,region < 2 ? AXI_OKAY : AXI_SLVERR);
                read_case(bases[region],size,1,1,region == 0 && size >= 2 ? AXI_OKAY : AXI_SLVERR);
                write_case(bases[region],size,1,1'(size),region < 2 ? AXI_OKAY : AXI_SLVERR);
            end
        end
        read_case(ITCM_BASE-4,2,1,0,AXI_SLVERR);
        read_case(ITCM_BASE+ITCM_BYTES-4,2,1,0,AXI_OKAY);
        read_case(ITCM_BASE+ITCM_BYTES-4,3,1,0,AXI_SLVERR);
        read_case(DTCM_BASE+DTCM_BYTES-4,2,1,0,AXI_OKAY);
        read_case(DTCM_BASE+DTCM_BYTES,2,1,0,AXI_SLVERR);
        read_case(ITCM_BASE+1,1,1,0,AXI_SLVERR);
        read_case(DTCM_BASE+2,2,1,0,AXI_SLVERR);
        read_case(32'hffffffff,2,1,0,AXI_SLVERR);
        write_case(ITCM_BASE+ITCM_BYTES,2,1,1,AXI_SLVERR);
        write_case(DTCM_BASE+DTCM_BYTES-4,2,1,0,AXI_OKAY);
        for (int size = 0; size <= 4; size++) begin
            write_case(ITCM_BASE+64-(1 << size),size,4,1,AXI_OKAY);
            write_case(DTCM_BASE+64-(1 << size),size,4,0,AXI_OKAY);
        end
        write_case(ITCM_BASE+128,5,2,1,AXI_OKAY);
        write_case(DTCM_BASE+128,5,2,0,AXI_OKAY);
        // 同时悬挂读写，检查 AXI scalar 交替许可和 region/response owner 不串扰。
        fork
            read_case(ITCM_BASE+256,5,3,0,AXI_OKAY);
            write_case(DTCM_BASE+256,5,3,1,AXI_OKAY);
        join
        assert (bank_reads[0] > 0 && bank_reads[1] > 0 && bank_writes[0] > 0 && bank_writes[1] > 0 && errors > 0)
            else $fatal(1, "TCM region/error coverage missing");
        $display("PASS tb_tcm_system_target RV%0d checks=%0d reads=%0d writes=%0d errors=%0d bank_reads=%0d/%0d bank_writes=%0d/%0d",
                 XLEN,checks,reads,writes,errors,bank_reads[0],bank_reads[1],bank_writes[0],bank_writes[1]);
        $finish;
    end
    initial begin #2ms; $fatal(1, "TCM system target timeout"); end
endmodule
