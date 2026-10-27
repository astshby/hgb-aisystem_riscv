// Module: tb_soc_independent_boot
// Description: Actual CPU ROM/TCM/MMIO boot with stopped DDR, then in-flight AXI epoch recovery.
module tb_soc_independent_boot;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import axi_types_pkg::*;
    parameter int CLOCK_PROFILE = 1;
    logic ref_clk=0, clk_core=0, clk_sys=0, clk_ddr=0, clk_periph=0;
    logic board_reset_n=0, soc_pll_locked=0, ddr_pll_locked=0, ddr_phy_locked=0;
    logic ddr_ready=0, ddr_run=0, reset_async, ddr_reset_n;
    logic [31:0] gpio_in[3]='{default:'0};
    axi_req_t external_req='0, ddr_req;
    axi_rsp_t external_rsp, ddr_rsp='0;
    pipeline_pkg::retire_trace_t trace[2];
    int rom_count=0, info_count=0, loops=0;
    always #4ns ref_clk=~ref_clk;
    always #5ns clk_core=~clk_core;
    always #(CLOCK_PROFILE == 4 ? 5ns : 6.25ns) clk_sys=~clk_sys;
    always #20ns clk_periph=~clk_periph;
    always begin
        #4ns;
        if(ddr_run) clk_ddr=~clk_ddr;
        else clk_ddr=0;
    end
    pango_soc_reset supervisor (.*);
    soc_system #(.DDR_BYTES(65536), .CLOCK_INFO_ENABLE(1), .CORE_CLOCK_HZ(100000000),
        .SYS_CLOCK_HZ(CLOCK_PROFILE == 4 ? 100000000 : 80000000),
        .DDR_CLOCK_HZ(125000000), .PERIPH_CLOCK_HZ(25000000)) dut (
        .clk_core, .clk_sys, .clk_ddr, .clk_periph, .reset_async, .ddr_ready,
        .uart_rx(2'b11), .uart_tx(), .gpio_in, .gpio_out(), .gpio_oe(),
        .flash_cs_n(), .flash_sck(), .flash_mosi(), .flash_miso(1'b0),
        .ddr_req, .ddr_rsp, .external_req, .external_rsp, .npu_req(), .npu_rsp('0),
        .commit_valid(), .commit_pc(), .commit_inst(), .commit_rd(), .commit_rd_we(),
        .commit_rd_data(), .commit_exception(), .commit_trace(trace),
        .dmem_store_fire(), .dmem_store_addr(), .dmem_store_data(), .dmem_store_strb());
    always @(posedge clk_core) begin
        if(!dut.rst_core) begin
            for(int p=0;p<2;p++) begin
                if(trace[p].valid) begin
                    assert(!trace[p].exception) else $fatal(1,"boot exception pc=%h",trace[p].pc);
                    if(trace[p].pc==0) rom_count++;
                    if(trace[p].rd_we && trace[p].rd==7) begin
                        assert(trace[p].rd_data==XLEN'(XLEN)) else $fatal(1,"MMIO XLEN read mismatch");
                        info_count++;
                    end
                    if(trace[p].pc==XLEN'(32'h01000010)) loops++;
                end
            end
        end
    end
    task automatic read_ddr(input logic [3:0] id, input bit expect_error);
        @(negedge clk_sys);
        external_req.ar_valid=1;
        external_req.ar='0;
        external_req.ar.id=id;
        external_req.ar.addr=32'h80000000;
        external_req.ar.size=2;
        external_req.ar.burst=2'b01;
        external_req.r_ready=0;
        do @(posedge clk_sys); while(!external_rsp.ar_ready);
        @(negedge clk_sys);
        external_req.ar_valid=0;
        if(expect_error) begin
            wait(external_rsp.r_valid);
            @(negedge clk_sys);
            assert(external_rsp.r.id==id && external_rsp.r.last && external_rsp.r.resp==AXI_DECERR)
                else $fatal(1,"DDR response id=%0d expected=%0d last=%0b resp=%0d",
                            external_rsp.r.id,id,external_rsp.r.last,external_rsp.r.resp);
            external_req.r_ready=1;
            @(negedge clk_sys);
            external_req.r_ready=0;
        end
    endtask
    initial begin
        logic [31:0] program_words[8];
        program_words='{32'h00100293,32'h10040337,32'h00032383,32'h00000013,
                        32'h00128293,32'hffdff06f,32'h00000013,32'h00000013};
        for(int i=0;i<8;i++) begin
            dut.g_tcm[0].u_ram.g_bank[0].mem[i]='0;
            dut.g_tcm[0].u_ram.g_bank[1].mem[i]='0;
        end
        for(int i=0;i<8;i++) begin
            if(XLEN==32) begin
                if(i%2==0) dut.g_tcm[0].u_ram.g_bank[0].mem[i/2]=XLEN'(program_words[i]);
                else dut.g_tcm[0].u_ram.g_bank[1].mem[i/2]=XLEN'(program_words[i]);
            end else begin
                if((i/2)%2==0) dut.g_tcm[0].u_ram.g_bank[0].mem[i/4] |= XLEN'(program_words[i]) << (32*(i%2));
                else dut.g_tcm[0].u_ram.g_bank[1].mem[i/4] |= XLEN'(program_words[i]) << (32*(i%2));
            end
        end
        repeat(8) @(negedge ref_clk);
        board_reset_n=1; soc_pll_locked=1;
        wait(loops>=20 && info_count==1);
        assert(rom_count==1 && dut.rst_ddr && !ddr_ready) else $fatal(1,"CPU did not boot independently");
        read_ddr(4'd2,1);
        $display("PASS ROM TCM MMIO and DDR unavailable error while DDR clock stopped RV%0d C%0d",XLEN,CLOCK_PROFILE);
        @(negedge ref_clk);
        ddr_run=1; ddr_ready=1; ddr_pll_locked=1; ddr_phy_locked=1;
        repeat(40) @(negedge ref_clk);
        read_ddr(4'd3,0);
        wait(ddr_req.ar_valid);
        assert(!external_rsp.r_valid) else $fatal(1,"unexpected in-flight response");
        @(negedge ref_clk);
        ddr_phy_locked=0;
        wait(reset_async);
        @(negedge ref_clk);
        external_req='0;
        ddr_ready=0; ddr_pll_locked=0; ddr_run=0;
        wait(info_count==2 && rom_count==2);
        assert(!external_rsp.r_valid) else $fatal(1,"old epoch response survived restart");
        // 主端本地 ID 只有低两位，高两位由 fabric 填入来源；新 epoch 使用不同合法 ID。
        read_ddr(4'd1,1);
        $display("PASS CPU restart and AXI old epoch discard RV%0d C%0d",XLEN,CLOCK_PROFILE);
        $finish;
    end
    initial begin
        #200us;
        $fatal(1,"independent boot timeout rom=%0d info=%0d loops=%0d",rom_count,info_count,loops);
    end
endmodule
