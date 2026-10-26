// Package: mm3_fixed_pkg
// Description: Integer dyadic representation and exact C-compatible normalization/rounding.
package mm3_fixed_pkg;
    typedef struct packed {
        logic signed [63:0] v;
        logic signed [31:0] e;
    } fixed_t;
    function automatic logic [63:0] magnitude(input logic signed [63:0] v);
        return v < 0 ? (~$unsigned(v) + 64'd1) : $unsigned(v);
    endfunction
    function automatic int unsigned bits128(input logic [127:0] v);
        int unsigned n;
        n = 0;
        for (int i = 0; i < 128; i++) if (v[i]) n = i+1;
        return n;
    endfunction
    function automatic logic [63:0] round128(input logic [127:0] v, input int unsigned s);
        logic [63:0] q;
        logic guard_bit, sticky;
        q = s >= 128 ? 0 : 64'(v >> s);
        guard_bit = 0;
        sticky = 0;
        for (int i = 0; i < 128; i++) begin
            if (s != 0 && i == s-1) guard_bit = v[i];
            if (s > 1 && i < s-1) sticky |= v[i];
        end
        return q + 64'(guard_bit && (sticky || q[0]));
    endfunction
    function automatic fixed_t make_fixed(input logic signed [63:0] v, input logic signed [31:0] e);
        fixed_t r;
        logic [63:0] a;
        int unsigned b;
        r = '0;
        a = magnitude(v);
        b = bits128({64'b0,a});
        if (b != 0) begin
            r.e = e;
            if (b > 61) begin
                a = round128({64'b0,a}, b-61);
                r.e += 32'(b-61);
                if (a == (64'd1 << 61)) begin a >>= 1; r.e++; end
            end else begin a <<= 61-b; r.e -= 32'(61-b); end
            r.v = v < 0 ? -$signed(a) : $signed(a);
        end
        return r;
    endfunction
    function automatic fixed_t scale_fixed(input logic [31:0] m, input logic signed [31:0] e);
        return make_fixed($signed({32'b0,m}), e-32'sd31);
    endfunction
    function automatic logic abs_greater(input fixed_t a, input fixed_t b);
        return a.v != 0 && (b.v == 0 || a.e > b.e || (a.e == b.e && magnitude(a.v) > magnitude(b.v)));
    endfunction
    function automatic logic [63:0] integer_mag(input fixed_t a, input logic bits32);
        logic [63:0] lim, v;
        lim = bits32 ? 64'h7fffffff : 64'h7fff;
        v = magnitude(a.v);
        if (a.e >= 0) begin
            if (a.e >= 63 || v > (lim >> a.e)) return lim;
            return v << a.e;
        end
        v = round128({64'b0,v}, 32'(-a.e));
        return v > lim ? lim : v;
    endfunction
    function automatic logic quant_saturated(input fixed_t a, input logic bits32);
        logic [63:0] lim, v;
        lim = bits32 ? 64'h7fffffff : 64'h7fff;
        v = magnitude(a.v);
        if (a.e >= 0) return a.e >= 63 ? v != 0 : v > (lim >> a.e);
        return round128({64'b0,v}, 32'(-a.e)) > lim;
    endfunction
    function automatic fixed_t add_fixed(input fixed_t a,b);
        logic signed [31:0] e;
        logic [63:0] av,bv;
        if(a.v==0)return b;
        if(b.v==0)return a;
        e=a.e>b.e?a.e:b.e;
        av=round128({64'b0,magnitude(a.v)},32'(e-a.e));
        bv=round128({64'b0,magnitude(b.v)},32'(e-b.e));
        return make_fixed((a.v<0?-$signed(av):$signed(av))+(b.v<0?-$signed(bv):$signed(bv)),e);
    endfunction
    function automatic logic signed [31:0] integer32(input fixed_t a);
        logic [63:0] v;
        v=integer_mag(a,1);
        return a.v<0?-$signed(32'(v)):$signed(32'(v));
    endfunction
endpackage
