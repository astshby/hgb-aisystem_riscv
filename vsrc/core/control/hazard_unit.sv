// Module: hazard_unit
// Description: Detects the single-cycle EX-to-D2 load-use hazard.
module hazard_unit (
    // d1_d2表示当前d2，d2_ex表示当前ex，主要处理load-use(生产者-消费者模型)
    input  pipeline_pkg::d2_ex_t producer,
    input  pipeline_pkg::d1_d2_t consumer,
    output logic                  load_use_stall
);
    logic producer_is_load;
    logic rs1_hazard;
    logic rs2_hazard;

    // load 数据下一周期才在 WB 可用，紧随其后的消费者需要停顿一拍。
    always_comb begin
        producer_is_load = producer.valid && producer.uop.mem_read &&
                           producer.uop.gpr_write && (producer.rd != '0) &&
                           !producer.exc.valid;
        rs1_hazard = consumer.uop.rs1_used && (consumer.rs1 == producer.rd);
        rs2_hazard = consumer.uop.rs2_used && (consumer.rs2 == producer.rd);
        load_use_stall = producer_is_load && consumer.valid &&
                         (rs1_hazard || rs2_hazard);
    end
endmodule
