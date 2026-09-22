// Module: tb_muldiv_unit
// Description: Checks the unified MDU and alternating multiply/divide response routing.
module tb_muldiv_unit;
    timeunit 1ns;
    timeprecision 1ps;
    muldiv_checker #(.MODE(0), .TEST_NAME("tb_muldiv_unit")) checker_instance ();
endmodule
