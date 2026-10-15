// Module: tb_uart_loader
// Description: Downloads a DDR executable through actual SoC UART pins, including rejected header/retry.
module tb_uart_loader;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    localparam int DIVISOR = 100; // 50 MHz / 500 kbaud, simulation firmware only.
    tb_soc_benchmark #(.DDR_BYTES(256 * 1024)) test();
    logic host_rx = 1'b1;
    byte unsigned received[$];
    byte unsigned wire_bytes[262144];
    string wire_path;
    integer wire_count;
    integer replies = 0;
    integer copied_bytes = 0, hot_commits = 0, hot_bytes;
    bit rt_image;

    function automatic int unsigned wire_word(input int index);
        return {wire_bytes[index+3],wire_bytes[index+2],wire_bytes[index+1],wire_bytes[index]};
    endfunction
    always @(posedge test.clk) if (!test.rst && rt_image) begin
        if (test.dut.m_req_valid[2] && test.dut.m_req_ready[2]) begin
            if (test.dut.m_request[2].write) begin
                assert (test.dut.m_request[2].addr==XLEN'('h0100e000+copied_bytes))
                    else $fatal(1,"bad DMA hot destination");
                copied_bytes+=$countones(test.dut.m_request[2].wstrb);
            end else
                assert (test.dut.m_request[2].addr>=XLEN'('h0110c000) &&
                        test.dut.m_request[2].addr<XLEN'('h0110c000+hot_bytes))
                    else $fatal(1,"bad DMA hot source");
        end
        if (test.commit_valid && test.commit_pc>=XLEN'('h0100e000) && test.commit_pc<XLEN'('h01010000)) begin
            assert (copied_bytes==hot_bytes && test.fence_commits>=2)
                else $fatal(1,"hot code before complete DMA/FENCE.I");
            hot_commits++;
        end
    end

    initial force test.uart_rx = {1'b1, host_rx};

    initial forever begin
        byte unsigned value;
        @(negedge test.uart_tx[0]);
        repeat (DIVISOR/2) @(negedge test.clk);
        assert (!test.uart_tx[0]) else $fatal(1, "bad UART start");
        for (int bit_index=0; bit_index<8; bit_index++) begin
            repeat (DIVISOR) @(negedge test.clk);
            value[bit_index]=test.uart_tx[0];
        end
        repeat (DIVISOR) @(negedge test.clk);
        assert (test.uart_tx[0]) else $fatal(1, "bad UART stop");
        received.push_back(value);
    end

    task automatic recv_byte(output byte unsigned value);
        while (received.size()==0) @(negedge test.clk);
        value=received.pop_front();
    endtask
    task automatic ready_banner;
        byte unsigned value;
        string line;
        line="";
        do begin
            recv_byte(value);
            line={line,value};
        end while (value!=10);
        assert (line=="LOADER READY v1 m0d1\n") else $fatal(1,"unexpected loader banner: %s",line);
    endtask
    task automatic send_byte(input byte unsigned value, input bit stop_ok=1'b1);
        @(negedge test.clk);
        host_rx=0;
        repeat (DIVISOR) @(negedge test.clk);
        for (int bit_index=0; bit_index<8; bit_index++) begin
            host_rx=value[bit_index];
            repeat (DIVISOR) @(negedge test.clk);
        end
        host_rx=stop_ok;
        repeat (DIVISOR) @(negedge test.clk);
        host_rx=1;
        repeat (DIVISOR) @(negedge test.clk);
    endtask
    task automatic ack(input byte unsigned expected);
        byte unsigned value;
        recv_byte(value);
        assert (value==expected) else $fatal(1,"UART ack expected=%h got=%h",expected,value);
        replies++;
    endtask
    initial begin
        int unsigned count, offset, size, block_size;
        int crc_passes, runs, saved_hot;
        byte unsigned value;
        string line;
        rt_image=$test$plusargs("RT_IMAGE");
        if (rt_image && (!$value$plusargs("HOT_BYTES=%d",hot_bytes) || hot_bytes<=0))
            $fatal(1,"missing hot image length");
        if (!$value$plusargs("WIRE=%s",wire_path) || !$value$plusargs("WIRE_BYTES=%d",wire_count))
            $fatal(1,"missing packet");
        assert (wire_count>28 && wire_count<=262144) else $fatal(1,"bad wire size");
        $readmemh(wire_path,wire_bytes,0,wire_count-1);
        ready_banner();
        // 错误 header 必须回 NAK、保留在 loader，并接受下一次完整事务。
        for (int i=0; i<28; i++) send_byte(wire_bytes[i] ^ (i==0 ? 8'h01 : 8'h00));
        ack(8'h15);
        ack(8'h02);
        ready_banner();
        send_byte(8'h00,1'b0);
        ack(8'h15);
        ack(8'h09);
        ready_banner();
        count=wire_word(16);
        offset=28+16*count;
        for (int i=0; i<offset; i++) send_byte(wire_bytes[i]);
        ack(8'h06);
        for (int segment=0; segment<count; segment++) begin
            size=wire_word(28+16*segment+4);
            while (size) begin
                block_size=size>128 ? 128 : size;
                for (int i=0; i<block_size+4; i++) send_byte(wire_bytes[offset+i]);
                offset+=block_size+4;
                size-=block_size;
                ack(8'h06);
            end
            $display("UART downloaded segment %0d/%0d bytes=%0d",segment+1,count,offset);
            $fflush();
        end
        assert (offset==wire_count) else $fatal(1,"packet trailing bytes");
        ack(8'h07);
        if (rt_image) begin
            crc_passes=0;
            runs=0;
            while (runs<2) begin
                line="";
                do begin recv_byte(value); line={line,value}; end while (value!=10);
                if (line=="PASS rt-thread CoreMark DDR functional CRC (short run)\n") crc_passes++;
                if (line=="COREMARK READY run=1 r=repeat\n") begin
                    assert (crc_passes==1 && runs==0) else $fatal(1,"first run CRC missing");
                    runs=1;
                    send_byte(8'h72);
                end
                if (line=="COREMARK READY run=2 r=repeat\n") begin
                    assert (crc_passes==2 && runs==1) else $fatal(1,"repeat CRC missing");
                    runs=2;
                end
            end
            saved_hot=hot_commits;
            repeat (200000) @(negedge test.clk);
            assert (!test.test_done && hot_commits>saved_hot && test.ddr_fetches>100 && copied_bytes==hot_bytes)
                else $fatal(1,"resident RT-Thread/DMA/DDR coverage missing");
            $display("PASS UART RT-Thread CoreMark RV%0d runs=2 DMA=%0d DDR_fetches=%0d hot=%0d",XLEN,copied_bytes,test.ddr_fetches,hot_commits);
            $finish;
        end
    end
    final if (test.test_pass && !rt_image) begin
        assert (replies==8 && test.ddr_fetches>0 && test.fence_commits>0)
            else $fatal(1,"missing protocol or DDR execution coverage");
        $display("PASS UART loader RV%0d digital RX/TX + reject/retry + DDR publish/readback + jump",XLEN);
    end
endmodule
