// Module: tb_video_i2c
// Description: Wire-level TX-table ACK, NACK retries, readback failure, sticky outcomes and reset checks.
module tb_video_i2c;
    timeunit 1ns;
    timeprecision 1ps;
    logic clk = 0, rst = 1;
    always #8334ps clk = ~clk;
    logic sda_in, scl, sda_drive_low, reset_n, done, error;
    logic [7:0] retries, writes_done, nack_budget = 0;
    logic force_bad_read = 0, model_error;
    int writes_checked, reads_checked, repeated_starts;
    int checks = 0;
    realtime prefix_complete;
    logic previous_active = 0;
    int previous_writes = 0;
    ms7210_init #(.RESET_CYCLES(8),.SETTLE_CYCLES(120)) dut (.*);
    ms7210_i2c_model slave (
        .scl,.master_drive_low(sda_drive_low),.rst,.nack_budget,.force_bad_read,
        .sda_in,.writes_checked,.reads_checked,.repeated_starts,.model_error
    );
    // 下降沿观察已稳定的线级解码，避免同一delta中SCL/SDA换位的观察次序。
    always @(negedge clk) begin
        if (rst) begin
            previous_active = 0;
            previous_writes = 0;
            prefix_complete = 0;
        end else begin
            if (writes_checked == 19 && previous_writes != 19) prefix_complete = $realtime;
            if (slave.active_q && !previous_active && writes_checked == 19)
                assert ($realtime-prefix_complete >= 120*16668ps)
                    else $fatal(1,"missing reference settling interval after command18");
            previous_active = slave.active_q;
            previous_writes = writes_checked;
        end
    end
    task automatic begin_case(input logic [7:0] nacks,input bit bad_read);
        @(negedge clk);
        nack_budget = nacks;
        force_bad_read = bad_read;
        rst = 1;
        repeat (8) @(negedge clk);
        assert (!done && !error && !reset_n) else $fatal(1,"reset outputs");
        rst = 0;
    endtask
    task automatic wait_end(input bit expect_error);
        int cycles = 0;
        while (!done && !error && cycles < 500000) begin
            @(negedge clk);
            cycles++;
            assert (!model_error) else $fatal(1,"I2C slave protocol/table error writes=%0d reads=%0d",writes_checked,reads_checked);
        end
        assert (cycles < 500000 && error == expect_error && done != expect_error)
            else $fatal(1,"I2C termination expected_error=%b done=%b error=%b writes=%0d retries=%0d",expect_error,done,error,writes_done,retries);
        repeat (300) @(negedge clk);
        assert (error == expect_error && done != expect_error && scl && !sda_drive_low)
            else $fatal(1,"I2C sticky result/bus idle");
        checks++;
    endtask
    initial begin
        begin_case(0,0);
        wait_end(0);
        assert (writes_checked == 49 && writes_done == 49 && reads_checked == 1 && repeated_starts == 1 && retries == 0)
            else $fatal(1,"complete49 table/probe counts");
        begin_case(1,0);
        wait_end(0);
        assert (retries == 1 && writes_checked == 49 && reads_checked == 1)
            else $fatal(1,"NACK recovery");
        begin_case(3,0);
        wait_end(1);
        assert (retries == 3 && writes_done == 0 && writes_checked == 0)
            else $fatal(1,"three address failures");
        begin_case(0,1);
        wait_end(1);
        assert (retries == 3 && writes_done == 0 && reads_checked == 3 && repeated_starts == 3)
            else $fatal(1,"three readback failures");
        begin_case(0,0);
        repeat (10000) @(negedge clk);
        assert (!done && !error) else $fatal(1,"mid-transfer reset precondition");
        begin_case(0,0);
        wait_end(0);
        assert (writes_checked == 49 && writes_done == 49 && reads_checked == 1 && retries == 0)
            else $fatal(1,"reset/restart table");
        $display("PASS MS7210 I2C cases=%0d table_writes=49 probe_write_read=0003_5a repeated_start=1 nack_retry=1 three_fail_sticky=1 bad_read_sticky=1 reset=1",checks);
        $finish;
    end
    initial begin
        #50ms;
        $fatal(1,"MS7210 I2C timeout");
    end
endmodule
