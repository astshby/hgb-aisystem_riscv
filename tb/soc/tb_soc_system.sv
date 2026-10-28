// Module: tb_soc_system
// Description: Executes unchanged software images on the integrated four-clock AXI SoC.
`include "tb/common/soc_latency_metrics.sv"
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
    parameter int ICACHE_BYTES=4096,
    parameter int DCACHE_BYTES=4096,
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
    // 专用 CoreMark 软件在保留的 DTCM 字中标记测量区间。此处只观测 RAM，
    // 不注入 CPU/DMA 请求；性能分母仍取软件 mcycle，跨域计数只描述该区间的活动。
    localparam int TCM_BANK_WORDS=soc_config_pkg::DTCM_BYTES/(2*DBUS_BYTES);
    logic [31:0] p2_roi_addr=32'h01100100, p2_roi_phase;
    logic p2_roi_enable=0, p2_roi_seen=0;
    int p2_roi_bank=0, p2_roi_index=0;
    longint unsigned p2_core_cycles=0, p2_sys_cycles=0;
    longint unsigned p2_cpu_ddr_ar=0, p2_cpu_ddr_aw=0;
    longint unsigned p2_dma_ar=0, p2_dma_aw=0, p2_dma_rbeats=0, p2_dma_wbeats=0;
    longint unsigned p2_cpu_ar_wait[2]='{0,0}, p2_dma_ar_wait=0;
    longint unsigned p2_max_cpu_ar_wait=0, p2_max_dma_ar_wait=0;
    always_comb begin
        if (p2_roi_bank==0)
            p2_roi_phase=32'(dut.g_tcm[1].u_ram.g_bank[0].mem[p2_roi_index]);
        else
            p2_roi_phase=32'(dut.g_tcm[1].u_ram.g_bank[1].mem[p2_roi_index]);
    end
    always @(posedge clk_core) begin
        if (!dut.rst_core && p2_roi_enable && p2_roi_phase==1) begin
            p2_roi_seen<=1;
            p2_core_cycles<=p2_core_cycles+1;
        end
    end
    always @(posedge clk_sys) begin
        if (!dut.rst_sys && p2_roi_enable && p2_roi_phase==1) begin
            p2_sys_cycles<=p2_sys_cycles+1;
            p2_cpu_ddr_ar<=p2_cpu_ddr_ar+
                int'(dut.masters[0].ar_valid && dut.master_responses[0].ar_ready && dut.masters[0].ar.addr>=32'h80000000)+
                int'(dut.masters[1].ar_valid && dut.master_responses[1].ar_ready && dut.masters[1].ar.addr>=32'h80000000);
            p2_cpu_ddr_aw<=p2_cpu_ddr_aw+
                int'(dut.masters[0].aw_valid && dut.master_responses[0].aw_ready && dut.masters[0].aw.addr>=32'h80000000)+
                int'(dut.masters[1].aw_valid && dut.master_responses[1].aw_ready && dut.masters[1].aw.addr>=32'h80000000);
            if (dut.masters[2].ar_valid && dut.master_responses[2].ar_ready) p2_dma_ar<=p2_dma_ar+1;
            if (dut.masters[2].aw_valid && dut.master_responses[2].aw_ready) p2_dma_aw<=p2_dma_aw+1;
            if (dut.master_responses[2].r_valid && dut.masters[2].r_ready) p2_dma_rbeats<=p2_dma_rbeats+1;
            if (dut.masters[2].w_valid && dut.master_responses[2].w_ready) p2_dma_wbeats<=p2_dma_wbeats+1;
            for (int master=0;master<2;master++) begin
                if (dut.masters[master].ar_valid && !dut.master_responses[master].ar_ready)
                    p2_cpu_ar_wait[master]<=p2_cpu_ar_wait[master]+1;
                else p2_cpu_ar_wait[master]<=0;
            end
            // 两个 CPU 主端同时更新时使用 max，避免非阻塞赋值顺序丢失较大值。
            if (dut.masters[0].ar_valid && !dut.master_responses[0].ar_ready &&
                p2_cpu_ar_wait[0]+1>p2_max_cpu_ar_wait &&
                (!(dut.masters[1].ar_valid && !dut.master_responses[1].ar_ready) ||
                 p2_cpu_ar_wait[0]>=p2_cpu_ar_wait[1]))
                p2_max_cpu_ar_wait<=p2_cpu_ar_wait[0]+1;
            else if (dut.masters[1].ar_valid && !dut.master_responses[1].ar_ready &&
                     p2_cpu_ar_wait[1]+1>p2_max_cpu_ar_wait)
                p2_max_cpu_ar_wait<=p2_cpu_ar_wait[1]+1;
            if (dut.masters[2].ar_valid && !dut.master_responses[2].ar_ready) begin
                p2_dma_ar_wait<=p2_dma_ar_wait+1;
                if (p2_dma_ar_wait+1>p2_max_dma_ar_wait) p2_max_dma_ar_wait<=p2_dma_ar_wait+1;
            end else p2_dma_ar_wait<=0;
        end else begin
            p2_cpu_ar_wait[0]<=0;
            p2_cpu_ar_wait[1]<=0;
            p2_dma_ar_wait<=0;
        end
    end
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

    // 观测默认关闭。各域按自己的沿采样 ROI；软件 mcycle 仍是 CoreMark 的分母。
    logic p2_metrics_enable=0, p2_platform_enable=0;
    logic [31:0] p2_periph_period_ps=0, p2_measured_periph_period_ps=0;
    logic p2_period_seen=0;
    realtime p2_last_periph_edge=0;
    longint unsigned p2_period_checks=0;
    // 注入值与实际相邻上升沿核对；不改变时钟发生器或复位释放时刻。
    always @(posedge clk_periph) if(p2_platform_enable) begin
        if(p2_period_seen) begin
            p2_measured_periph_period_ps=soc_metrics_pkg::clock_period_ps(($realtime-p2_last_periph_edge)/2.0);
            assert(p2_measured_periph_period_ps==p2_periph_period_ps)
                else $fatal(1,"peripheral period mismatch injected=%0d measured=%0d",p2_periph_period_ps,p2_measured_periph_period_ps);
            p2_period_checks++;
        end
        p2_last_periph_edge=$realtime; p2_period_seen=1;
    end
    // 专用时基测试在 CPU 解除复位前结束，仅检查配置写入和真实时钟周期。
    initial if($test$plusargs("P2_PLATFORM_CLOCK_ONLY")) begin
        assert($test$plusargs("P2_PLATFORM")) else $fatal(1,"clock-only check requires P2_PLATFORM");
        wait(p2_period_checks!=0);
        @(negedge clk_periph);
        $display("PASS soc-platform-clock RV%0d clock=C%0d injected_period_ps=%0d measured_period_ps=%0d",
            XLEN,clock_config,p2_periph_period_ps,p2_measured_periph_period_ps);
        $finish;
    end
    final if(p2_platform_enable) $display("P2_PLATFORM_CLOCK periph_period_ps=%0d measured_period_ps=%0d checked_periods=%0d",
        p2_periph_period_ps,p2_measured_periph_period_ps,p2_period_checks);
    wire metrics_roi=p2_roi_enable ? p2_roi_phase==1 : 1'b1;
    localparam int CPU_ID_W=$bits(pipeline_pkg::retire_id_t);
    soc_latency_metrics #(.NAME("cpu.if")) u_if_latency (
        .clk(clk_core),.rst(dut.rst_core),.enable(p2_metrics_enable&&!reset_async),.roi(metrics_roi),
        .start_fire(dut.imem_req_valid&&dut.imem_req_ready),.start_id(1'b0),.start_units(32'd8),
        .response_fire(dut.imem_rsp_valid&&dut.imem_rsp_ready),.response_last(1'b1),.response_id(1'b0),.response_units(32'b0),
        .request_stall(dut.imem_req_valid&&!dut.imem_req_ready),.response_stall(dut.imem_rsp_valid&&!dut.imem_rsp_ready));
    for(genvar p=0;p<2;p++) begin : g_data_latency
        bus_types_pkg::bus_target_e checked_target;
        bus_types_pkg::bus_error_e checked_error;
        logic [2:0] expected_route;
        longint unsigned route_checks = 0;
        // 用完整地址/权限译码检查真实队头，而非复用入队的本地资格逻辑。
        address_decode #(.DDR_BYTES(DDR_BYTES)) u_route_reference (
            .request(dut.u_memory.request[p]), .target(checked_target), .error(checked_error));
        always_comb begin
            expected_route = 3'b001;
            if (checked_error == bus_types_pkg::BUS_OK && checked_target == bus_types_pkg::TARGET_ITCM)
                expected_route = 3'b010;
            else if (checked_error == bus_types_pkg::BUS_OK && checked_target == bus_types_pkg::TARGET_DTCM)
                expected_route = 3'b100;
        end
        always @(posedge clk_core) if (!reset_async && !dut.rst_core && dut.u_memory.req_valid[p]) begin
            assert (dut.u_memory.queued_route[p] == expected_route)
                else $fatal(1, "queued TCM route mismatch port=%0d address=%h", p, dut.u_memory.request[p].addr);
            route_checks++;
        end
        final $display("TCM_ROUTE port=%0d checked_queue_cycles=%0d", p, route_checks);
        soc_latency_metrics #(.NAME($sformatf("cpu.d%0d",p)),.ID_W(CPU_ID_W)) u_end_to_end (
            .clk(clk_core),.rst(dut.rst_core),.enable(p2_metrics_enable&&!reset_async),.roi(metrics_roi),
            .start_fire(dut.data_req_valid[p]&&dut.data_req_ready[p]),.start_id(dut.tagged_request[p].id),
            .start_units(32'd1<<dut.tagged_request[p].size),
            .response_fire(dut.data_rsp_valid[p]&&dut.data_rsp_ready[p]),.response_last(1'b1),
            .response_id(dut.tagged_response[p].id),.response_units(32'b0),
            .request_stall(dut.data_req_valid[p]&&!dut.data_req_ready[p]),
            .response_stall(dut.data_rsp_valid[p]&&!dut.data_rsp_ready[p]));
        soc_latency_metrics #(.NAME($sformatf("cpu.d%0d.queue",p)),.ID_W(CPU_ID_W)) u_queue (
            .clk(clk_core),.rst(dut.rst_core),.enable(p2_metrics_enable&&!reset_async),.roi(metrics_roi),
            .start_fire(dut.data_req_valid[p]&&dut.data_req_ready[p]),.start_id(dut.tagged_request[p].id),.start_units(32'b0),
            .response_fire(dut.u_memory.req_fire[p]),.response_last(1'b1),
            .response_id(dut.u_memory.buffered_request[p].id),.response_units(32'b0),
            .request_stall(dut.data_req_valid[p]&&!dut.data_req_ready[p]),
            .response_stall(dut.u_memory.req_valid[p]&&!dut.u_memory.req_ready[p]));
    end
    for(genvar b=0;b<2;b++) begin : g_tcm_latency
        longint unsigned conflict_cycles=0, blocked_response_cycles=0, bank_fires=0;
        longint unsigned roi_conflict_cycles=0, roi_blocked_response_cycles=0, roi_bank_fires=0;
        // 双端口可同时服务同bank两读；只将实际阻塞的bank竞争计为冲突。
        logic conflict;
        always_comb begin
            conflict=0;
            for(int p=0;p<4;p++) for(int q=p+1;q<4;q++)
                if(dut.g_tcm[b].req_v[p]&&(!dut.g_tcm[b].rsp_v[p]||dut.g_tcm[b].rsp_r[p])&&
                   dut.g_tcm[b].req_v[q]&&(!dut.g_tcm[b].rsp_v[q]||dut.g_tcm[b].rsp_r[q])&&
                   |(dut.g_tcm[b].u_ram.needed[p]&dut.g_tcm[b].u_ram.needed[q])&&
                   (!dut.g_tcm[b].req_r[p]||!dut.g_tcm[b].req_r[q])) conflict=1;
        end
        always @(posedge clk_core) if(!reset_async&&!dut.rst_core&&p2_metrics_enable) begin
            if(conflict) begin conflict_cycles++; if(metrics_roi) roi_conflict_cycles++; end
            if(|(dut.g_tcm[b].rsp_v&~dut.g_tcm[b].rsp_r)) begin
                blocked_response_cycles++; if(metrics_roi) roi_blocked_response_cycles++;
            end
            bank_fires+=64'($countones(dut.g_tcm[b].u_ram.bank_fire));
            if(metrics_roi) roi_bank_fires+=64'($countones(dut.g_tcm[b].u_ram.bank_fire));
        end
        for(genvar p=0;p<4;p++) begin : g_port
            soc_latency_metrics #(.NAME($sformatf("tcm%0d.port%0d",b,p))) u_latency (
                .clk(clk_core),.rst(dut.rst_core),.enable(p2_metrics_enable&&!reset_async),.roi(metrics_roi),
                .start_fire(dut.g_tcm[b].req_v[p]&&dut.g_tcm[b].req_r[p]),.start_id(1'b0),.start_units(32'b0),
                .response_fire(dut.g_tcm[b].rsp_v[p]&&dut.g_tcm[b].rsp_r[p]),.response_last(1'b1),
                .response_id(1'b0),.response_units(32'b0),
                .request_stall(dut.g_tcm[b].req_v[p]&&!dut.g_tcm[b].req_r[p]),
                .response_stall(dut.g_tcm[b].rsp_v[p]&&!dut.g_tcm[b].rsp_r[p]));
        end
        final if(p2_metrics_enable) $display("P2_TCM name=tcm%0d conflict_cycles=%0d response_blocked_cycles=%0d bank_fires=%0d roi_conflict_cycles=%0d roi_response_blocked_cycles=%0d roi_bank_fires=%0d",
            b,conflict_cycles,blocked_response_cycles,bank_fires,roi_conflict_cycles,roi_blocked_response_cycles,roi_bank_fires);
    end
    soc_cache_latency_metrics #(.NAME("icache")) u_icache_latency (
        .clk(clk_core),.rst(dut.rst_core),.enable(p2_metrics_enable&&!reset_async),.roi(metrics_roi),
        .hit(dut.u_memory.u_icache.request_fire&&dut.u_memory.u_icache.cacheable&&dut.u_memory.u_icache.hit),
        .miss(dut.u_memory.u_icache.request_fire&&dut.u_memory.u_icache.cacheable&&!dut.u_memory.u_icache.hit),
        .install(dut.u_memory.u_icache.install),
        .refill_start(dut.u_memory.u_icache.u_refill.start_valid&&dut.u_memory.u_icache.u_refill.start_ready),
        .refill_done(dut.u_memory.u_icache.u_refill.done_valid&&dut.u_memory.u_icache.u_refill.done_ready),
        .refill_last_beat(dut.u_memory.u_icache.u_refill.rd_valid&&dut.u_memory.u_icache.u_refill.rd_ready&&dut.u_memory.u_icache.u_refill.rd_data.last),
        .refill_request_stall(dut.u_memory.u_icache.u_refill.rd_cmd_valid&&!dut.u_memory.u_icache.u_refill.rd_cmd_ready),
        .refill_response_stall(dut.u_memory.u_icache.u_refill.rd_valid&&!dut.u_memory.u_icache.u_refill.rd_ready),
        .install_write(dut.u_memory.u_icache.fill_write));
    for(genvar b=0;b<2;b++) begin : g_dcache_latency
        logic lookup_q=0;
        logic waiting_cached, cached_request_present;
        logic [1:0] cached_pending;
        longint unsigned roi_same_bank_compete=0, roi_active_bank_wait=0, roi_response_backpressure=0, roi_maintenance_wait=0;
        longint unsigned request_stall_cycles=0, response_with_request=0, same_cycle_turnover=0;
        longint unsigned roi_request_stall_cycles=0, roi_response_with_request=0, roi_same_cycle_turnover=0;
        // 每 bank 只记一次等待周期；请求地址/尺寸合法且整行可缓存才计入。
        always_comb begin
            waiting_cached=0; cached_request_present=0; cached_pending=0;
            for(int p=0;p<2;p++) begin
                if(dut.u_memory.u_dcache.ENABLE&&dut.u_memory.u_dcache.req_valid[p]&&
                   dut.u_memory.u_dcache.request_bank[p]==1'(b)&&
                   dut.u_memory.u_dcache.request[p].addr>=XLEN'(soc_addr_pkg::DDR_BASE)&&
                   (65'(dut.u_memory.u_dcache.request[p].addr)&~65'(dut.u_memory.u_dcache.LINE_BYTES-1))+
                       65'(dut.u_memory.u_dcache.LINE_BYTES)<=65'(soc_addr_pkg::DDR_BASE)+65'(DDR_BYTES)&&
                   (XLEN==64||dut.u_memory.u_dcache.request[p].size!=core_types_pkg::MEM_DWORD)&&
                   (dut.u_memory.u_dcache.request[p].addr&((XLEN'(1)<<dut.u_memory.u_dcache.request[p].size)-1))==0) begin
                    cached_request_present=1; cached_pending[p]=1;
                    if(!dut.u_memory.u_dcache.req_ready[p]) waiting_cached=1;
                end
            end
        end
        always @(posedge clk_core) if(!reset_async&&!dut.rst_core&&p2_metrics_enable) begin
            if(waiting_cached) begin request_stall_cycles++; if(metrics_roi) roi_request_stall_cycles++; end
            // 各原因独立计数，可重叠；不能相加当作总停顿或全部解释成双口竞争。
            if(metrics_roi) begin
                if(&cached_pending) roi_same_bank_compete++;
                if(waiting_cached && dut.u_memory.u_dcache.bank_busy_q[b]) roi_active_bank_wait++;
                if(waiting_cached && dut.u_memory.u_dcache.b_rsp_valid[b] && !dut.u_memory.u_dcache.b_rsp_ready[b]) roi_response_backpressure++;
                if(waiting_cached && (dut.u_memory.u_dcache.maintenance_q || dut.u_memory.u_dcache.maint_req_valid)) roi_maintenance_wait++;
            end
            if(dut.u_memory.u_dcache.response_fire[b]&&cached_request_present) begin
                response_with_request++; if(metrics_roi) roi_response_with_request++;
            end
            if(dut.u_memory.u_dcache.request_fire[b]&&dut.u_memory.u_dcache.response_fire[b]) begin
                same_cycle_turnover++; if(metrics_roi) roi_same_cycle_turnover++;
            end
        end
        final if(p2_metrics_enable) $display("P2_CACHE_BANK name=dcache%0d request_stall_cycles=%0d response_with_request=%0d same_cycle_turnover=%0d roi_request_stall_cycles=%0d roi_response_with_request=%0d roi_same_cycle_turnover=%0d roi_same_bank_compete=%0d roi_active_bank_wait=%0d roi_response_backpressure=%0d roi_maintenance_wait=%0d",
            b,request_stall_cycles,response_with_request,same_cycle_turnover,
            roi_request_stall_cycles,roi_response_with_request,roi_same_cycle_turnover,
            roi_same_bank_compete,roi_active_bank_wait,roi_response_backpressure,roi_maintenance_wait);
        // D-cache 在接受 cache 请求后的下一拍作唯一 LOOKUP 决策。
        always_ff @(posedge clk_core) lookup_q<=!dut.rst_core&&dut.u_memory.u_dcache.g_bank[b].u_cache.request_fire;
        soc_cache_latency_metrics #(.NAME($sformatf("dcache%0d",b))) u_latency (
            .clk(clk_core),.rst(dut.rst_core),.enable(p2_metrics_enable&&!reset_async),.roi(metrics_roi),
            .hit(lookup_q&&dut.u_memory.u_dcache.g_bank[b].u_cache.hit),
            .miss(lookup_q&&!dut.u_memory.u_dcache.g_bank[b].u_cache.hit),
            .install(dut.u_memory.u_dcache.g_bank[b].u_cache.install),
            .refill_start(dut.u_memory.u_dcache.g_bank[b].u_cache.u_refill.start_valid&&dut.u_memory.u_dcache.g_bank[b].u_cache.u_refill.start_ready),
            .refill_done(dut.u_memory.u_dcache.g_bank[b].u_cache.u_refill.done_valid&&dut.u_memory.u_dcache.g_bank[b].u_cache.u_refill.done_ready),
            .refill_last_beat(dut.u_memory.u_dcache.g_bank[b].u_cache.u_refill.rd_valid&&dut.u_memory.u_dcache.g_bank[b].u_cache.u_refill.rd_ready&&dut.u_memory.u_dcache.g_bank[b].u_cache.u_refill.rd_data.last),
            .refill_request_stall(dut.u_memory.u_dcache.g_bank[b].u_cache.u_refill.rd_cmd_valid&&!dut.u_memory.u_dcache.g_bank[b].u_cache.u_refill.rd_cmd_ready),
            .refill_response_stall(dut.u_memory.u_dcache.g_bank[b].u_cache.u_refill.rd_valid&&!dut.u_memory.u_dcache.g_bank[b].u_cache.u_refill.rd_ready),
            .install_write(dut.u_memory.u_dcache.g_bank[b].u_cache.fill_write));
    end
    for(genvar m=0;m<4;m++) begin : g_axi_latency
        soc_axi_latency_metrics #(.NAME($sformatf("sys.master%0d",m))) u_latency (
            .clk(clk_sys),.rst(dut.rst_sys),.enable(p2_metrics_enable&&!reset_async),.roi(metrics_roi),
            .req(dut.masters[m]),.rsp(dut.master_responses[m]));
    end
    soc_axi_latency_metrics #(.NAME("ddr.target"),.DOMAIN("ddr")) u_ddr_latency (
        .clk(clk_ddr),.rst(dut.rst_ddr),.enable(p2_metrics_enable&&!reset_async),.roi(metrics_roi),.req(ddr_req),.rsp(ddr_rsp));
    soc_latency_metrics #(.NAME("dma.engine"),.DOMAIN("sys"),.RESPONSE_UNITS(1)) u_dma_latency (
        .clk(clk_sys),.rst(dut.rst_sys),.enable(p2_metrics_enable&&!reset_async),.roi(metrics_roi),
        .start_fire(dut.u_dma.command_accept),.start_id(1'b0),.start_units(dut.u_dma.command_out.length),
        .response_fire(dut.u_dma.finish_valid&&dut.u_dma.result_ready),.response_last(1'b1),
        .response_id(1'b0),.response_units(dut.u_dma.result_in.bytes),
        .request_stall(dut.u_dma.command_valid&&!dut.u_dma.command_accept),
        .response_stall(dut.u_dma.finish_valid&&!dut.u_dma.result_ready));
    soc_latency_metrics #(.NAME("dma.software"),.DOMAIN("periph"),.RESPONSE_UNITS(1)) u_dma_software_latency (
        .clk(clk_periph),.rst(dut.rst_periph),.enable(p2_metrics_enable&&!reset_async),.roi(metrics_roi),
        .start_fire(dut.u_dma.start_valid&&dut.u_dma.command_ready),.start_id(1'b0),.start_units(dut.u_dma.command_in.length),
        .response_fire(dut.u_dma.result_valid),.response_last(1'b1),.response_id(1'b0),.response_units(dut.u_dma.result_out.bytes),
        .request_stall(dut.u_dma.start_valid&&!dut.u_dma.command_ready),.response_stall(1'b0));

    logic boot_seen=0, boot_itcm_seen=0, boot_ddr_seen=0, boot_order_ok=1, boot_words_ok=1;
    logic [XLEN-1:0] boot_first_pc='1;
    longint unsigned boot_rom_retired=0, boot_itcm_retired=0, boot_ddr_retired=0;
    longint unsigned roi_ddr_retired=0, roi_ddr_if=0, roi_ddr_data=0;
    longint unsigned roi_ddr_sp_writes=0, roi_tcm_sp_writes=0, roi_bad_sp_writes=0, roi_sp_construction_writes=0;
    longint unsigned roi_ddr_stack_accesses=0, roi_tcm_stack_accesses=0, roi_bad_stack_accesses=0;
    logic [XLEN-1:0] trace_sp=0;
    // 启动顺序由实际退休 trace 验证，读取镜像或观察预取均不算程序已执行。
    always @(posedge clk_core) if(!reset_async&&!dut.rst_core&&(p2_platform_enable||p2_metrics_enable)) begin
        for(int lane=0;lane<2;lane++) if(commit_trace[lane].valid) begin
            logic [XLEN-1:0] stack_address;
            logic [11:0] stack_immediate;
            int unsigned stack_bytes;
            // trace 按退休年龄排列；访存使用旧 SP，随后才处理本指令对 SP 的写回。
            if(metrics_roi&&!commit_trace[lane].exception&&commit_trace[lane].inst[19:15]==5'd2&&
               (commit_trace[lane].inst[6:0]==7'h03||commit_trace[lane].inst[6:0]==7'h23)) begin
                stack_immediate=commit_trace[lane].inst[6:0]==7'h23 ?
                    {commit_trace[lane].inst[31:25],commit_trace[lane].inst[11:7]} : commit_trace[lane].inst[31:20];
                stack_address=trace_sp+{{(XLEN-12){stack_immediate[11]}},stack_immediate};
                stack_bytes=1<<commit_trace[lane].inst[13:12];
                if(stack_address>=XLEN'(32'h8001c000)&&65'(stack_address)+65'(stack_bytes)<=65'h80020000)
                    roi_ddr_stack_accesses++;
                else if(stack_address>=XLEN'(32'h0110e000)&&65'(stack_address)+65'(stack_bytes)<=65'h01110000)
                    roi_tcm_stack_accesses++;
                else roi_bad_stack_accesses++;
            end
            if(!boot_seen) begin boot_seen=1; boot_first_pc=commit_trace[lane].pc; end
            if(commit_trace[lane].pc<XLEN'(soc_addr_pkg::ITCM_BASE)) begin
                if(boot_rom_retired==0) begin
                    if(commit_trace[lane].pc!=0||commit_trace[lane].inst!=32'h010002b7) boot_words_ok=0;
                end else if(boot_rom_retired==1) begin
                    if(commit_trace[lane].pc!=4||commit_trace[lane].inst!=32'h00028067) boot_words_ok=0;
                end else boot_words_ok=0;
                if(boot_itcm_seen||boot_ddr_seen) boot_order_ok=0;
                boot_rom_retired++;
            end else if(commit_trace[lane].pc>=XLEN'(soc_addr_pkg::ITCM_BASE)&&
                        commit_trace[lane].pc<XLEN'(soc_addr_pkg::ITCM_BASE+soc_config_pkg::ITCM_BYTES)) begin
                if(!boot_itcm_seen&&(boot_rom_retired!=2||commit_trace[lane].pc!=XLEN'(soc_addr_pkg::ITCM_BASE))) boot_order_ok=0;
                boot_itcm_seen=1; boot_itcm_retired++;
            end else if(commit_trace[lane].pc>=XLEN'(soc_addr_pkg::DDR_BASE)&&
                        65'(commit_trace[lane].pc)<65'(soc_addr_pkg::DDR_BASE)+65'(DDR_BYTES)) begin
                if(!boot_itcm_seen) boot_order_ok=0;
                boot_ddr_seen=1; boot_ddr_retired++;
                if(metrics_roi) roi_ddr_retired++;
            end
            if(commit_trace[lane].rd_we&&commit_trace[lane].rd==5'd2) begin
                if(metrics_roi&&commit_trace[lane].rd_data!=0) begin
                    // la sp 的 AUIPC/LUI 可暂时越过栈顶；实际访存由上面的区间检查负责。
                    if(commit_trace[lane].inst[6:0]==7'h17||commit_trace[lane].inst[6:0]==7'h37) roi_sp_construction_writes++;
                    else if(commit_trace[lane].rd_data>=XLEN'(32'h8001c000)&&commit_trace[lane].rd_data<=XLEN'(32'h80020000)) roi_ddr_sp_writes++;
                    else if(commit_trace[lane].rd_data>=XLEN'(32'h0110e000)&&commit_trace[lane].rd_data<=XLEN'(32'h01110000)) roi_tcm_sp_writes++;
                    else roi_bad_sp_writes++;
                end
                trace_sp=commit_trace[lane].rd_data;
            end
        end
        if(metrics_roi) begin
            if(dut.imem_req_valid&&dut.imem_req_ready&&dut.imem_req_addr>=XLEN'(soc_addr_pkg::DDR_BASE)&&
               65'(dut.imem_req_addr)<65'(soc_addr_pkg::DDR_BASE)+65'(DDR_BYTES)) roi_ddr_if++;
            for(int p=0;p<2;p++) if(dut.data_req_valid[p]&&dut.data_req_ready[p]&&
                dut.tagged_request[p].address>=XLEN'(soc_addr_pkg::DDR_BASE)&&
                65'(dut.tagged_request[p].address)<65'(soc_addr_pkg::DDR_BASE)+65'(DDR_BYTES)) roi_ddr_data++;
        end
    end
    task automatic set_platform_word(input logic[31:0] address,input logic[31:0] value);
        int word_index, byte_lane;
        word_index=int'((address-soc_addr_pkg::DTCM_BASE)>>($clog2(DBUS_BYTES)+1));
        byte_lane=int'(address&(DBUS_BYTES-1));
        if((address>>$clog2(DBUS_BYTES))&1)
            dut.g_tcm[1].u_ram.g_bank[1].mem[word_index][8*byte_lane+:32]=value;
        else dut.g_tcm[1].u_ram.g_bank[0].mem[word_index][8*byte_lane+:32]=value;
    endtask
    final if((p2_metrics_enable||p2_platform_enable)&&!$test$plusargs("P2_PLATFORM_CLOCK_ONLY")) begin
        $display("P2_METRICS scope=%s enabled=%0d latency_units=domain_cycles",p2_roi_enable ? "software_marker" : "whole_run",p2_metrics_enable);
        $display("P2_BOOT first_pc=%08h rom_retired=%0d itcm_seen=%0d ddr_seen=%0d order_ok=%0d rom_words_ok=%0d itcm_retired=%0d ddr_retired=%0d roi_ddr_retired=%0d roi_ddr_if=%0d roi_ddr_data=%0d",
            boot_first_pc,boot_rom_retired,boot_itcm_seen,boot_ddr_seen,boot_order_ok,boot_words_ok,
            boot_itcm_retired,boot_ddr_retired,roi_ddr_retired,roi_ddr_if,roi_ddr_data);
        $display("P2_STACK roi_ddr_sp_writes=%0d roi_tcm_sp_writes=%0d roi_bad_sp_writes=%0d roi_sp_construction_writes=%0d roi_ddr_stack_accesses=%0d roi_tcm_stack_accesses=%0d roi_bad_stack_accesses=%0d",
            roi_ddr_sp_writes,roi_tcm_sp_writes,roi_bad_sp_writes,roi_sp_construction_writes,
            roi_ddr_stack_accesses,roi_tcm_stack_accesses,roi_bad_stack_accesses);
        $display("P2_CACHE_CONFIG icache_bytes=%0d icache_line_bytes=%0d icache_ways=2 icache_fill_bytes=%0d dcache_bytes=%0d dcache_line_bytes=%0d dcache_ways=2 dcache_banks=2 dcache_bank_bit=%0d dcache_bank_xor_mask=%0d dcache_set_low=%0d dcache_set_high=%0d",
            dut.u_memory.u_icache.CACHE_BYTES,dut.u_memory.u_icache.LINE_BYTES,dut.u_memory.u_icache.FILL_BYTES,
            dut.u_memory.u_dcache.CACHE_BYTES,dut.u_memory.u_dcache.LINE_BYTES,dut.u_memory.u_dcache.BANK_BIT,dut.u_memory.u_dcache.BANK_XOR_MASK,
            $clog2(dut.u_memory.u_dcache.LINE_BYTES),dut.u_memory.u_dcache.BANK_BIT-1);
    end

    initial assert (!(NPU_ENABLE || MM3_ENABLE)) else $fatal(1,"accelerator unavailable in this branch");
    if (1) begin : g_no_npu
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
        .SOC_PROFILE(SOC_PROFILE),.ICACHE_ENABLE(ICACHE_ENABLE),.DCACHE_ENABLE(DCACHE_ENABLE),
        .ICACHE_BYTES(ICACHE_BYTES),.DCACHE_BYTES(DCACHE_BYTES),.CLOCK_HZ(CLOCK_HZ)) dut(.*);
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
        p2_metrics_enable=$test$plusargs("P2_METRICS");
        p2_platform_enable=$test$plusargs("P2_PLATFORM");
        p2_roi_enable=$value$plusargs("P2_ROI=%h",p2_roi_addr);
        if (p2_roi_enable) begin
            assert(p2_roi_addr>=soc_addr_pkg::DTCM_BASE &&
                   p2_roi_addr<soc_addr_pkg::DTCM_BASE+soc_config_pkg::DTCM_BYTES &&
                   (p2_roi_addr & (DBUS_BYTES-1))==0) else $fatal(1,"P2_ROI requires aligned DTCM word");
            p2_roi_bank=int'((p2_roi_addr>>$clog2(DBUS_BYTES)) & 1);
            p2_roi_index=int'((p2_roi_addr-soc_addr_pkg::DTCM_BASE)>>($clog2(DBUS_BYTES)+1));
            assert(p2_roi_index<TCM_BANK_WORDS) else $fatal(1,"P2_ROI index outside TCM");
        end
        dut.g_tcm[0].u_ram.load_image(imem_path);
        dut.g_tcm[1].u_ram.load_image(dmem_path);
        if($value$plusargs("DDR=%s",ddr_path)) u_ddr.load_image(ddr_path);
        // 仅修改保留的运行配置区；指令/DDR 文件保持原镜像身份。
        if(p2_platform_enable) begin
            #1ps; // 所有时钟配置 initial 完成后才换算周期。
            p2_periph_period_ps=soc_metrics_pkg::clock_period_ps(periph_half);
            set_platform_word(32'h01100110,32'h50324346);
            set_platform_word(32'h01100114,32'd1);
            set_platform_word(32'h01100118,p2_periph_period_ps);
            set_platform_word(32'h0110011c,32'(clock_config));
            $display("P2_PLATFORM magic=50324346 version=1 periph_period_ps=%0d clock=%0d",p2_periph_period_ps,clock_config);
        end
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
                if($test$plusargs("P2_EXPECT_M1")) begin
                    assert(p2_metrics_enable&&roi_ddr_retired==0&&roi_ddr_if==0&&roi_ddr_data==0)
                        else $fatal(1,"M1 measured window executed/accessed DDR or metrics disabled");
                end
                assert(test_code==((32'(expected_exit)<<1)|32'd1)) else $fatal(1,"FAIL %s code=%0d pc=%h",test_name,test_code,commit_pc);
                if(p2_roi_enable) begin
                    assert(p2_roi_seen && p2_roi_phase==2) else $fatal(1,"P2 ROI did not start/end");
                    $display("P2_ROI core_cycles=%0d sys_cycles=%0d cpu_ddr_ar=%0d cpu_ddr_aw=%0d dma_ar=%0d dma_aw=%0d dma_rbeats=%0d dma_wbeats=%0d max_cpu_ar_wait=%0d max_dma_ar_wait=%0d",
                        p2_core_cycles,p2_sys_cycles,p2_cpu_ddr_ar,p2_cpu_ddr_aw,p2_dma_ar,p2_dma_aw,
                        p2_dma_rbeats,p2_dma_wbeats,p2_max_cpu_ar_wait,p2_max_dma_ar_wait);
                end
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
