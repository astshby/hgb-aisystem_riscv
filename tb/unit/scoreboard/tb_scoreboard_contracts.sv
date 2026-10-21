// Module: tb_scoreboard_contracts
// Description: Checks scheduling resources and circular age independently of encoded tag order.
module tb_scoreboard_contracts;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import scoreboard_pkg::*;

    d2_ex_t packet;
    retire_id_t candidate, boundary;
    logic expected;
    initial begin
        for (int first = 0; first < 5; first++) begin
            for (int second = 0; second < 5; second++) begin
                expected = first != 4 && second != 4 &&
                           !(first == 1 && second == 1) && !(first == 2 && second == 2);
                assert (resources_pair(schedule_class_e'(first), schedule_class_e'(second)) == expected)
                    else $fatal(1, "resource matrix first=%0d second=%0d", first, second);
            end
        end
        packet = '0;
        assert (schedule_class(packet) == SCHED_ALU) else $fatal;
        packet.uop.mem_read = 1;
        assert (schedule_class(packet) == SCHED_MEMORY) else $fatal;
        packet.exc.valid = 1;
        assert (schedule_class(packet) == SCHED_SERIAL) else $fatal;
        for (int head = 0; head < RETIRE_ENTRIES; head++) begin
            for (int age_a = 0; age_a < RETIRE_ENTRIES; age_a++) begin
                for (int age_b = 0; age_b < RETIRE_ENTRIES; age_b++) begin
                    candidate = '{slot:RETIRE_IDX_W'(head + age_a), generation:2'b00};
                    boundary = '{slot:RETIRE_IDX_W'(head + age_b), generation:2'b11};
                    assert (younger_than(candidate, boundary, RETIRE_IDX_W'(head)) == (age_a > age_b))
                        else $fatal(1, "circular age head=%0d a=%0d b=%0d", head, age_a, age_b);
                end
            end
        end
        $display("PASS tb_scoreboard_contracts XLEN=%0d ROB=%0d matrix=25 age=%0d",
                 XLEN, RETIRE_ENTRIES, RETIRE_ENTRIES**3);
        $finish;
    end
endmodule
