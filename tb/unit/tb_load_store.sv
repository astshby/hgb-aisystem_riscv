// Module: tb_load_store
// Description: Checks RV32 byte lanes, write strobes, and load extension.
module tb_load_store;
    timeunit 1ns;
    timeprecision 1ps;

    import core_config_pkg::*;
    import core_types_pkg::*;

    xlen_t bus_data;
    xlen_t address;
    mem_size_e size;
    logic unsigned_load;
    xlen_t load_data;
    xlen_t store_data;
    xlen_t bus_wdata;
    logic [DBUS_BYTES-1:0] bus_wstrb;

    load_unit u_load (.*);
    store_unit u_store (.*);

    initial begin
        bus_data = xlen_t'(32'h80ff_7f01);
        address = xlen_t'(2);
        size = MEM_BYTE;
        unsigned_load = 1'b0;
        store_data = xlen_t'(32'h1234);
        #1;
        assert (load_data == xlen_t'(-1)) else $fatal(1, "signed byte");
        unsigned_load = 1'b1; #1;
        assert (load_data == xlen_t'(255)) else $fatal(1, "unsigned byte");
        address = xlen_t'(2);
        size = MEM_HALF; #1;
        assert (bus_wstrb == (DBUS_BYTES'(3) << 2)) else $fatal(1, "half strobe");
        assert (bus_wdata[31:16] == 16'h1234) else $fatal(1, "half data");
        if (XLEN == 64) begin
            bus_data = 64'h0123_4567_8000_0001;
            address = '0;
            size = MEM_WORD;
            unsigned_load = 1'b0; #1;
            assert (load_data == 64'hffff_ffff_8000_0001) else $fatal(1, "LW sign extension");
            unsigned_load = 1'b1; #1;
            assert (load_data == 64'h0000_0000_8000_0001) else $fatal(1, "LWU zero extension");
            size = MEM_DWORD;
            store_data = 64'hfedc_ba98_7654_3210; #1;
            assert (bus_wstrb == 8'hff && bus_wdata == store_data) else $fatal(1, "SD lanes");
        end
        $display("PASS tb_load_store RV%0d", XLEN);
        $finish;
    end
endmodule
