// Module: tb_mm3_soc
// Description: Runs a bare-metal C image and passively observes console and tohost Stores.
module tb_mm3_soc #(
    parameter int unsigned DDR_BYTES = 128*1024*1024,
    parameter int unsigned DDR_MODEL_BYTES = DDR_BYTES,
    parameter logic [31:0] CLOCK_HZ = 50000000,
    parameter logic [31:0] UART_DIVISOR = 434,
    parameter bit DMA_WIDE_ENABLE = 1'b0,
    parameter bit DMA_BLOCK_ENABLE = 1'b0,
    parameter bit CACHE_BLOCK_ENABLE = 1'b0,
    parameter bit DCACHE_ENABLE = 1'b1,
    parameter bit LOCAL_TCM_ENABLE = 1'b0,
    parameter int unsigned SOC_PROFILE = soc_config_pkg::SOC_PROFILE_FULL,
    parameter bit MM3_ACCEL_ENABLE = 1'b1,
    parameter int unsigned MM3_MAC_LANES = 16,
    parameter int unsigned RESULT_BYTES = 4
);
    timeunit 1ns;
    timeprecision 1ps;

    import core_config_pkg::*;
    import core_types_pkg::*;

    localparam int unsigned BYTE_OFFSET_W = $clog2(DBUS_BYTES);

    logic [1:0] uart_rx;
    logic uart_loopback, gpio_loopback;
    logic [1:0] uart_tx;
    logic [31:0] gpio_in [3];
    logic [31:0] gpio_out [3], gpio_oe [3];
    logic ddr_req_valid, ddr_req_ready, ddr_rsp_valid, ddr_rsp_ready;
    bus_types_pkg::bus_req_t ddr_request;
    bus_types_pkg::bus_rsp_t ddr_response;
    logic dma_wide_req_valid, dma_wide_req_ready, dma_wide_rsp_valid, dma_wide_rsp_ready;
    bus_types_pkg::ddr_req_t dma_wide_request;
    bus_types_pkg::ddr_rsp_t dma_wide_response;
    logic [1:0] cache_rd_cmd_valid, cache_rd_cmd_ready, cache_rd_valid, cache_rd_ready;
    logic [1:0] cache_wr_cmd_valid, cache_wr_cmd_ready, cache_wr_valid, cache_wr_ready;
    logic [1:0] cache_wr_rsp_valid, cache_wr_rsp_ready;
    block_types_pkg::block_cmd_t cache_rd_cmd [2], cache_wr_cmd [2];
    block_types_pkg::block_r_t cache_rd_data [2];
    block_types_pkg::block_w_t cache_wr_data [2];
    block_types_pkg::block_b_t cache_wr_rsp [2];
    logic dma_block_rd_cmd_valid, dma_block_rd_cmd_ready, dma_block_rd_valid, dma_block_rd_ready;
    logic dma_block_wr_cmd_valid, dma_block_wr_cmd_ready, dma_block_wr_valid, dma_block_wr_ready;
    logic dma_block_wr_rsp_valid, dma_block_wr_rsp_ready;
    block_types_pkg::block_cmd_t dma_block_rd_cmd, dma_block_wr_cmd;
    block_types_pkg::block_r_t dma_block_rd_data;
    block_types_pkg::block_w_t dma_block_wr_data;
    block_types_pkg::block_b_t dma_block_wr_rsp;
    logic dma_axi_read_pending_q, dma_axi_write_pending_q;
    integer dma_axi_reads = 0, dma_axi_writes = 0, dma_axi_read_beats = 0, dma_axi_write_beats = 0;
    integer dma_axi_read_bursts = 0, dma_axi_write_bursts = 0, dma_axi_overlap_cycles = 0;
    logic clk = 1'b0;
    logic rst = 1'b1;
    logic commit_valid;
    logic [XLEN-1:0] commit_pc;
    logic [31:0] commit_inst;
    logic [4:0] commit_rd;
    logic commit_rd_we;
    logic [XLEN-1:0] commit_rd_data;
    logic commit_exception;
    pipeline_pkg::retire_trace_t commit_trace [2];
    logic dmem_store_fire;
    logic [XLEN-1:0] dmem_store_addr;
    logic [XLEN-1:0] dmem_store_data;
    logic [DBUS_BYTES-1:0] dmem_store_strb;
    logic [XLEN-1:0] result_addr;
    logic [XLEN-1:0] console_addr;
    logic test_done;
    logic test_pass;
    logic [31:0] test_code;
    string imem_path;
    string dmem_path;
    string test_name;
    longint unsigned max_cycles = 1000000000000;
    longint unsigned cycles = 0;
    logic trace_enable;
    logic [31:0] fault_read_addr = 32'hffffffff, fault_write_addr = 32'hffffffff;

    // 成功时先跳出采样循环，统一结束仿真，避免继续执行循环后的超时路径。
    logic completed = 1'b0;

    always #5 clk = ~clk;
    assign uart_rx = uart_loopback ? uart_tx : 2'b11;
    for (genvar g = 0; g < 3; g++) begin : g_gpio_loopback
        assign gpio_in[g] = gpio_loopback ? (gpio_out[g] & gpio_oe[g]) : '0;
    end

    soc_top #(.DDR_BYTES(DDR_BYTES), .MM3_ACCEL_ENABLE(MM3_ACCEL_ENABLE), .MM3_MAC_LANES(MM3_MAC_LANES), .DMA_WIDE_ENABLE(DMA_WIDE_ENABLE), .DMA_BLOCK_ENABLE(DMA_BLOCK_ENABLE), .CACHE_BLOCK_ENABLE(CACHE_BLOCK_ENABLE), .DCACHE_ENABLE(DCACHE_ENABLE),
              .LOCAL_TCM_ENABLE(LOCAL_TCM_ENABLE), .SOC_PROFILE(SOC_PROFILE),
              .CLOCK_HZ(CLOCK_HZ), .UART_DIVISOR(UART_DIVISOR)) dut (.*);
    if (DDR_BYTES != 0) begin : g_external
        logic awvalid, awready, awid, awlock, wvalid, wready, wlast;
        logic arvalid, arready, arid, arlock, bvalid, bready, bid, rvalid, rready, rid, rlast;
        logic [31:0] awaddr, araddr;
        logic [7:0] awlen, arlen;
        logic [2:0] awsize, arsize, awprot, arprot;
        logic [1:0] awburst, arburst, bresp, rresp;
        logic [3:0] awcache, awqos, awregion, arcache, arqos, arregion;
        logic [255:0] wdata, rdata;
        logic [31:0] wstrb;
        logic rd_cmd_valid, rd_cmd_ready, rd_valid, rd_ready;
        logic wr_cmd_valid, wr_cmd_ready, wr_valid, wr_ready, wr_rsp_valid, wr_rsp_ready;
        block_types_pkg::block_cmd_t rd_cmd, wr_cmd;
        block_types_pkg::block_r_t rd_data;
        block_types_pkg::block_w_t wr_data;
        block_types_pkg::block_b_t wr_rsp;
        ddr_block_fabric #(.DDR_BYTES(DDR_BYTES)) u_port (
            .clk, .rst, .cpu_req_valid(ddr_req_valid), .cpu_req_ready(ddr_req_ready), .cpu_request(ddr_request),
            .cpu_rsp_valid(ddr_rsp_valid), .cpu_rsp_ready(ddr_rsp_ready), .cpu_response(ddr_response),
            .dma_req_valid(dma_wide_req_valid), .dma_req_ready(dma_wide_req_ready), .dma_request(dma_wide_request),
            .dma_rsp_valid(dma_wide_rsp_valid), .dma_rsp_ready(dma_wide_rsp_ready), .dma_response(dma_wide_response),
            .cache_rd_cmd_valid, .cache_rd_cmd_ready, .cache_rd_cmd, .cache_rd_valid, .cache_rd_ready, .cache_rd_data,
            .cache_wr_cmd_valid, .cache_wr_cmd_ready, .cache_wr_cmd, .cache_wr_valid, .cache_wr_ready, .cache_wr_data,
            .cache_wr_rsp_valid, .cache_wr_rsp_ready, .cache_wr_rsp,
            .dma_block_rd_cmd_valid, .dma_block_rd_cmd_ready, .dma_block_rd_cmd,
            .dma_block_rd_valid, .dma_block_rd_ready, .dma_block_rd_data,
            .dma_block_wr_cmd_valid, .dma_block_wr_cmd_ready, .dma_block_wr_cmd,
            .dma_block_wr_valid, .dma_block_wr_ready, .dma_block_wr_data,
            .dma_block_wr_rsp_valid, .dma_block_wr_rsp_ready, .dma_block_wr_rsp,
            .rd_cmd_valid, .rd_cmd_ready, .rd_cmd, .rd_valid, .rd_ready, .rd_data,
            .wr_cmd_valid, .wr_cmd_ready, .wr_cmd, .wr_valid, .wr_ready, .wr_data,
            .wr_rsp_valid, .wr_rsp_ready, .wr_rsp
        );
        block_to_axi #(.DDR_BYTES(DDR_BYTES)) u_bridge (
            .clk, .rst, .rd_cmd_valid, .rd_cmd_ready, .rd_cmd, .rd_valid, .rd_ready, .rd_data,
            .wr_cmd_valid, .wr_cmd_ready, .wr_cmd, .wr_valid, .wr_ready, .wr_data,
            .wr_rsp_valid, .wr_rsp_ready, .wr_rsp,
            .awvalid, .awready, .awid, .awaddr, .awlen, .awsize, .awburst,
            .awlock, .awcache, .awqos, .awregion, .awprot,
            .wvalid, .wready, .wdata, .wstrb, .wlast, .bvalid, .bready, .bid, .bresp,
            .arvalid, .arready, .arid, .araddr, .arlen, .arsize, .arburst,
            .arlock, .arcache, .arqos, .arregion, .arprot,
            .rvalid, .rready, .rid, .rdata, .rresp, .rlast
        );
        // 地址译码/桥保持完整 DDR 容量；仿真可只分配用于本次负载的低地址窗口，
        // 窗口之外由模型返回错误，不能据此宣称验证了全部物理 DDR。
        axi_block_memory_model #(.BYTES(DDR_MODEL_BYTES)) u_external (
            .clk, .rst, .fault_read_addr,
            .fault_write_addr,
            .awvalid, .awready, .awid, .awaddr, .awsize, .awlen,
            .wvalid, .wready, .wdata, .wstrb, .wlast, .bvalid, .bready, .bid, .bresp,
            .arvalid, .arready, .arid, .araddr, .arsize, .arlen,
            .rvalid, .rready, .rid, .rdata, .rresp, .rlast
        );
    end
    string data_path, model_path, tokenizer_path, result_path;
    int backend = 0, mode = 0, case_index = 0, trace_mode = 0, allocation_fail = 0, expected_exit = 0;
    logic observed_store;
    xlen_t observed_addr, observed_data;
    logic [DBUS_BYTES-1:0] observed_strb;
    xlen_t observed_byte_addr;
    always_ff @(posedge clk) begin
        if(rst)begin observed_store<=0;observed_addr<=0;observed_data<=0;observed_strb<=0;end
        else begin
            observed_store<=dmem_store_fire;
            if(dmem_store_fire)begin observed_addr<=dmem_store_addr;observed_data<=dmem_store_data;observed_strb<=dmem_store_strb;end
        end
    end
    // PASS 必须关联同一个动态 Store 的请求、成功响应与正常退休。
    // Console 仍可提前观察；它只用于进度，不参与验收结论。
