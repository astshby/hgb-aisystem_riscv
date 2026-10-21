// Module: wb_response_register
// Description: Registers formatted load data and memory completion errors before retirement.
module wb_response_register (
    input logic clk, rst,
    input logic memory_pending,
    input core_types_pkg::xlen_t address,
    input core_types_pkg::mem_size_e size,
    input logic unsigned_load,
    input logic rsp_valid,
    output logic rsp_ready,
    input core_types_pkg::xlen_t rsp_data,
    input logic rsp_error,
    input logic consume,
    output logic response_valid,
    output core_types_pkg::xlen_t load_data,
    output logic response_error
);
    core_types_pkg::xlen_t formatted_data;
    logic rsp_fire;

    // LSU 用已接受事务的地址/属性解释 BRAM/Cache 返回数据，字节选择和扩展位于寄存边界之前。
    // Store 也保存一次完成/错误状态；其 data 不参与架构写回。
    load_unit u_load_unit (
        .bus_data(rsp_data), .address, .size, .unsigned_load,
        .load_data(formatted_data)
    );

    // 只为 LSU 当前已接受的真实访存接收一次响应；满槽不旁路、不在消费同拍重装。
    assign rsp_ready = !rst && memory_pending && !response_valid;
    assign rsp_fire = rsp_valid && rsp_ready;

    // 槽位有效性归本模块所有；LSU 完成握手或协调取消时 consume 释放，不能假定完成即退休。
    // consume 优先于同沿响应，取消时即使数据沿被采样也不会留下有效结果。
    always_ff @(posedge clk) begin
        if (rst)
            response_valid <= 1'b0;
        else if (consume)
            response_valid <= 1'b0;
        else if (rsp_fire)
            response_valid <= 1'b1;
    end

    // 数据和错误同时锁存；外部撤销 valid 或改变返回总线不影响待交付结果。
    // 无效槽的载荷无需复位，response_valid 只授权 LSU 完成/前递；架构退休仍由队头决定。
    always_ff @(posedge clk) begin
        if (rsp_fire) begin
            load_data <= formatted_data;
            response_error <= rsp_error;
        end
    end
endmodule
