// Module: tb_coremark_tcm
// Description: Executes a preloaded program on the same real TCM composition used by PDS.
module tb_coremark_tcm #(
    parameter real CORE_PERIOD_PS = 10000
);
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    logic clk_core=0, rst_core=1;
    // 累计绝对边沿，分数周期只在当前边沿量化，避免逐半拍取整漂移。
    initial begin
        realtime origin, edge_time;
        longint unsigned edge_count;
        assert (CORE_PERIOD_PS > 0) else $fatal(1,"invalid core clock period");
        origin=$realtime; edge_count=0;
        forever begin
            edge_count++;
            edge_time=origin+real'(edge_count)*CORE_PERIOD_PS*0.5ps;
            #(edge_time-$realtime); clk_core=!clk_core;
        end
    end
    logic commit_valid, commit_rd_we, commit_exception, dmem_store_fire;
    xlen_t commit_pc, commit_rd_data, dmem_store_addr, dmem_store_data;
    logic [31:0] commit_inst;
    logic [4:0] commit_rd;
    logic [DBUS_BYTES-1:0] dmem_store_strb;
    pipeline_pkg::retire_trace_t commit_trace [2];
    benchmark_core_tcm dut (.*);

    xlen_t result_addr, console_addr;
    logic test_done, test_pass;
    logic [31:0] test_code;
    int cycles=0, max_cycles;
    string imem_path, dmem_path, test_name;
    store_result_monitor u_result_monitor (
        .clk(clk_core),.rst(rst_core),.result_addr,.dmem_store_fire,
        .dmem_store_addr,.dmem_store_data,.dmem_store_strb,
        .store_request_id(dut.u_hot.u_core.store_request_id),
        .store_response_fire(dut.u_hot.u_core.store_response_fire),
        .store_response_error(dut.u_hot.u_core.store_response_error),
        .store_response_id(dut.u_hot.u_core.store_response_id),
        .store_retire_fire(dut.u_hot.u_core.queue_retire_fire && dut.u_hot.u_core.head_meta.kind==pipeline_pkg::RET_STORE),
        .store_retire_error(dut.u_hot.u_core.head_result.exc.valid),.store_retire_id(dut.u_hot.u_core.head_id),
        .cancel(dut.u_hot.u_core.wb_redirect.valid),.test_done,.test_pass,.test_code);
    always @(posedge clk_core) begin
        if (!rst_core) begin
            cycles<=cycles+1;
            if (dmem_store_fire && dmem_store_addr==console_addr && dmem_store_strb[dmem_store_addr[$clog2(DBUS_BYTES)-1:0]])
                $write("%c",dmem_store_data[8*dmem_store_addr[$clog2(DBUS_BYTES)-1:0]+:8]);
        end
    end
    initial begin
        $display("P2_CORE xlen=%0d backend=scoreboard issue_width=%0d retire_entries=%0d split_issue_queue=%0d integer_queue_entries=%0d memory_queue_entries=%0d limited_integer_ooo=%0d scheduler_forward_mode=%0d predictor_mode=%0d ras_enable=%0d mul_impl=%0d div_impl=%0d",
            XLEN,ISSUE_WIDTH,RETIRE_ENTRIES,SPLIT_ISSUE_QUEUE,ISSUE_QUEUE_ENTRIES,
            MEMORY_QUEUE_ENTRIES,LIMITED_INTEGER_OOO,SCHEDULER_FORWARD_MODE,PREDICTOR_MODE,RAS_ENABLE,MUL_IMPL,DIV_IMPL);
        $display("UNIFIED_TCM core_period_ps=%0.6f itcm_bytes=65536 dtcm_bytes=65536 cache=0 ddr=0",CORE_PERIOD_PS);
        if (!$value$plusargs("IMEM=%s",imem_path) || !$value$plusargs("DMEM=%s",dmem_path) ||
            !$value$plusargs("TOHOST=%h",result_addr)) $fatal(1,"missing image/tohost");
        if (!$value$plusargs("CONSOLE=%h",console_addr)) console_addr='1;
        if (!$value$plusargs("TEST=%s",test_name)) test_name="core-tcm";
        if (!$value$plusargs("MAX_CYCLES=%d",max_cycles)) max_cycles=100000000;
        dut.u_hot.g_tcm[0].u_ram.load_image(imem_path);
        dut.u_hot.g_tcm[1].u_ram.load_image(dmem_path);
        repeat (10) @(negedge clk_core);
        rst_core=0;
        while (cycles<max_cycles) begin
            @(negedge clk_core);
            if (test_done) begin
                assert(test_pass) else $fatal(1,"FAIL %s code=%0d pc=%h",test_name,test_code,commit_pc);
                $display("PASS %s RV%0d cycles=%0d",test_name,XLEN,cycles);
                $finish;
                break;
            end
        end
        if (!test_done) $fatal(1,"TIMEOUT %s pc=%h",test_name,commit_pc);
    end
endmodule
