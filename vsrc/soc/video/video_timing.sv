// Module: video_timing
// Description: Fixed 1920x1080p60 positive-sync raster, based on the same-board 4_6_hdmi_dyn_ppll timing table.
module video_timing (
    input logic clk, rst,
    output logic hs, vs, de, frame_start,
    output logic [11:0] x,
    output logic [10:0] y
);
    logic [11:0] h_q;
    logic [10:0] v_q;
    assign hs=h_q<44;
    assign vs=v_q<5;
    assign de=h_q>=192 && h_q<2112 && v_q>=41 && v_q<1121;
    assign x=h_q-12'd192;
    assign y=v_q-11'd41;
    assign frame_start=h_q==0 && v_q==0;
    always_ff @(posedge clk) begin
        if (rst) begin h_q<=0; v_q<=0; end
        else if (h_q==2199) begin
            h_q<=0; v_q<=v_q==1124 ? 0 : v_q+1'b1;
        end else h_q<=h_q+1'b1;
    end
endmodule
