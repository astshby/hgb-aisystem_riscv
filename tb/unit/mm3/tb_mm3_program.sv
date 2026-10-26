// Module: tb_mm3_program
// Description: CPU-free operator-chain BFM; expected data is never injected into the DUT pipeline.
module tb_mm3_program;
    timeunit 1ns;timeprecision 1ps;
    import core_config_pkg::*;import core_types_pkg::*;import bus_types_pkg::*;import block_types_pkg::*;import mm3_config_pkg::*;
    logic clk = 0, rst = 1;
    logic req_valid = 0, req_ready, rsp_valid, rsp_ready = 1;
    bus_req_t request;
    bus_rsp_t response;
    logic rd_cmd_valid, rd_cmd_ready, rd_valid, rd_ready;
    block_cmd_t rd_cmd;
    block_r_t rd_data;
    logic wr_cmd_valid, wr_cmd_ready, wr_valid, wr_ready, wr_rsp_valid, wr_rsp_ready;
    block_cmd_t wr_cmd;
    block_w_t wr_data;
    block_b_t wr_rsp;
    logic awvalid, awready, awid, awlock, wvalid, wready, wlast;
    logic arvalid, arready, arid, arlock, bvalid, bready, bid, rvalid, rready, rid, rlast;
    logic [31:0] awaddr, araddr;
    logic [7:0] awlen, arlen;
    logic [2:0] awsize, arsize, awprot, arprot;
    logic [1:0] awburst, arburst, bresp, rresp;
    logic [3:0] awcache, awqos, awregion, arcache, arqos, arregion;
    logic [255:0] wdata, rdata;
    logic [31:0] wstrb;
    logic [31:0] fault_read_addr = 32'hffffffff, fault_write_addr = 32'hffffffff;
    always #5 clk=~clk;
    mm3_accel #(.DDR_BYTES(MM3_DDR_BYTES)) dut(.*);
    block_to_axi #(.DDR_BYTES(MM3_DDR_BYTES)) bridge(.*);
    axi_block_memory_model #(.BYTES(MM3_DDR_BYTES)) memory(.*);
    string image_path,commands_path,ranges_path,control_path,result_path;
    logic[31:0] value,status,command,opcode,count,ranges;
    longint unsigned cycles=0;
    always @(posedge clk)if(!rst)begin cycles<=cycles+1;if(cycles>=64'(MM3_TIMEOUT_CYCLES))$fatal(1,"MM3 program timeout cycles=%0d",cycles);end
    task automatic put_byte(input int unsigned offset,input logic[7:0] v);
        memory.mem[offset/DBUS_BYTES][(offset%DBUS_BYTES)*8+:8]=v;
    endtask
    function automatic logic[31:0] word_at(input logic[31:0] address);
        logic[31:0] v;int unsigned offset;
        offset=address-32'h80000000;v=0;
        assert(64'(offset)+4<=64'(MM3_DDR_BYTES))else $fatal(1,"BFM address outside DDR");
        for(int i=0;i<4;i++)v[i*8+:8]=memory.mem[(offset+32'(i))/DBUS_BYTES][((offset+32'(i))%DBUS_BYTES)*8+:8];
        return v;
    endfunction
    function automatic logic[31:0] mm3_trace_word(input logic[31:0] address);
        return word_at(address);
    endfunction
