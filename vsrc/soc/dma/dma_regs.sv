// Module: dma_regs
// Description: Memory-mapped DMA command, progress, error and interrupt registers.
module dma_regs (
    input logic clk, rst,
    input logic req_valid,
    output logic req_ready,
    input bus_types_pkg::bus_req_t request,
    output logic rsp_valid,
    input logic rsp_ready,
    output bus_types_pkg::bus_rsp_t response,
    input logic engine_busy,
    input logic finish_valid, finish_error,
    input logic [2:0] finish_code,
    input logic [31:0] finish_bytes, finish_addr,
    output logic start_valid,
    output logic [31:0] start_src, start_dst, start_length,
    output logic irq
);
    logic [31:0] src_q, dst_q, length_q, bytes_q, fault_q;
    logic [2:0] code_q;
    logic irq_enable_q, done_q, error_q;
    logic [31:0] read_data, write_data, write_mask;
    logic access_error, access_fire;
    logic [11:0] offset;
    assign offset = request.addr[11:0];
    assign start_src = src_q;
    assign start_dst = dst_q;
    assign start_length = length_q;
    assign irq = irq_enable_q && (done_q || error_q);
    assign start_valid = access_fire && request.write && offset == 12'h00c &&
                         write_mask[0] && write_data[0];

    mmio_endpoint u_mmio (
        .clk, .rst, .req_valid, .req_ready, .request,
        .rsp_valid, .rsp_ready, .response, .read_data,
        .access_error, .access_fire, .write_data, .write_mask
    );

    // 控制寄存器 busy 时只读；STATUS 的 DONE/ERROR 写 1 清除，中断来自保留状态。
    always_comb begin
        read_data = '0;
        access_error = 1'b0;
        case (offset)
            12'h000: read_data = src_q;
            12'h004: read_data = dst_q;
            12'h008: read_data = length_q;
            12'h00c: read_data = {30'b0, irq_enable_q, 1'b0};
            12'h010: read_data = {29'b0, error_q, done_q, engine_busy};
            12'h014: read_data = bytes_q;
            12'h018: read_data = fault_q;
            12'h01c: read_data = {29'b0, code_q};
            default: access_error = 1'b1;
        endcase
        if (request.write && ((offset <= 12'h00c && engine_busy) ||
                              offset == 12'h014 || offset == 12'h018 || offset == 12'h01c))
            access_error = 1'b1;
    end

    // 请求沿只锁存命令与配置；最终写响应到达后才记录完成，完成优先于同拍 W1C。
    always_ff @(posedge clk) begin
        if (rst) begin
            src_q <= '0;
            dst_q <= '0;
            length_q <= '0;
            bytes_q <= '0;
            fault_q <= '0;
            code_q <= '0;
            irq_enable_q <= 1'b0;
            done_q <= 1'b0;
            error_q <= 1'b0;
        end else begin
            if (access_fire && request.write) begin
                case (offset)
                    12'h000: src_q <= (src_q & ~write_mask) | (write_data & write_mask);
                    12'h004: dst_q <= (dst_q & ~write_mask) | (write_data & write_mask);
                    12'h008: length_q <= (length_q & ~write_mask) | (write_data & write_mask);
                    12'h00c: if (write_mask[0]) irq_enable_q <= write_data[1];
                    12'h010: begin
                        if (write_mask[0] && write_data[1]) done_q <= 1'b0;
                        if (write_mask[0] && write_data[2]) error_q <= 1'b0;
                    end
                    default: ;
                endcase
            end
            if (start_valid) begin
                bytes_q <= '0;
                fault_q <= '0;
                code_q <= '0;
                done_q <= 1'b0;
                error_q <= 1'b0;
            end
            if (finish_valid) begin
                bytes_q <= finish_bytes;
                fault_q <= finish_addr;
                code_q <= finish_code;
                done_q <= !finish_error;
                error_q <= finish_error;
            end
        end
    end
endmodule
