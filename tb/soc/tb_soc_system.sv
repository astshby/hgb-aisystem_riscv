// Module: tb_soc_system
// Description: Executes unchanged software images on the integrated four-clock AXI SoC.
module tb_soc_system #(
    parameter int DDR_BYTES=262144,
    parameter int DDR_MODEL_BYTES=DDR_BYTES,
    parameter int FLASH_BYTES=65536,
    parameter int CLOCK_HZ=100000000,
    parameter int UART_DIVISOR=4,
    parameter int CLOCK_PROFILE=1,
    parameter int CORE_PERIOD_PS=0,
    parameter int SYS_PERIOD_PS=0,
    parameter int DDR_PERIOD_PS=0,
    parameter int PERIPH_PERIOD_PS=0,
    parameter bit NPU_ENABLE=0,
    parameter bit MM3_ENABLE=0,
    parameter int MM3_MAC_LANES=16,
    parameter bit AUTO_FINISH=1,
    parameter int NPU_PERIOD_PS=10000,
    parameter int SOC_PROFILE=soc_config_pkg::SOC_PROFILE_FULL,
    parameter bit ICACHE_ENABLE=1,
    parameter bit DCACHE_ENABLE=1,
    parameter bit LOCAL_TCM_ENABLE=1,
    parameter bit DMA_WIDE_ENABLE=1,
    parameter bit DMA_BLOCK_ENABLE=1,
    parameter bit CACHE_BLOCK_ENABLE=1,
    parameter int RESULT_BYTES=4
);
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import axi_types_pkg::*;
    // 每个模型固定一个硬件时钟配置；运行时选项仅校验，不能改时钟却留下旧寄存器元数据。
    function automatic int period_ps(input int domain_index);
        case (domain_index)
            0: if (CORE_PERIOD_PS > 0) return CORE_PERIOD_PS;
            1: if (SYS_PERIOD_PS > 0) return SYS_PERIOD_PS;
            2: if (DDR_PERIOD_PS > 0) return DDR_PERIOD_PS;
            3: if (PERIPH_PERIOD_PS > 0) return PERIPH_PERIOD_PS;
            default: return 0;
        endcase
        case(CLOCK_PROFILE)
            0: return 10000;
            1: case(domain_index) 0:return 10000; 1:return 12500; 2:return 8000; default:return 40000; endcase
            2: case(domain_index) 0:return 8000; 1:return 10000; 2:return 12500; default:return 25000; endcase
            3: case(domain_index) 0:return 11764; 1:return 8548; 2:return 10752; default:return 27028; endcase
            4: case(domain_index) 0,1:return 10000; 2:return 8000; default:return 40000; endcase
            default:return 0;
        endcase
    endfunction
    function automatic int frequency_hz(input int domain_index);
        // Hz 元数据四舍五入到整数；真正周期仍以整数 ps 驱动和测量。
        return period_ps(domain_index)>0 ? int'((64'd1000000000000+64'(period_ps(domain_index)/2))/64'(period_ps(domain_index))) : 0;
    endfunction
    // 从实际编译常量打印配置，供固定软件重放核对所选 Core，避免旧模型混入新结果。
    initial begin
        $display("P2_CORE xlen=%0d backend=scoreboard issue_width=%0d retire_entries=%0d split_issue_queue=%0d integer_queue_entries=%0d memory_queue_entries=%0d limited_integer_ooo=%0d scheduler_forward_mode=%0d predictor_mode=%0d ras_enable=%0d mul_impl=%0d div_impl=%0d",
            XLEN, ISSUE_WIDTH, RETIRE_ENTRIES, SPLIT_ISSUE_QUEUE, ISSUE_QUEUE_ENTRIES,
            MEMORY_QUEUE_ENTRIES, LIMITED_INTEGER_OOO, SCHEDULER_FORWARD_MODE,
            PREDICTOR_MODE, RAS_ENABLE, MUL_IMPL, DIV_IMPL);
    end
    logic clk_core=0, clk_sys=0, clk_ddr=0, clk_periph=0, reset_async=1;
    realtime core_half=5ns, sys_half=6.25ns, ddr_half=4ns, periph_half=20ns;
    int clock_config=CLOCK_PROFILE;
    initial begin
        void'($value$plusargs("CLOCK_CONFIG=%d",clock_config));
        assert(clock_config==CLOCK_PROFILE) else $fatal(1,"runtime CLOCK_CONFIG differs from compiled CLOCK_PROFILE");
        assert (period_ps(0)>0 && period_ps(1)>0 && period_ps(2)>0 && period_ps(3)>0)
            else $fatal(1,"invalid clock configuration");
        core_half=period_ps(0)*0.5ps;
        sys_half=period_ps(1)*0.5ps;
        ddr_half=period_ps(2)*0.5ps;
        periph_half=period_ps(3)*0.5ps;
        $display("P2_HARDWARE clock_profile=%0d icache_fill_bytes=%0d metrics_schema=2 clock_info_enable=%0d core_hz=%0d sys_hz=%0d ddr_hz=%0d periph_hz=%0d timer_hz=%0d",
            CLOCK_PROFILE,dut.u_memory.u_icache.FILL_BYTES,dut.CLOCK_INFO_ENABLE,
            dut.CORE_CLOCK_HZ,dut.SYS_CLOCK_HZ,dut.DDR_CLOCK_HZ,dut.PERIPH_CLOCK_HZ,dut.PERIPH_CLOCK_HZ);
    end
    initial begin #1ps; forever #(core_half) clk_core=!clk_core; end
    initial begin #1ps; if(clock_config!=0) #1700ps; forever #(sys_half) clk_sys=!clk_sys; end
    initial begin #1ps; if(clock_config!=0) #2300ps; forever #(ddr_half) clk_ddr=!clk_ddr; end
    initial begin #1ps; if(clock_config!=0) #3100ps; forever #(periph_half) clk_periph=!clk_periph; end
    logic [1:0] uart_rx, uart_tx;
    logic [31:0] gpio_in[3], gpio_out[3], gpio_oe[3];
    logic ddr_ready=(DDR_BYTES!=0);
    logic flash_cs_n, flash_sck, flash_mosi, flash_miso;
    axi_req_t ddr_req, external_req, npu_req;
    axi_rsp_t ddr_rsp, external_rsp, npu_rsp;
    logic commit_valid,commit_rd_we,commit_exception,dmem_store_fire;
    logic [XLEN-1:0] commit_pc,commit_rd_data,dmem_store_addr,dmem_store_data;
    logic [31:0] commit_inst;
    logic [4:0] commit_rd;
    logic [DBUS_BYTES-1:0] dmem_store_strb;
    pipeline_pkg::retire_trace_t commit_trace[2];
    logic [XLEN-1:0] result_addr,console_addr;
    logic test_done,test_pass;
    logic [31:0] test_code;
    logic [31:0] fault_read_addr=32'hffffffff,fault_write_addr=32'hffffffff;
    longint unsigned cycles=0,max_cycles;
    int expected_exit=0;
    string imem_path,dmem_path,ddr_path,test_name;
    logic trace_enable;
    logic completed=0;
    int cache_hits=0, dcache_hits=0, ddr_fetches=0, dcache_commands=0, fence_commits=0, fatal_cycles=0;
    int dma_reads=0, dma_writes=0, dma_rbeats=0, dma_wbeats=0, dma_read_bursts=0, dma_write_bursts=0, dma_overlap=0;
    logic dma_r_pending=0, dma_w_pending=0;
    always @(posedge clk_sys) begin
        if (!dut.rst_sys) begin
            if (dma_r_pending && dma_w_pending) dma_overlap<=dma_overlap+1;
            if (dut.masters[2].ar_valid && dut.master_responses[2].ar_ready) begin
                dma_reads<=dma_reads+1; dma_r_pending<=1;
                if (dut.masters[2].ar.len!=0) dma_read_bursts<=dma_read_bursts+1;
            end
            if (dut.master_responses[2].r_valid && dut.masters[2].r_ready) begin
                dma_rbeats<=dma_rbeats+1;
                if (dut.master_responses[2].r.last) dma_r_pending<=0;
            end
            if (dut.masters[2].aw_valid && dut.master_responses[2].aw_ready) begin
                dma_writes<=dma_writes+1; dma_w_pending<=1;
                if (dut.masters[2].aw.len!=0) dma_write_bursts<=dma_write_bursts+1;
            end
            if (dut.masters[2].w_valid && dut.master_responses[2].w_ready) dma_wbeats<=dma_wbeats+1;
            if (dut.master_responses[2].b_valid && dut.masters[2].b_ready) dma_w_pending<=0;
        end
    end

    initial assert (!(MM3_ENABLE)) else $fatal(1,"accelerator unavailable in this branch");
    if (NPU_ENABLE) begin : g_npu
        assign external_req='0;
        logic clk_npu=0, rst_npu;
        always #(NPU_PERIOD_PS * 0.5ps) clk_npu=~clk_npu;
        soc_reset_controller u_reset (.reset_async,.clk_core(clk_npu),.clk_sys,.clk_ddr,.clk_periph,
            .rst_core(rst_npu),.rst_sys(),.rst_ddr(),.rst_periph());
        npu_axi_target u_npu (.clk_sys,.rst_sys(dut.rst_sys),.clk_npu,.rst_npu,
            .axi_req(npu_req),.axi_rsp(npu_rsp));
        initial $display("NPU_HARDWARE enabled=1 period_ps=%0d implementation=128mac mmio_abi=65536",NPU_PERIOD_PS);
    end else begin : g_no_npu
        assign external_req='0;
        assign npu_rsp='0;
    end
    assign uart_rx=$test$plusargs("UART_LOOPBACK") ? uart_tx : 2'b11;
    for(genvar g=0;g<3;g++) begin : g_gpio
        assign gpio_in[g]=$test$plusargs("GPIO_LOOPBACK") ? gpio_out[g]&gpio_oe[g] : '0;
    end
    soc_system #(.DDR_BYTES(DDR_BYTES),.FLASH_BYTES(FLASH_BYTES),.NPU_BYTES((NPU_ENABLE || MM3_ENABLE) ? 65536 : 0),.UART_DIVISOR(UART_DIVISOR),
        .CLOCK_INFO_ENABLE(1),.CORE_CLOCK_HZ(frequency_hz(0)),.SYS_CLOCK_HZ(frequency_hz(1)),
        .DDR_CLOCK_HZ(DDR_BYTES!=0 ? frequency_hz(2) : 0),.PERIPH_CLOCK_HZ(frequency_hz(3)),
        .SOC_PROFILE(SOC_PROFILE),.ICACHE_ENABLE(ICACHE_ENABLE),.DCACHE_ENABLE(DCACHE_ENABLE),.CLOCK_HZ(CLOCK_HZ)) dut(.*);
    axi_system_memory_model #(.BYTES(DDR_MODEL_BYTES == 0 ? 32 : DDR_MODEL_BYTES), .WORD_BYTES(XLEN/8)) u_ddr (.clk(clk_ddr),.rst(dut.rst_ddr),.stall(1'b0),
        .req(ddr_req),.rsp(ddr_rsp),.fault_read_addr,.fault_write_addr);
    spi_flash_model u_flash (.cs_n(flash_cs_n),.sck(flash_sck),.mosi(flash_mosi),.miso(flash_miso));
    store_result_monitor #(.RESULT_BYTES(RESULT_BYTES)) u_result_monitor (
        .clk(clk_core),.rst(dut.rst_core),.result_addr,.dmem_store_fire,
        .dmem_store_addr,.dmem_store_data,.dmem_store_strb,
        .store_request_id(dut.u_core.store_request_id),.store_response_fire(dut.u_core.store_response_fire),
        .store_response_error(dut.u_core.store_response_error),.store_response_id(dut.u_core.store_response_id),
        .store_retire_fire(dut.u_core.queue_retire_fire && dut.u_core.head_meta.kind==pipeline_pkg::RET_STORE),
        .store_retire_error(dut.u_core.head_result.exc.valid),.store_retire_id(dut.u_core.head_id),
        .cancel(dut.u_core.wb_redirect.valid),.test_done,.test_pass,.test_code);
    always @(posedge clk_core) begin
        if (!dut.rst_core) begin
            cycles<=cycles+1;
            if (dut.u_memory.u_icache.touch && !dut.u_memory.u_icache.install) cache_hits<=cache_hits+1;
            dcache_hits<=dcache_hits+int'(dut.u_memory.u_dcache.g_bank[0].u_cache.touch && !dut.u_memory.u_dcache.g_bank[0].u_cache.install)+
                int'(dut.u_memory.u_dcache.g_bank[1].u_cache.touch && !dut.u_memory.u_dcache.g_bank[1].u_cache.install);
            if(dut.cache_rd_cmd_valid[0] && dut.cache_rd_cmd_ready[0]) ddr_fetches<=ddr_fetches+1;
            if(dut.cache_command_valid && dut.cache_command_ready) dcache_commands<=dcache_commands+1;
            if(dut.fence_i_commit) fence_commits<=fence_commits+1;
            if (dmem_store_fire && dmem_store_addr==console_addr && dmem_store_strb[dmem_store_addr[$clog2(DBUS_BYTES)-1:0]])
                $write("%c",dmem_store_data[8*dmem_store_addr[$clog2(DBUS_BYTES)-1:0]+:8]);
            if(trace_enable) for(int i=0;i<2;i++) if(commit_trace[i].valid)
                $display("TRACE pc=%h inst=%h data=%h exc=%b",commit_trace[i].pc,commit_trace[i].inst,commit_trace[i].rd_data,commit_trace[i].exception);
        end
    end
    initial begin
        if(!$value$plusargs("IMEM=%s",imem_path) || !$value$plusargs("DMEM=%s",dmem_path) ||
           !$value$plusargs("TOHOST=%h",result_addr)) $fatal(1,"missing image/tohost");
        if(!$value$plusargs("CONSOLE=%h",console_addr)) console_addr='1;
        if(!$value$plusargs("TEST=%s",test_name)) test_name="soc-system";
        if(!$value$plusargs("MAX_CYCLES=%d",max_cycles)) max_cycles=3000000;
        trace_enable=$test$plusargs("TRACE_CORE");
        void'($value$plusargs("EXPECTED_EXIT=%d",expected_exit));
        void'($value$plusargs("FAULT_READ=%h",fault_read_addr));
        void'($value$plusargs("FAULT_WRITE=%h",fault_write_addr));
        dut.g_tcm[0].u_ram.load_image(imem_path);
        dut.g_tcm[1].u_ram.load_image(dmem_path);
        if($value$plusargs("DDR=%s",ddr_path)) u_ddr.load_image(ddr_path);
        repeat(10) @(negedge clk_core);
        reset_async=0;
        while(cycles<max_cycles) begin
            @(negedge clk_core);
            if($test$plusargs("EXPECT_CACHE_FATAL") && dut.cache_fatal) begin
                assert(dut.fetch_block && !dut.imem_req_ready && dut.cache_error==cache_pkg::CACHE_WRITEBACK_ERROR &&
                       dut.cache_fault_addr==XLEN'(fault_write_addr)) else $fatal(1,"cache fatal state/owner");
                fatal_cycles++;
                if(fatal_cycles==32) begin
                    $display("PASS soc-cache-fatal RV%0d cycles=%0d",XLEN,cycles);
                    completed=1;break;
                end
            end
            if(test_done) begin
                assert(!$test$plusargs("EXPECT_CACHE_FATAL")) else $fatal(1,"missing cache fatal");
                if($test$plusargs("CACHE_CHECKS")) begin
                    assert(cache_hits>=16 && ddr_fetches>=3 && fence_commits>=3) else $fatal(1,"missing I-cache coverage");
                    $display("CACHE hits=%0d DDR_fetches=%0d FENCE.I=%0d",cache_hits,ddr_fetches,fence_commits);
                end
                if($test$plusargs("DCACHE_CHECKS")) begin
                    assert((!DCACHE_ENABLE || dcache_hits>=8) && dcache_commands>=2) else $fatal(1,"missing D-cache coverage");
                    $display("DCACHE enabled=%0d hits=%0d commands=%0d",DCACHE_ENABLE,dcache_hits,dcache_commands);
                end
                if($test$plusargs("DMA_WIDE_CHECK")) begin
                    assert(dma_rbeats>=4 && dma_wbeats>=4 && !dma_r_pending && !dma_w_pending) else $fatal(1,"missing unified DMA beats/drain");
                    $display("PASS DMA_NATIVE_AXI RV%0d unified=1 read_beats=%0d write_beats=%0d",XLEN,dma_rbeats,dma_wbeats);
                end
                if($test$plusargs("DMA_BLOCK_CHECK")) begin
                    assert(dma_read_bursts>0 && dma_write_bursts>0 && dma_overlap>0 && !dma_r_pending && !dma_w_pending)
                        else $fatal(1,"missing unified DMA bursts/overlap/drain");
                    $display("PASS DMA_BLOCK_AXI RV%0d unified=1 read_commands=%0d write_commands=%0d read_beats=%0d write_beats=%0d overlap=%0d",
                        XLEN,dma_reads,dma_writes,dma_rbeats,dma_wbeats,dma_overlap);
                end
                assert(test_code==((32'(expected_exit)<<1)|32'd1)) else $fatal(1,"FAIL %s code=%0d pc=%h",test_name,test_code,commit_pc);
                $display("PASS %s RV%0d cycles=%0d clocks=C%0d core_half_ns=%0f sys_half_ns=%0f ddr_half_ns=%0f periph_half_ns=%0f SPI_reads=%0d",
                    test_name,XLEN,cycles,clock_config,core_half,sys_half,ddr_half,periph_half,u_flash.transactions);
                completed=1;
                break;
            end
        end
        if (!completed) $fatal(1,"TIMEOUT %s pc=%h inst=%h cycles=%0d",test_name,commit_pc,commit_inst,cycles);
        if (AUTO_FINISH) $finish;
    end
endmodule