`include "tb/unit/mm3/mm3_trace_tasks.svh"
    task automatic load_file(input string path,input int unsigned offset);
        int fd,rc,n,loaded,got;byte unsigned chunk[65536];
        fd=$fopen(path,"rb");if(fd==0)$fatal(1,"open %s",path);
        rc=$fseek(fd,0,2);n=$ftell(fd);rc=$fseek(fd,0,0);loaded=0;
        if(n<0||64'(offset)+64'(n)>64'(MM3_DDR_BYTES))$fatal(1,"image range");
        while(loaded<n)begin got=$fread(chunk,fd,0,n-loaded<65536?n-loaded:65536);if(got<=0)$fatal(1,"read %s",path);for(int i=0;i<got;i++)put_byte(offset+32'(loaded+i),chunk[i]);loaded+=got;end
        $fclose(fd);
    endtask
    task automatic mmio(input bit wr,input logic[31:0] offset,data,input bit expect_error=0);
        logic[31:0] lane;bus_rsp_t captured;
        @(negedge clk);request='0;request.addr=xlen_t'(32'h10050000+offset);request.size=MEM_WORD;request.write=wr;
        lane=(32'h10050000+offset)%DBUS_BYTES;request.wdata=xlen_t'(data)<<(lane*8);request.wstrb=DBUS_BYTES'(4'hf)<<lane;
        req_valid=1;do @(posedge clk);while(!req_ready);
        @(negedge clk);req_valid=0;
        while(!rsp_valid)@(negedge clk);
        captured=response;repeat(2)begin @(posedge clk);assert(rsp_valid&&response==captured)else $fatal(1,"MMIO response changed under backpressure");end
        assert((response.error!=BUS_OK)==expect_error)else $fatal(1,"MMIO error offset=%h code=%0d",offset,response.error);
        value=32'(response.rdata>>(lane*8));@(negedge clk);rsp_ready=1;@(posedge clk);@(negedge clk);rsp_ready=0;
    endtask
    task automatic dump_result;
        int fd;logic[31:0] p,n;
        fd=$fopen(result_path,"wb");if(fd==0)$fatal(1,"open result");
        for(int r=0;r<int'(ranges);r++)begin
            p=word_at(32'h80420000+32'(r)*8);n=word_at(32'h80420004+32'(r)*8);
            if(p<32'h80000000||64'(p)+64'(n)>64'h80000000+64'(MM3_DDR_BYTES))$fatal(1,"result range");
            for(int i=0;i<int'(n);i++)$fwrite(fd,"%c",8'(word_at((p+32'(i))&32'hfffffffc)>>(8*((p+32'(i))%4))));
        end
        $fclose(fd);
    endtask
    initial begin
        rsp_ready=0;request='0;
        if(!$value$plusargs("IMAGE=%s",image_path)||!$value$plusargs("COMMANDS=%s",commands_path)||!$value$plusargs("RANGES=%s",ranges_path)||!$value$plusargs("CONTROL=%s",control_path)||!$value$plusargs("RESULT=%s",result_path))$fatal(1,"missing fixture paths");
        #1;load_file(image_path,'h01000000);load_file(commands_path,'h00410000);load_file(ranges_path,'h00420000);load_file(control_path,'h00400100);
        count=word_at(32'h80400104);ranges=word_at(32'h80400114);
        if(count==0||count>MM3_MAX_COMMANDS||ranges>MM3_MAX_COMMANDS)$fatal(1,"fixture count");
        repeat(5)@(negedge clk);rst=0;
        for(int i=0;i<int'(count);i++)begin
            command=32'h80410000+32'(i)*128;opcode=word_at(command+4);
            mmio(1,12,6);
            if(opcode==0)begin
                mmio(1,20,word_at(command+8));mmio(1,24,word_at(command+16));
                mmio(1,28,word_at(command+24));mmio(1,32,word_at(command+28));mmio(1,36,word_at(command+40));
                mmio(1,40,word_at(command+32));mmio(1,44,word_at(command+44));
                mmio(1,48,word_at(word_at(command+36)));mmio(1,52,word_at(word_at(command+36)+4));mmio(1,56,0);
            end else begin mmio(1,'h90,opcode);mmio(1,'h94,command);end
            mmio(1,8,1);
            // 单命令在途：忙时启动必须拒绝，不能重置正在计算的结果。
            if(i==0)mmio(1,8,1,1);
            do begin mmio(0,12,0);status=value;end while(status[0]);
            if(status!=2)begin mmio(0,16,0);$fatal(1,"operator %0d opcode=%0d error=%0d",i,opcode,value);end
            mmio(0,12,0);assert(value==2)else $fatal(1,"DONE must persist");
            mm3_trace_command(32'(i),command);
            $display("MM3_OP_DONE index=%0d op=%0d cycles=%0d",i,opcode,cycles);
        end
        // 零长度的合法 ABI 描述符必须返回配置错误，并保持 ERROR 直到 W1C。
        for(int i=0;i<128;i++)put_byte('h00430000+32'(i),0);
        for(int i=0;i<4;i++)put_byte('h00430000+32'(i),8'(32'h334f5031>>(8*i)));
        put_byte('h00430004,1);
        mmio(1,12,6);mmio(1,'h90,1);mmio(1,'h94,'h80430000);mmio(1,8,1);
        do begin mmio(0,12,0);status=value;end while(status[0]);
        assert(status==4)else $fatal(1,"invalid size did not produce ERROR");
        mmio(0,16,0);assert(value==1)else $fatal(1,"invalid size error code");
        mmio(0,12,0);assert(value==4)else $fatal(1,"ERROR must persist");
        mmio(1,12,6);mmio(0,12,0);assert(value==0)else $fatal(1,"W1C failed");
        dump_result();$display("PASS MM3_PROGRAM commands=%0d cycles=%0d",count,cycles);$finish;
    end
endmodule
