// Module: tb_uart_loader
// Description: Downloads a DDR executable through actual SoC UART pins, including rejected header/retry.
module tb_uart_loader #(
    parameter bit LOCAL_TCM_ENABLE = 1'b0,
    parameter int unsigned SOC_PROFILE = soc_config_pkg::SOC_PROFILE_FULL
);
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    localparam int DIVISOR = 100; // 50 MHz / 500 kbaud, simulation firmware only.
    tb_soc_system #(.DDR_BYTES(256 * 1024), .PERIPH_PERIOD_PS(20000),
                       .UART_DIVISOR(DIVISOR), .LOCAL_TCM_ENABLE(LOCAL_TCM_ENABLE),
                       .SOC_PROFILE(SOC_PROFILE)) test();
    logic host_rx = 1'b1;
    byte unsigned received[$];
    byte unsigned wire_bytes[262144];
    string wire_path;
    integer wire_count;
    integer replies = 0;

    function automatic int unsigned wire_word(input int index);
        return {wire_bytes[index+3],wire_bytes[index+2],wire_bytes[index+1],wire_bytes[index]};
    endfunction
    initial force test.uart_rx = {1'b1, host_rx};

    initial forever begin
        byte unsigned value;
        @(negedge test.uart_tx[0]);
        repeat (DIVISOR/2) @(negedge test.clk_periph);
        assert (!test.uart_tx[0]) else $fatal(1, "bad UART start");
        for (int bit_index=0; bit_index<8; bit_index++) begin
            repeat (DIVISOR) @(negedge test.clk_periph);
            value[bit_index]=test.uart_tx[0];
        end
        repeat (DIVISOR) @(negedge test.clk_periph);
        assert (test.uart_tx[0]) else $fatal(1, "bad UART stop");
        received.push_back(value);
    end

    task automatic recv_byte(output byte unsigned value);
        while (received.size()==0) @(negedge test.clk_periph);
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
        @(negedge test.clk_periph);
        host_rx=0;
        repeat (DIVISOR) @(negedge test.clk_periph);
        for (int bit_index=0; bit_index<8; bit_index++) begin
            host_rx=value[bit_index];
            repeat (DIVISOR) @(negedge test.clk_periph);
        end
        host_rx=stop_ok;
        repeat (DIVISOR) @(negedge test.clk_periph);
        host_rx=1;
        repeat (DIVISOR) @(negedge test.clk_periph);
    endtask
    task automatic ack(input byte unsigned expected);
        byte unsigned value;
        recv_byte(value);
        assert (value==expected) else $fatal(1,"UART ack expected=%h got=%h",expected,value);
        replies++;
    endtask
    initial begin
        int unsigned count, offset, size, block_size;
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
    end
    final if (test.test_pass) begin
        assert (replies==8 && test.ddr_fetches>0 && test.fence_commits>0)
            else $fatal(1,"missing protocol or DDR execution coverage");
        $display("PASS UART loader RV%0d digital RX/TX + reject/retry + DDR publish/readback + jump",XLEN);
    end
endmodule
