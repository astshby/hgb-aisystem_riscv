// Module: tb_mm3_accel
// Description: MMIO, AXI backpressure and exact real-size GEMV comparison against standalone C.
module tb_mm3_accel #(parameter int unsigned MAC_LANES = 16);
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import bus_types_pkg::*;
    import block_types_pkg::*;
    import mm3_fixed_pkg::*;
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
    logic [31:0] cfg [10], status, value;
    logic [31:0] saved_row_m;
    logic [31:0] expected_m, expected_e, cases, expected_output [6400];
    logic [63:0] expected_sat, expected_under, expected_acc [6400];
    fixed_t expected_work [6400];
    longint unsigned cycles = 0, started;
    int fd, case_id;
    string path;
    logic checking = 0;
    always #5 clk = ~clk;
    always @(posedge clk) cycles <= cycles+1;
    mm3_accel #(.DDR_BYTES(8*1024*1024),.MAC_LANES(MAC_LANES)) dut (.*);
    block_to_axi #(.DDR_BYTES(8*1024*1024)) bridge (.*);
    axi_block_memory_model #(.BYTES(8*1024*1024)) memory (.*);
    function automatic logic [31:0] get32();
        logic [31:0] v;
        int byte_value;
        v=0;
        for (int i=0;i<4;i++) begin
            byte_value=$fgetc(fd);
            if(byte_value<0) $fatal(1,"truncated fixture");
            v |= 32'(byte_value) << (8*i);
        end
        return v;
    endfunction
    function automatic logic [63:0] get64();
        logic [31:0] lo, hi;
        lo=get32();hi=get32();return {hi,lo};
    endfunction
    task automatic put_byte(input int unsigned addr,input logic [7:0] v);
        memory.mem[addr/DBUS_BYTES][(addr%DBUS_BYTES)*8 +:8]=v;
    endtask
    function automatic logic [31:0] mem32(input int unsigned addr);
        logic [31:0] v;
        for(int i=0;i<4;i++)v[i*8 +:8]=memory.mem[(addr+i)/DBUS_BYTES][((addr+i)%DBUS_BYTES)*8 +:8];
        return v;
    endfunction
    task automatic mmio(input logic write_enable,input int unsigned offset,input logic [31:0] v,input logic error_expected);
        @(negedge clk); request='0;request.addr=xlen_t'(32'h10050000+offset);
        request.write=write_enable;request.size=MEM_WORD;
        request.wdata=xlen_t'(v) << (request.addr[$clog2(DBUS_BYTES)-1:0]*8);
        request.wstrb=DBUS_BYTES'(4'hf) << request.addr[$clog2(DBUS_BYTES)-1:0];req_valid=1;
        do @(negedge clk); while(!req_ready);
        req_valid=0;
        while(!rsp_valid) @(negedge clk);
        assert((response.error!=BUS_OK)==error_expected) else $fatal(1,"MMIO error offset=%h code=%0d",offset,response.error);
        value=32'(response.rdata >> (request.addr[$clog2(DBUS_BYTES)-1:0]*8));
        @(negedge clk);
    endtask
    task automatic wait_done(input logic error_expected);
        status=1;
        while(status[0])begin
            mmio(0,12,0,0);status=value;
            if(cycles-started>10000000)$fatal(1,"GEMV timeout state=%0d",dut.state_q);
        end
        assert(status== (error_expected?4:2))else $fatal(1,"bad completion %h code=%0d",status,dut.error_code_q);
    endtask
    always @(negedge clk) if(checking && !rst)begin
        if(int'(dut.state_q)==9)
            assert(dut.acc_q===expected_acc[dut.row_q])else $fatal(1,"MAC mismatch case=%0d row=%0d",case_id,dut.row_q);
        if(int'(dut.state_q)==12 && dut.math_done)
            assert(dut.math_result===expected_work[dut.row_q])else $fatal(1,"scaled row mismatch case=%0d row=%0d",case_id,dut.row_q);
    end
    initial begin
        request='0;
        if(!$value$plusargs("FIXTURE=%s",path))$fatal(1,"missing fixture");
        fd=$fopen(path,"rb");if(!fd)$fatal(1,"open fixture");cases=get32();
        repeat(3)@(negedge clk);rst=0;
        for(case_id=0;case_id<int'(cases);case_id++)begin
            for(int i=0;i<10;i++)cfg[i]=get32();
            for(int i=0;i<int'(cfg[0]*cfg[1]);i++)put_byte(32'h2000+32'(i),8'($fgetc(fd)));
            for(int i=0;i<int'(cfg[1]*2);i++)put_byte(32'(i),8'($fgetc(fd)));
            for(int i=0;i<int'(cfg[0]*8);i++)put_byte(32'h600000+32'(i),8'($fgetc(fd)));
            for(int i=0;i<int'(cfg[0]*4)+64;i++)put_byte(32'h610000+32'(i),8'ha5);
            for(int i=0;i<64;i++)put_byte(32'h620000+32'(i),8'ha5);
            expected_m=get32();expected_e=get32();expected_sat=get64();expected_under=get64();
            for(int i=0;i<int'(cfg[0]);i++)begin
                expected_acc[i]=get64();expected_work[i].v=64'(get64());expected_work[i].e=32'(get32());expected_output[i]=get32();
            end
            checking=1;
            for(int i=0;i<10;i++)mmio(1,20+32'(i)*4,cfg[i],0);
            started=cycles;mmio(1,8,1,0);
            mmio(1,8,1,1); // BUSY 命令不能重新启动或破坏已接收的命令。
            wait_done(0);checking=0;
            assert(mem32('h620000)==expected_m && mem32('h620004)==expected_e)else $fatal(1,"output scale mismatch case=%0d",case_id);
            for(int i=0;i<int'(cfg[0]);i++)begin
                if(cfg[9]!=0)value=mem32('h610000+32'(i)*4);
                else value=32'($signed(16'(mem32('h610000+32'(i)*2))));
                assert(value==expected_output[i])else $fatal(1,"output mismatch case=%0d row=%0d got=%h expected=%h",case_id,i,value,expected_output[i]);
            end
            assert(dut.counters[8]==expected_sat && dut.counters[9]==expected_under)else $fatal(1,"stats mismatch");
            assert(mem32('h610000+cfg[0]*(cfg[9]!=0?4:2))==32'ha5a5a5a5 && mem32('h620008)==32'ha5a5a5a5)else $fatal(1,"tail guard clobbered");
            mmio(0,12,0,0);assert(value==2)else $fatal(1,"DONE must persist");
            mmio(1,12,6,0);mmio(0,12,0,0);assert(value==0)else $fatal(1,"W1C");
            $display("PASS MM3_GEMV case=%0d rows=%0d cols=%0d bits=%0d cycles=%0d",case_id,cfg[0],cfg[1],cfg[9]!=0?32:16,cycles-started);
        end
        // 非法配置必须在发出 DDR 请求前失败；后续有效命令可以恢复。
        mmio(1,20,0,0);started=cycles;mmio(1,8,1,0);wait_done(1);
        mmio(1,20,1,0);mmio(1,24,1,0);
        fault_read_addr=32'h80000000;started=cycles;mmio(1,8,1,0);wait_done(1);fault_read_addr='1;
        fault_write_addr=32'h80610000;started=cycles;mmio(1,8,1,0);wait_done(1);fault_write_addr='1;
        started=cycles;mmio(1,8,1,0);wait_done(0);
        mmio(1,20,0,0);started=cycles;mmio(1,8,1,0);wait_done(1);
        mmio(1,20,1,0);mmio(1,24,1,0);
        saved_row_m=mem32('h600000);for(int i=0;i<4;i++)put_byte('h600000+32'(i),0);
        started=cycles;mmio(1,8,1,0);wait_done(1);assert(dut.error_code_q==2)else $fatal(1,"invalid row scale not rejected");
        for(int i=0;i<4;i++)put_byte('h600000+32'(i),saved_row_m[i*8 +:8]);
        for(int i=0;i<10;i++)mmio(1,20+32'(i)*4,cfg[i],0);
        mmio(1,8,1,0);repeat(10)@(negedge clk);rst=1;repeat(3)@(negedge clk);rst=0;
        for(int i=0;i<10;i++)mmio(1,20+32'(i)*4,cfg[i],0);
        checking=1;started=cycles;mmio(1,8,1,0);wait_done(0);checking=0;
        $display("PASS MM3_RESET reset during active DMA and subsequent exact row processing");
        $display("PASS MM3_ACCEL %0d exact C cases; backpressure, guards, busy, W1C and invalid/read-fault checks",cases);
        $finish;
    end
    initial begin #1000000000; $fatal(1,"global timeout"); end
endmodule
