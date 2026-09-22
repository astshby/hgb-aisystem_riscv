// Module: tb_div_unit
// Description: Checks iterative division independently of the EX pipeline.
module tb_div_unit;
    timeunit 1ns;
    timeprecision 1ps;
    muldiv_checker #(.MODE(2), .TEST_NAME("tb_div_unit")) checker_instance ();
endmodule