`ifdef CORE_SCOREBOARD
    logic result_store_retire, result_store_error;
    pipeline_pkg::retire_id_t result_store_id;
    always_comb begin
        result_store_retire = 0;
        result_store_error = 0;
        result_store_id = '0;
        for (int lane = 0; lane < 2; lane++) begin
            if (dut.u_core.retire_fire[lane] &&
                dut.u_core.head_metadata[lane].kind == pipeline_pkg::RET_STORE) begin
                result_store_retire = 1;
                result_store_error = dut.u_core.head_results[lane].exc.valid;
                result_store_id = dut.u_core.head_ids[lane];
            end
        end
    end
    store_result_monitor u_result_monitor (
        .store_request_id(dut.u_core.store_request_id),
        .store_response_fire(dut.u_core.store_response_fire),
        .store_response_error(dut.u_core.store_response_error),
        .store_response_id(dut.u_core.store_response_id),
        .store_retire_fire(result_store_retire),
        .store_retire_error(result_store_error), .store_retire_id(result_store_id),
        .cancel(dut.u_core.wb_redirect.valid), .*
    );
`else
    store_result_monitor u_result_monitor (
        .store_request_id(dut.u_core.lsu_owner_id),
        .store_response_fire(dut.u_core.dmem_rsp_valid && dut.u_core.dmem_rsp_ready &&
                             dut.u_core.lsu_owner_valid && dut.u_core.dmem_req_write),
        .store_response_error(dut.u_core.dmem_rsp_error),
        .store_response_id(dut.u_core.lsu_owner_id),
        .store_retire_fire(dut.u_core.queue_retire_fire &&
                           dut.u_core.head_meta.kind == pipeline_pkg::RET_STORE),
        .store_retire_error(dut.u_core.head_result.exc.valid),
        .store_retire_id(dut.u_core.head_id),
        .cancel(dut.u_core.wb_redirect.valid), .*
    );
