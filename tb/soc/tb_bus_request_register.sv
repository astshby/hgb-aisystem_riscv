// Module: tb_bus_request_register
// Description: Checks DDR request registration, full-slot backpressure, payload ownership, and reset.
module tb_bus_request_register;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import bus_types_pkg::*;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic in_req_valid = 1'b0;
    logic in_req_ready;
    bus_req_t in_request = '0;
    logic out_req_valid;
    logic out_req_ready = 1'b0;
    bus_req_t out_request;
    bus_req_t request_a, request_b, request_c;

    always #5 clk = ~clk;

    bus_request_register dut (.*);

    initial begin
        request_a = '{write:1'b0, execute:1'b1, size:MEM_WORD,
                      addr:xlen_t'(32'h80000104), wdata:'0, wstrb:'0};
        request_b = '{write:1'b1, execute:1'b0, size:MEM_BYTE,
                      addr:xlen_t'(32'h80000207), wdata:xlen_t'(32'hdeadbeef),
                      wstrb:DBUS_BYTES'(1 << (DBUS_BYTES-1))};
        request_c = '{write:1'b0, execute:1'b0, size:MEM_HALF,
                      addr:xlen_t'(32'h80000300), wdata:'0, wstrb:'0};

        repeat (2) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        in_req_valid = 1'b1;
        in_request = request_a;
        out_req_ready = 1'b1;
        #1;
        assert (in_req_ready && !out_req_valid)
            else $fatal(1, "request bypassed its register");
        @(posedge clk);
        #1;
        assert (out_req_valid && out_request == request_a && !in_req_ready)
            else $fatal(1, "first request was not registered");

        // 满槽时后继写请求不能覆盖已接受的取指请求。
        @(negedge clk);
        in_request = request_b;
        out_req_ready = 1'b0;
        repeat (3) begin
            @(posedge clk);
            #1;
            assert (out_req_valid && out_request == request_a && !in_req_ready)
                else $fatal(1, "held request changed under backpressure");
        end
        @(negedge clk);
        out_req_ready = 1'b1;
        #1;
        assert (out_req_valid && !in_req_ready && out_request == request_a)
            else $fatal(1, "downstream ready reached upstream ready combinationally");
        @(posedge clk);
        #1;
        assert (!out_req_valid && in_req_ready)
            else $fatal(1, "full slot used a combinational refill bypass");
        @(posedge clk);
        #1;
        assert (out_req_valid && out_request == request_b && !in_req_ready)
            else $fatal(1, "second request lost its address or write payload");

        // 复位时撤销未发出的请求，不能在复位后重放旧写操作。
        @(negedge clk);
        in_req_valid = 1'b0;
        out_req_ready = 1'b0;
        rst = 1'b1;
        #1;
        assert (!out_req_valid && !in_req_ready)
            else $fatal(1, "reset did not gate request handshakes");
        @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        in_req_valid = 1'b1;
        in_request = request_c;
        #1;
        assert (!out_req_valid && in_req_ready)
            else $fatal(1, "stale request survived reset");
        @(posedge clk);
        #1;
        assert (out_req_valid && out_request == request_c)
            else $fatal(1, "request after reset was corrupted");
        $display("PASS tb_bus_request_register RV%0d", XLEN);
        $finish;
    end
endmodule
