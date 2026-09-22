// Module: wallace_tree
// Description: Elaborated 3:2 carry-save reduction tree ending in two unsigned rows.
// wallace_tree 级联压缩部分积行:递归实现，这个行是由硬件elaborate决定的，所以要用generate
module wallace_tree #(
    parameter int WIDTH = 64,
    parameter int ROWS = 17
) (
    input logic [WIDTH-1:0] rows [ROWS],
    output logic [WIDTH-1:0] sum,
    output logic [WIDTH-1:0] carry
);
    generate
        if (ROWS <= 2) begin : g_last
            assign sum = rows[0];
            if (ROWS == 2) assign carry = rows[1];
            else assign carry = '0;
        end else begin : g_reduce
            localparam int GROUPS = ROWS / 3;
            localparam int NEXT_ROWS = GROUPS * 2 + ROWS % 3;
            wire [WIDTH-1:0] reduced [NEXT_ROWS];
            // 每三个同位权行压成 sum/carry 两行；级内不做宽进位传播。
            for (genvar i = 0; i < GROUPS; i++) begin : g_csa
                assign reduced[2*i] = rows[3*i] ^ rows[3*i+1] ^ rows[3*i+2];
                assign reduced[2*i+1] = ((rows[3*i] & rows[3*i+1]) |
                    (rows[3*i] & rows[3*i+2]) | (rows[3*i+1] & rows[3*i+2])) << 1;
            end
            for (genvar i = 0; i < ROWS % 3; i++) begin : g_tail
                assign reduced[2*GROUPS+i] = rows[3*GROUPS+i];
            end
            wallace_tree #(.WIDTH(WIDTH), .ROWS(NEXT_ROWS)) u_next (
                .rows(reduced), .sum, .carry
            );
        end
    endgenerate
endmodule
