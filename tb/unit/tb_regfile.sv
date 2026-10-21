// Module: tb_regfile
// Description: Checks x0, synchronous writes, and explicit WB read-through.
module tb_regfile;
    timeunit 1ns;
    timeprecision 1ps;

    import core_types_pkg::*;

    logic clk = 1'b0;
    gpr_addr_t rs1_addr;
    gpr_addr_t rs2_addr;
    xlen_t rs1_data;
    xlen_t rs2_data;
    logic write_enable;
    gpr_addr_t write_addr;
    xlen_t write_data;

    always #5 clk = ~clk;
    regfile dut (
        .rs1_addr_1('0), .rs2_addr_1('0), .rs1_data_1(), .rs2_data_1(),
        .write_enable_1(1'b0), .write_addr_1('0), .write_data_1('0), .*
    );

    initial begin
        rs1_addr = 5'd5;
        rs2_addr = '0;
        write_enable = 1'b1;
        write_addr = 5'd5;
        write_data = xlen_t'(32'h1234_5678);
        #1;
        assert (rs1_data == write_data) else $fatal(1, "write-through");
        @(posedge clk);
        #1;
        write_enable = 1'b0;
        assert (rs1_data == xlen_t'(32'h1234_5678)) else $fatal(1, "stored write");
        write_enable = 1'b1;
        write_addr = '0;
        write_data = '1;
        #1;
        assert (rs2_data == '0) else $fatal(1, "x0 changed");
        $display("PASS tb_regfile");
        $finish;
    end
endmodule