`endif
    longint unsigned next_progress = 1000000;
    longint unsigned dma_commands=0, accel_commands=0, shared_overlap=0;
    if(MM3_ACCEL_ENABLE) begin : g_observe_accelerator
    always @(posedge clk) if(!rst)begin
        if(dut.mm3_c_rd_cmd_valid[0]&&dut.mm3_c_rd_cmd_ready[0])dma_commands++;
        if(dut.mm3_c_rd_cmd_valid[1]&&dut.mm3_c_rd_cmd_ready[1])accel_commands++;
        if(dut.g_mm3_accel.u_accel.busy && (dut.mm3_c_rd_cmd_valid[0]||dut.mm3_c_wr_cmd_valid[0]))shared_overlap++;
    end
    end
    task automatic set_byte(input int unsigned offset, input logic [7:0] value);
        g_external.u_external.mem[offset/DBUS_BYTES][(offset%DBUS_BYTES)*8 +:8] = value;
    endtask
    function automatic logic [31:0] get_word(input int unsigned offset);
        logic [31:0] v;
        for (int i=0;i<4;i++) v[i*8 +:8] = g_external.u_external.mem[(offset+32'(i))/DBUS_BYTES][((offset+32'(i))%DBUS_BYTES)*8 +:8];
        return v;
    endfunction
    task automatic set_word(input int unsigned offset,input logic [31:0] value);
        for(int i=0;i<4;i++) set_byte(offset+32'(i),value[i*8 +:8]);
    endtask
    task automatic load_bytes(input string path,input int unsigned offset);
        byte unsigned bytes [65536];
        int fd, count, rc, loaded, chunk;
        fd=$fopen(path,"rb"); if(!fd)$fatal(1,"open image %s",path);
        rc=$fseek(fd,0,2); count=$ftell(fd); rc=$fseek(fd,0,0);
        if(count<0 || 64'(offset)+64'(count)>64'(DDR_MODEL_BYTES))$fatal(1,"image does not fit: %s",path);
        loaded=0;
        while(loaded<count)begin
            chunk=count-loaded<65536?count-loaded:65536;
            rc=$fread(bytes,fd,0,chunk);if(rc!=chunk)$fatal(1,"short image %s",path);
            for(int i=0;i<chunk;i++)set_byte(offset+32'(loaded+i),bytes[i]);
            loaded+=chunk;
        end
        $fclose(fd);
        $display("MM3 LOAD %s bytes=%0d",path,count);
    endtask
    task automatic dump_bytes(input string path,input int unsigned offset,input int unsigned count);
        int fd;
        fd=$fopen(path,"wb");if(!fd)$fatal(1,"open result %s",path);
        for(int unsigned i=0;i<count;i++)$fwrite(fd,"%c",g_external.u_external.mem[(offset+i)/DBUS_BYTES][((offset+i)%DBUS_BYTES)*8 +:8]);
        $fclose(fd);
    endtask
    task automatic dump_values;
        int fd;
        int unsigned addr,count;
        addr=get_word('h00401000+11*4);count=get_word('h00401000+12*4);
        if(addr<32'h80000000||64'(addr)-64'h80000000+64'(count)>64'(DDR_MODEL_BYTES)||count>25600)$fatal(1,"invalid result vector");
        fd=$fopen({result_path,".values"},"wb");if(!fd)$fatal(1,"open vector dump");
        for(int unsigned i=0;i<count;i++)$fwrite(fd,"%c",g_external.u_external.mem[(addr-32'h80000000+i)/DBUS_BYTES][((addr+i)%DBUS_BYTES)*8 +:8]);
        for(int i=0;i<8;i++)$fwrite(fd,"%c",8'(get_word('h00401000+9*4+32'(i/4)*4) >> (8*(i%4))));
        $fclose(fd);
    endtask
    initial begin
        uart_loopback=0;gpio_loopback=0;
        if(!$value$plusargs("IMEM=%s",imem_path) || !$value$plusargs("DATA=%s",data_path) ||
           !$value$plusargs("RESULT=%s",result_path))$fatal(1,"missing image/result arguments");
        if(!$value$plusargs("TOHOST=%h",result_addr) || !$value$plusargs("CONSOLE=%h",console_addr))$fatal(1,"missing BSP symbols");
        void'($value$plusargs("BACKEND=%d",backend));void'($value$plusargs("MODE=%d",mode));
        void'($value$plusargs("CASE=%d",case_index));void'($value$plusargs("TRACE=%d",trace_mode));
        void'($value$plusargs("MAX_CYCLES=%d",max_cycles));
        void'($value$plusargs("ALLOC_FAIL=%d",allocation_fail));void'($value$plusargs("EXPECTED_EXIT=%d",expected_exit));
        // 初值只装载软件和资产；所有推理均由 RTL CPU 与可综合加速器实际执行。
        #1;
`ifdef CORE_SCOREBOARD
        dut.u_memory.u_itcm.load_image(imem_path);
