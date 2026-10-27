// Module: mm3_kv_cache
// Description: DDR-backed KV slot address/control stage. Data and scale copies use the common DMA buffers.
module mm3_kv_cache(
    input logic clk,rst,start,ready,
    input logic[31:0] pos,capacity,key_base,value_base,key_scale_base,value_scale_base,
    output logic valid,failed,
    output logic[31:0] key_address,value_address,key_scale_address,value_scale_address
);
    import mm3_config_pkg::*;
    logic[63:0] ka,va,ks,vs;
    always_comb begin
        ka=64'(key_base)+64'(pos)*MM3_KV_HEADS*MM3_HEAD_DIM*2;
        va=64'(value_base)+64'(pos)*MM3_KV_HEADS*MM3_HEAD_DIM*2;
        ks=64'(key_scale_base)+64'(pos)*MM3_KV_HEADS*8;
        vs=64'(value_scale_base)+64'(pos)*MM3_KV_HEADS*8;
    end
    always_ff @(posedge clk)begin
        if(rst)begin valid<=0;failed<=0;key_address<=0;value_address<=0;key_scale_address<=0;value_scale_address<=0;end
        else if(start&&!valid)begin
            valid<=1;failed<=capacity==0||capacity>MM3_SEQ_CAP||pos>=capacity|||(ka[63:32]|va[63:32]|ks[63:32]|vs[63:32]);
            key_address<=32'(ka);value_address<=32'(va);key_scale_address<=32'(ks);value_scale_address<=32'(vs);
        end else if(valid&&ready)valid<=0;
    end
endmodule
