// Module: fetch_width_adapter
// Description: Preserves one fetch owner while adapting 32/64-bit fetch responses to a 32-bit memory port.
module fetch_width_adapter #(
    parameter int unsigned DATA_W = core_config_pkg::FETCH_DATA_W
) (
    input logic clk, rst,
    input logic s_req_valid,
    output logic s_req_ready,
    input core_types_pkg::xlen_t s_req_addr,
    output logic s_rsp_valid,
    input logic s_rsp_ready,
    output logic [DATA_W-1:0] s_rsp_data,
    output logic s_rsp_error, s_rsp_error_1,
    output logic m_req_valid,
    input logic m_req_ready,
    output core_types_pkg::xlen_t m_req_addr,
    input logic m_rsp_valid,
    output logic m_rsp_ready,
    input logic [31:0] m_rsp_data,
    input logic m_rsp_error
);
    import core_types_pkg::*;

    if (DATA_W == 32) begin
        // 单发射保持原来的直通时序，不为兼容双字取指增加请求或响应寄存拍。
        assign m_req_valid = s_req_valid;
        assign s_req_ready = m_req_ready;
        assign m_req_addr = s_req_addr;
        assign s_rsp_valid = m_rsp_valid;
        assign m_rsp_ready = s_rsp_ready;
        assign s_rsp_data = m_rsp_data;
        assign s_rsp_error = m_rsp_error;
        assign s_rsp_error_1 = 1'b0;
    end else begin
        typedef enum logic [2:0] {IDLE, SEND_LOW, WAIT_LOW, SEND_HIGH, WAIT_HIGH, REPLY} state_e;
        state_e state_q;
        xlen_t address_q;
        logic [63:0] data_q;
        logic [1:0] error_q;
        logic s_req_fire, s_rsp_fire, m_req_fire, m_rsp_fire;

        // Core 提供8字节对齐的双字地址；Cache/TCM仍逐条32-bit取指，本槽保存整批归属。
        assign s_req_ready = !rst && state_q == IDLE;
        assign s_rsp_valid = !rst && state_q == REPLY;
        assign s_rsp_data = data_q;
        assign s_rsp_error = error_q[0];
        assign s_rsp_error_1 = error_q[1];
        assign m_req_valid = !rst && (state_q == SEND_LOW || state_q == SEND_HIGH);
        assign m_req_addr = address_q + ((state_q == SEND_HIGH || state_q == WAIT_HIGH) ? xlen_t'(4) : '0);
        assign m_rsp_ready = !rst && (state_q == WAIT_LOW || state_q == WAIT_HIGH);
        assign s_req_fire = s_req_valid && s_req_ready;
        assign s_rsp_fire = s_rsp_valid && s_rsp_ready;
        assign m_req_fire = m_req_valid && m_req_ready;
        assign m_rsp_fire = m_rsp_valid && m_rsp_ready;

        // 每个字保留独立错误。高字失败不能使低字成为取指异常，Core 按实际消费 lane 处理。
        // 接受后的取指不可取消；重定向由 Core 丢弃旧完整响应，复位须与下层协调。
        always_ff @(posedge clk) begin
            if (rst) begin
                state_q <= IDLE;
                address_q <= '0;
                data_q <= '0;
                error_q <= '0;
            end else begin
                unique case (state_q)
                    IDLE: if (s_req_fire) begin
                        address_q <= s_req_addr;
                        data_q <= '0;
                        error_q <= '0;
                        state_q <= SEND_LOW;
                    end
                    SEND_LOW: if (m_req_fire) state_q <= WAIT_LOW;
                    WAIT_LOW: if (m_rsp_fire) begin
                        data_q[31:0] <= m_rsp_data;
                        error_q[0] <= m_rsp_error;
                        state_q <= SEND_HIGH;
                    end
                    SEND_HIGH: if (m_req_fire) state_q <= WAIT_HIGH;
                    WAIT_HIGH: if (m_rsp_fire) begin
                        data_q[63:32] <= m_rsp_data;
                        error_q[1] <= m_rsp_error;
                        state_q <= REPLY;
                    end
                    REPLY: if (s_rsp_fire) state_q <= IDLE;
                    default: state_q <= IDLE;
                endcase
            end
        end
    end

`ifndef SYNTHESIS
    initial assert (DATA_W == 32 || DATA_W == 64)
        else $fatal(1, "fetch_width_adapter requires 32/64-bit fetch data");
`endif
endmodule
