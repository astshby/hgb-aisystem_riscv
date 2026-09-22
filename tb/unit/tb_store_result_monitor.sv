// Module: tb_store_result_monitor
// Description: Verifies passive address, strobe, PASS, and FAIL Store decoding.
module tb_store_result_monitor;
    timeunit 1ns;
    timeprecision 1ps;

    import core_config_pkg::*;
    import core_types_pkg::*;

    logic clk = 1'b0;
    logic rst = 1'b1;
    xlen_t result_addr;
    logic dmem_store_fire;
    xlen_t dmem_store_addr;
    xlen_t dmem_store_data;
    logic [DBUS_BYTES-1:0] dmem_store_strb;
    logic test_done;
    logic test_pass;
    logic [31:0] test_code;

    always #5 clk = ~clk;
    store_result_monitor dut (.*);

    task automatic send_store(
        input xlen_t address,
        input xlen_t data,
        input logic [DBUS_BYTES-1:0] strb
    );
        @(negedge clk);
        dmem_store_fire = 1'b1;
        dmem_store_addr = address;
        dmem_store_data = data;
        dmem_store_strb = strb;
        @(negedge clk);
        dmem_store_fire = 1'b0;
    endtask

    initial begin
        result_addr = xlen_t'(32'h1000);
        dmem_store_fire = 1'b0;
        dmem_store_addr = '0;
        dmem_store_data = '0;
        dmem_store_strb = '0;

        repeat (2) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        send_store(xlen_t'(32'h1004), xlen_t'(1), '1);
        assert (!test_done) else $fatal(1, "wrong address terminated test");
        send_store(result_addr, xlen_t'(1), {{(DBUS_BYTES-1){1'b0}}, 1'b1});
        assert (!test_done) else $fatal(1, "partial Store terminated test");
        send_store(result_addr, xlen_t'(1), '1);
        assert (test_done && test_pass && test_code == 1)
            else $fatal(1, "PASS code was not captured");

        rst = 1'b1;
        @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        send_store(result_addr, xlen_t'(7), '1);
        assert (test_done && !test_pass && test_code == 7)
            else $fatal(1, "FAIL code was not captured");

        $display("PASS tb_store_result_monitor RV%0d", XLEN);
        $finish;
    end
endmodule
