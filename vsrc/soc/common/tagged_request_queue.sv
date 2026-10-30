// Module: tagged_request_queue
// Description: Two-entry registered tagged request and metadata queue with independent upstream readiness.
module tagged_request_queue #(
    parameter int META_WIDTH = 1
) (
    input logic clk, rst,
    input logic in_valid,
    output logic in_ready,
    input scoreboard_pkg::memory_request_t in_request,
    input logic [META_WIDTH-1:0] in_metadata,
    output logic out_valid,
    input logic out_ready,
    output scoreboard_pkg::memory_request_t out_request,
    output logic [META_WIDTH-1:0] out_metadata
);
    scoreboard_pkg::memory_request_t packet_q [2];
    logic [META_WIDTH-1:0] metadata_q [2];
    logic read_q, write_q;
    logic [1:0] count_q;
    logic push_fire, pop_fire;

    // 空队列没有组合穿透；上游 ready 只取决于寄存容量，切断下游解码/仲裁回路。
    // 深度二允许稳态占用一项时每拍同时进出；满时不借用当拍下游弹出的空槽。
    assign in_ready = !rst && count_q < 2;
    assign out_valid = !rst && count_q != 0;
    assign out_request = packet_q[read_q];
    assign out_metadata = metadata_q[read_q];
    assign push_fire = in_valid && in_ready;
    assign pop_fire = out_valid && out_ready;

    // 接收后归本队列持有，直到下游接受。取消读也必须外发并排空，由 LSQ 拒绝结果；
    // Store/MMIO 的队头授权在进入此队列之前完成，不能在这里撤回已接纳请求。
    always_ff @(posedge clk) begin
        if (rst) begin
            count_q <= 0; read_q <= 0; write_q <= 0;
        end else begin
            unique case ({push_fire, pop_fire})
                2'b10: count_q <= count_q + 2'd1;
                2'b01: count_q <= count_q - 2'd1;
                default: count_q <= count_q;
            endcase
            if (push_fire) begin
                packet_q[write_q] <= in_request;
                // 静态资格随请求同槽保存；只改载荷内容，不改变容量和进出握手。
                metadata_q[write_q] <= in_metadata;
                write_q <= !write_q;
            end
            if (pop_fire) read_q <= !read_q;
        end
    end
`ifndef SYNTHESIS
    always_ff @(posedge clk) if (!rst)
        assert (count_q <= 2) else $fatal(1, "tagged request queue overflow");
`endif
endmodule
