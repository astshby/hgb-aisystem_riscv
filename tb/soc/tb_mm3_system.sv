// Module: tb_mm3_system
// Description: Original MiniMind fixtures on the five-domain main SoC and shared DDR fabric.
module tb_mm3_system #(
    parameter bit OP_PROGRAM=0,
    parameter int DDR_BYTES=128*1024*1024,
    parameter int DDR_MODEL_BYTES=DDR_BYTES,
    parameter bit MM3_ACCEL_ENABLE=1,
    parameter int MM3_MAC_LANES=16,
    parameter int CLOCK_PROFILE=1,
    parameter int NPU_PERIOD_PS=10000
);
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    tb_soc_system #(.DDR_BYTES(DDR_BYTES),.DDR_MODEL_BYTES(DDR_MODEL_BYTES),
        .FLASH_BYTES(0),.MM3_ENABLE(MM3_ACCEL_ENABLE),.MM3_MAC_LANES(MM3_MAC_LANES),
        .CLOCK_PROFILE(CLOCK_PROFILE),.NPU_PERIOD_PS(NPU_PERIOD_PS),.AUTO_FINISH(0)) u_test();
    string data_path, model_path, tokenizer_path, result_path;
    string op_image, op_commands, op_ranges, op_control;
    int backend=0, mode=0, case_index=0, trace_mode=0, allocation_fail=0, expected_exit=0;
    longint unsigned dma_commands=0, accel_commands=0, shared_overlap=0;
    if (MM3_ACCEL_ENABLE) begin : g_observe_accelerator
        int trace_events=0, memory_trace_events=0;
        always @(posedge u_test.g_mm3.clk_npu) if ($test$plusargs("MM3_BUS_TRACE") && !u_test.g_mm3.rst_npu && memory_trace_events<40) begin
            if (u_test.g_mm3.u_npu.local_memory.ar_valid && u_test.g_mm3.u_npu.local_memory_rsp.ar_ready) begin
                $display("MM3_AXI_AR addr=%h len=%0d",u_test.g_mm3.u_npu.local_memory.ar.addr,u_test.g_mm3.u_npu.local_memory.ar.len);
                memory_trace_events++;
            end
            if (u_test.g_mm3.u_npu.local_memory_rsp.r_valid && u_test.g_mm3.u_npu.local_memory.r_ready) begin
                $display("MM3_AXI_R id=%h resp=%h last=%b data=%h",u_test.g_mm3.u_npu.local_memory_rsp.r.id,u_test.g_mm3.u_npu.local_memory_rsp.r.resp,u_test.g_mm3.u_npu.local_memory_rsp.r.last,u_test.g_mm3.u_npu.local_memory_rsp.r.data);
                memory_trace_events++;
            end
            if (u_test.g_mm3.u_npu.rd_valid && u_test.g_mm3.u_npu.rd_ready) begin
                $display("MM3_BLOCK_R last=%b err=%h",u_test.g_mm3.u_npu.rd_data.last,u_test.g_mm3.u_npu.rd_data.error);
                memory_trace_events++;
            end
        end
        always @(posedge u_test.g_mm3.clk_npu) if ($test$plusargs("MM3_BUS_TRACE") && !u_test.g_mm3.rst_npu && trace_events<40) begin
            if (u_test.g_mm3.u_npu.req_valid && u_test.g_mm3.u_npu.req_ready) begin
                $display("MM3_CONTROL write=%b address=%h data=%h",u_test.g_mm3.u_npu.request.write,u_test.g_mm3.u_npu.request.addr,u_test.g_mm3.u_npu.request.wdata);
                trace_events++;
            end
            if (u_test.g_mm3.u_npu.rd_cmd_valid && u_test.g_mm3.u_npu.rd_cmd_ready) begin
                $display("MM3_READ address=%h len=%0d",u_test.g_mm3.u_npu.rd_cmd.addr,u_test.g_mm3.u_npu.rd_cmd.len);
                trace_events++;
            end
        end
        // 仅为 TB 统计跨域活动，不用于驱动 RTL 或判定数据正确性。
        always @(posedge u_test.clk_sys) if (!u_test.dut.rst_sys) begin
            if(u_test.dut.masters[2].ar_valid && u_test.dut.master_responses[2].ar_ready) dma_commands++;
            if(u_test.external_req.ar_valid && u_test.external_rsp.ar_ready) accel_commands++;
            if(u_test.g_mm3.u_npu.u_accel.busy &&
               (u_test.dut.masters[2].ar_valid || u_test.dut.masters[2].aw_valid)) shared_overlap++;
        end
    end
    task automatic set_byte(input int unsigned offset, input logic [7:0] value);
        u_test.u_ddr.mem[offset] = value;
    endtask
    function automatic logic [31:0] get_word(input int unsigned offset);
        logic [31:0] v;
        for (int i=0;i<4;i++) v[i*8 +:8] = u_test.u_ddr.mem[offset+32'(i)];
        return v;
    endfunction
    function automatic logic[31:0] mm3_trace_word(input logic[31:0] address);
        return get_word(address-32'h80000000);
    endfunction
`include "tb/unit/mm3/mm3_trace_tasks.svh"
    if(OP_PROGRAM&&MM3_ACCEL_ENABLE)begin:g_op_trace
        bit previous_busy;
        int unsigned command_index;
        always @(posedge u_test.g_mm3.clk_npu)begin
            if(u_test.g_mm3.rst_npu)begin previous_busy<=0;command_index<=0;end
            else begin
                previous_busy<=u_test.g_mm3.u_npu.u_accel.busy;
                if(previous_busy&&!u_test.g_mm3.u_npu.u_accel.busy)begin
                    mm3_trace_command(command_index,32'h80410000+command_index*128);
                    command_index<=command_index+1;
                end
            end
        end
    end
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
        for(int unsigned i=0;i<count;i++)$fwrite(fd,"%c",u_test.u_ddr.mem[offset+i]);
        $fclose(fd);
    endtask
    task automatic dump_values;
        int fd;
        int unsigned addr,count;
        addr=get_word('h00401000+11*4);count=get_word('h00401000+12*4);
        if(addr<32'h80000000||64'(addr)-64'h80000000+64'(count)>64'(DDR_MODEL_BYTES)||count>25600)$fatal(1,"invalid result vector");
        fd=$fopen({result_path,".values"},"wb");if(!fd)$fatal(1,"open vector dump");
        for(int unsigned i=0;i<count;i++)$fwrite(fd,"%c",u_test.u_ddr.mem[addr-32'h80000000+i]);
        for(int i=0;i<8;i++)$fwrite(fd,"%c",8'(get_word('h00401000+9*4+32'(i/4)*4) >> (8*(i%4))));
        $fclose(fd);
    endtask
    task automatic dump_operator_program;
        int fd;logic[31:0] address,bytes,num;
        fd=$fopen(result_path,"wb");if(!fd)$fatal(1,"open result");
        num=get_word('h00400114);if(num>mm3_config_pkg::MM3_MAX_COMMANDS)$fatal(1,"range count");
        for(int r=0;r<int'(num);r++)begin
            address=get_word('h00420000+32'(r)*8);bytes=get_word('h00420004+32'(r)*8);
            if(address<32'h80000000||64'(address)+64'(bytes)>64'h80000000+DDR_MODEL_BYTES)$fatal(1,"range bounds");
            for(int i=0;i<int'(bytes);i++)$fwrite(fd,"%c",8'(get_word((address+32'(i)-32'h80000000)&32'hfffffffc)>>(8*((address+32'(i))%4))));
        end
        $fclose(fd);
    endtask
    initial begin
        forever begin
            repeat (1000000) @(negedge u_test.clk_core);
            $display("MM3 PROGRESS cycles=%0d pc=%h accelerator_reads=%0d",u_test.cycles,u_test.commit_pc,accel_commands);
            $fflush();
        end
    end
    initial begin
        if(!$value$plusargs("DATA=%s",data_path) || !$value$plusargs("RESULT=%s",result_path))
            $fatal(1,"missing image/result arguments");
        void'($value$plusargs("BACKEND=%d",backend));void'($value$plusargs("MODE=%d",mode));
        void'($value$plusargs("CASE=%d",case_index));void'($value$plusargs("TRACE=%d",trace_mode));
        void'($value$plusargs("ALLOC_FAIL=%d",allocation_fail));void'($value$plusargs("EXPECTED_EXIT=%d",expected_exit));
        // CPU 仍在复位中。只装载程序和输入，不预计算任何推理结果。
        #1ns;
        load_bytes(data_path,0);
        if(OP_PROGRAM)begin
            if(!$value$plusargs("IMAGE=%s",op_image)||!$value$plusargs("COMMANDS=%s",op_commands)||!$value$plusargs("RANGES=%s",op_ranges)||!$value$plusargs("CONTROL=%s",op_control))$fatal(1,"missing operator fixtures");
            load_bytes(op_image,'h01000000);load_bytes(op_commands,'h00410000);load_bytes(op_ranges,'h00420000);load_bytes(op_control,'h00400100);
        end else if(mode!=0&&mode!=4)begin
            if(!$value$plusargs("MODEL=%s",model_path) || !$value$plusargs("TOKENIZER=%s",tokenizer_path))$fatal(1,"missing model assets");
            load_bytes(model_path,'h01000000);load_bytes(tokenizer_path,'h05000000);
        end
        set_word('h00400000,32'(backend));set_word('h00400004,32'(mode));
        set_word('h00400008,32'(case_index));set_word('h0040000c,32'(trace_mode));set_word('h00400010,32'(allocation_fail));
        wait(u_test.completed);
        @(negedge u_test.clk_core);
        if(expected_exit!=0) begin
            $display("PASS MM3_EXPECTED_FAILURE code=%0d alloc_fail=%0d",expected_exit,allocation_fail);
        end else begin
            if(mode==4) begin
                assert(dma_commands>0 && (backend==0 || (accel_commands>0 && shared_overlap>0)))
                    else $fatal(1,"missing real DMA/accelerator overlap");
                $display("PASS MM3_CONCURRENT dma=%0d accel=%0d overlap=%0d",dma_commands,accel_commands,shared_overlap);
            end
            if(OP_PROGRAM) begin
                assert(accel_commands>0) else $fatal(1,"operator program did not use external DDR master");
                dump_operator_program();
                $display("PASS MM3_LAYER_SOC RV%0d cycles=%0d",XLEN,u_test.cycles);
            end else begin
                dump_bytes(result_path,'h00401000,512);dump_values();
                if(trace_mode!=0) dump_bytes({result_path,".trace"},'h00410000,get_word('h00401000+120*4));
                $display("PASS MM3_SOC RV%0d backend=%0d mode=%0d case=%0d cycles=%0d",
                    XLEN,backend,mode,case_index,u_test.cycles);
            end
        end
        $display("PASS MM3_FIVE_DOMAINS RV%0d accelerator_reads=%0d",XLEN,accel_commands);
        $finish;
    end
endmodule
