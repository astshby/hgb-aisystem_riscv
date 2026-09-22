// Module: tb_mul_unit
// Description: Checks registered multiplication independently of the EX pipeline.
module tb_mul_unit;
    timeunit 1ns;
    timeprecision 1ps;
    muldiv_checker #(.MODE(1), .TEST_NAME("tb_mul_unit")) checker_instance ();
endmodule