`else
        $readmemh(imem_path,dut.u_itcm.mem);
`endif
        load_bytes(data_path,0);
        if(mode!=0&&mode!=4)begin
            if(!$value$plusargs("MODEL=%s",model_path) || !$value$plusargs("TOKENIZER=%s",tokenizer_path))$fatal(1,"missing model assets");
            load_bytes(model_path,'h01000000);load_bytes(tokenizer_path,'h05000000);
        end
        set_word('h00400000,32'(backend));set_word('h00400004,32'(mode));
        set_word('h00400008,32'(case_index));set_word('h0040000c,32'(trace_mode));set_word('h00400010,32'(allocation_fail));
        repeat(5)@(negedge clk);rst=0;
        forever begin
            @(negedge clk);cycles++;
            if(observed_store)for(int lane=0;lane<DBUS_BYTES;lane++)if(observed_strb[lane])begin
                observed_byte_addr=(observed_addr & ~xlen_t'(DBUS_BYTES-1))+xlen_t'(lane);
                if(observed_byte_addr==console_addr)$write("%c",observed_data[lane*8 +:8]);
            end
            if(test_done)begin
                if((test_code>>1)!=32'(expected_exit))$fatal(1,"MM3 program failed code=%0d expected=%0d PC=%h",test_code>>1,expected_exit,commit_pc);
                if(expected_exit!=0)begin $display("PASS MM3_EXPECTED_FAILURE code=%0d alloc_fail=%0d",expected_exit,allocation_fail);$finish;end
                if(mode==4)begin
                    assert(dma_commands>0 && (backend==0 || (accel_commands>0 && shared_overlap>0)))
                        else $fatal(1,"missing real DMA/accelerator overlap");
                    $display("PASS MM3_CONCURRENT dma=%0d accel=%0d overlap=%0d",dma_commands,accel_commands,shared_overlap);
                end
                dump_bytes(result_path,'h00401000,512);dump_values();
                if(trace_mode!=0)dump_bytes({result_path,".trace"},'h00410000,get_word('h00401000+120*4));
                $display("PASS MM3_SOC RV%0d backend=%0d mode=%0d case=%0d cycles=%0d",XLEN,backend,mode,case_index,cycles);
                $finish;
            end
            if(cycles==next_progress)begin
                $display("MM3 PROGRESS cycles=%0d PC=%h",cycles,commit_pc);$fflush();next_progress+=1000000;
            end
            if(cycles>=max_cycles)$fatal(1,"MM3 timeout cycles=%0d PC=%h",cycles,commit_pc);
        end
    end
endmodule
