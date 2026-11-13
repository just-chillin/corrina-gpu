// FXG-1 GPU core.
//
// A job is described entirely by registers (BAR0). Every buffer the job
// touches (shader programs, uniforms, vertices, texture, colour target,
// depth target) lives in host memory and is reached by bus-master DMA, the
// way a discrete GPU without its own VRAM allocator would behave behind an
// IOMMU. One job = clear + one triangle list. START kicks it; an interrupt
// reports completion.
//
// Pipeline, all sequenced by one FSM around one shared shader core:
//   load programs/uniforms -> clear -> per triangle:
//     3 x (fetch attributes -> vertex shader -> 1/w -> viewport)
//     -> cull / setup edge functions -> per covered pixel:
//        barycentrics -> depth test -> perspective divide
//        -> fragment shader -> colour write -> depth write
//
// Numbers: Q16.16 in shaders, 28.4 sub-pixel screen coordinates, 24-bit
// depth, 1/w carried as Q8.24.
//
// Bus interfaces are deliberately plain so they can be wrapped:
//   s_*  register slave  (single-cycle; wrap with AXI4-Lite for a PCIe IP)
//   m_*  memory master   (valid/ready, 32-bit data; wrap with AXI4 master)
`default_nettype none
module fxg_gpu (
    input  wire        clk,
    input  wire        rst,
    input  wire        s_valid,
    input  wire        s_we,
    input  wire [7:0]  s_addr,
    input  wire [31:0] s_wdata,
    output reg  [31:0] s_rdata,
    output reg         m_valid,
    output reg         m_we,
    output reg  [63:0] m_addr,
    output reg  [31:0] m_wdata,
    input  wire        m_ready,
    input  wire [31:0] m_rdata,
    output wire        irq
);
    localparam [31:0] FXG_ID = 32'h46584731;   // "FXG1"

    // ------------------------------------------------------------------
    // Register file (word index = offset / 4)
    // ------------------------------------------------------------------
    localparam [4:0]
        R_ID = 5'd0, R_CTRL = 5'd1, R_STATUS = 5'd2, R_IRQ_STATUS = 5'd3,
        R_IRQ_ENABLE = 5'd4, R_RT_LO = 5'd5, R_RT_HI = 5'd6, R_Z_LO = 5'd7,
        R_Z_HI = 5'd8, R_RT_DIM = 5'd9, R_VTX_LO = 5'd10, R_VTX_HI = 5'd11,
        R_VTX_COUNT = 5'd12, R_VTX_STRIDE = 5'd13, R_VS_LO = 5'd14,
        R_VS_HI = 5'd15, R_VS_LEN = 5'd16, R_FS_LO = 5'd17, R_FS_HI = 5'd18,
        R_FS_LEN = 5'd19, R_TEX_LO = 5'd20, R_TEX_HI = 5'd21, R_TEX_DIM = 5'd22,
        R_UNI_LO = 5'd23, R_UNI_HI = 5'd24, R_UNI_COUNT = 5'd25, R_FLAGS = 5'd26,
        R_CLEAR_COLOR = 5'd27, R_CLEAR_DEPTH = 5'd28, R_PERF_CYCLES = 5'd29,
        R_PERF_PIXELS = 5'd30;

    reg [31:0] cfg [0:31];
    wire [4:0] s_idx = s_addr[6:2];

    wire [63:0] rt_addr  = {cfg[R_RT_HI],  cfg[R_RT_LO]};
    wire [63:0] z_addr   = {cfg[R_Z_HI],   cfg[R_Z_LO]};
    wire [63:0] vtx_addr = {cfg[R_VTX_HI], cfg[R_VTX_LO]};
    wire [63:0] vs_addr  = {cfg[R_VS_HI],  cfg[R_VS_LO]};
    wire [63:0] fs_addr  = {cfg[R_FS_HI],  cfg[R_FS_LO]};
    wire [63:0] tex_addr = {cfg[R_TEX_HI], cfg[R_TEX_LO]};
    wire [63:0] uni_addr = {cfg[R_UNI_HI], cfg[R_UNI_LO]};
    wire [11:0] rt_w     = cfg[R_RT_DIM][11:0];
    wire [11:0] rt_h     = cfg[R_RT_DIM][27:16];
    wire [31:0] vtx_count = cfg[R_VTX_COUNT];
    // Hardware clamps anything that sizes an internal RAM.
    wire [3:0]  stride   = (cfg[R_VTX_STRIDE] > 32'd8 || cfg[R_VTX_STRIDE] == 0)
                           ? 4'd8 : cfg[R_VTX_STRIDE][3:0];
    wire [8:0]  vs_len   = (cfg[R_VS_LEN] > 32'd256) ? 9'd256 : cfg[R_VS_LEN][8:0];
    wire [8:0]  fs_len   = (cfg[R_FS_LEN] > 32'd256) ? 9'd256 : cfg[R_FS_LEN][8:0];
    wire [5:0]  uni_len  = (cfg[R_UNI_COUNT] > 32'd32) ? 6'd32 : cfg[R_UNI_COUNT][5:0];
    wire [3:0]  tex_lw   = (cfg[R_TEX_DIM][3:0]  > 4'd11) ? 4'd11 : cfg[R_TEX_DIM][3:0];
    wire [3:0]  tex_lh   = (cfg[R_TEX_DIM][11:8] > 4'd11) ? 4'd11 : cfg[R_TEX_DIM][11:8];
    wire        f_clear_c = cfg[R_FLAGS][0];
    wire        f_clear_z = cfg[R_FLAGS][1];
    wire        f_ztest   = cfg[R_FLAGS][2];
    wire        f_zwrite  = cfg[R_FLAGS][3];
    wire        f_cull    = cfg[R_FLAGS][4];   // cull back faces (GL: CCW is front)

    reg        busy, fault, irq_status, irq_enable;
    reg [31:0] perf_cycles, perf_pixels;
    assign irq = irq_status & irq_enable;

    always @* begin
        case (s_idx)
        R_ID:          s_rdata = FXG_ID;
        R_CTRL:        s_rdata = 32'd0;
        R_STATUS:      s_rdata = {30'd0, fault, busy};
        R_IRQ_STATUS:  s_rdata = {31'd0, irq_status};
        R_IRQ_ENABLE:  s_rdata = {31'd0, irq_enable};
        R_PERF_CYCLES: s_rdata = perf_cycles;
        R_PERF_PIXELS: s_rdata = perf_pixels;
        default:       s_rdata = cfg[s_idx];
        endcase
    end

    wire start    = s_valid && s_we && s_idx == R_CTRL && s_wdata[0] && !busy;
    // CTRL bit 1: abort whatever is running and return to idle. Also clears
    // IRQ_ENABLE, so the driver must re-arm it.
    wire soft_rst = s_valid && s_we && s_idx == R_CTRL && s_wdata[1];
    wire core_rst = rst | soft_rst;

    // ------------------------------------------------------------------
    // Memories and the shader core
    // ------------------------------------------------------------------
    reg  [31:0] prog [0:511];
    reg  [31:0] prog_q;
    wire [8:0]  prog_addr;
    always @(posedge clk) prog_q <= prog[prog_addr];

    reg  [31:0] uni [0:31];
    wire [4:0]  sh_uni_addr;

    reg  [31:0] sin [0:7];
    wire [255:0] sh_in = {sin[7], sin[6], sin[5], sin[4], sin[3], sin[2], sin[1], sin[0]};
    wire [255:0] sh_out;
    wire signed [31:0] so0 = sh_out[31:0],    so1 = sh_out[63:32],
                       so2 = sh_out[95:64],   so3 = sh_out[127:96],
                       so4 = sh_out[159:128], so5 = sh_out[191:160],
                       so6 = sh_out[223:192], so7 = sh_out[255:224];

    reg         sh_start, sh_base;
    wire        sh_done, sh_fault, sh_killed;
    wire        tex_req;
    wire [31:0] tex_u, tex_v;
    reg         tex_ack;
    reg  [31:0] tex_data;

    fxg_shader u_shader (
        .clk(clk), .rst(core_rst), .start(sh_start), .base(sh_base),
        .busy(), .done(sh_done), .fault(sh_fault), .killed(sh_killed),
        .prog_addr(prog_addr), .prog_data(prog_q),
        .uni_addr(sh_uni_addr), .uni_data(uni[sh_uni_addr]),
        .in_flat(sh_in), .out_flat(sh_out),
        .tex_req(tex_req), .tex_u(tex_u), .tex_v(tex_v),
        .tex_ack(tex_ack), .tex_data(tex_data));

    reg         div_start;
    reg  [47:0] div_num;
    reg  [31:0] div_den;
    wire        div_done;
    wire [47:0] div_quo;
    fxg_div #(.NW(48), .DW(32)) u_div (
        .clk(clk), .rst(core_rst), .start(div_start), .num(div_num), .den(div_den),
        .busy(), .done(div_done), .quo(div_quo));
    localparam [47:0] TWO40 = 48'h0100_0000_0000;

    // ------------------------------------------------------------------
    // Fixed-point helpers
    // ------------------------------------------------------------------
    // Twice the signed area of triangle (a, b, c); also the edge function of
    // edge a->b evaluated at c.
    function signed [47:0] orient;
        input signed [31:0] ax, ay, bx, by, cx, cy;
        reg signed [47:0] abx, aby, acx, acy;
        begin
            abx = bx - ax; aby = by - ay; acx = cx - ax; acy = cy - ay;
            orient = abx * acy - aby * acx;
        end
    endfunction

    // a0 + l1*(a1-a0) + l2*(a2-a0), l in Q0.16 (0..65536).
    function signed [31:0] interp;
        input signed [31:0] a0, a1, a2;
        input [16:0] l1, l2;
        reg signed [63:0] d1, d2, acc;
        begin
            d1 = a1 - a0; d2 = a2 - a0;
            acc = d1 * $signed({47'd0, l1}) + d2 * $signed({47'd0, l2});
            acc = acc >>> 16;
            interp = a0 + acc[31:0];
        end
    endfunction

    // clip coordinate (Q16.16) * 1/w (Q8.24) -> NDC (Q16.16), saturated to
    // +-8.0. There is no clipper: this is a crude guard band.
    function signed [31:0] to_ndc;
        input signed [31:0] c, rw;
        reg signed [63:0] p;
        begin
            p = c; p = p * rw; p = p >>> 24;
            if (p > 64'sd524288) p = 64'sd524288;
            else if (p < -64'sd524288) p = -64'sd524288;
            to_ndc = p[31:0];
        end
    endfunction

    // NDC -> 28.4 screen coordinate: (n + 1) * dim / 2 * 16
    function signed [31:0] to_screen;
        input signed [31:0] n;
        input [11:0] dim;
        reg signed [63:0] p;
        begin
            p = n; p = (p + 64'sd65536) * $signed({52'd0, dim}) * 64'sd8;
            p = p >>> 16;
            to_screen = p[31:0];
        end
    endfunction

    function signed [31:0] mul_q; // (a * b) >>> sh
        input signed [31:0] a, b;
        input [5:0] sh;
        reg signed [63:0] p;
        begin p = a; p = p * b; p = p >>> sh; mul_q = p[31:0]; end
    endfunction

    function [7:0] chan; // Q16.16 [0,1] -> 8 bit, clamped
        input signed [31:0] c;
        begin
            if (c < 0) chan = 8'd0;
            else if (c >= 32'sd65536) chan = 8'd255;
            else chan = c[15:8];
        end
    endfunction

    // ------------------------------------------------------------------
    // Fill rule
    // ------------------------------------------------------------------
    // An edge runs a -> b with ex = bx - ax, ey = by - ay. Triangles reach the
    // rasteriser wound so that the interior is where the edge function is
    // positive, in y-down screen space. A pixel centre exactly on an edge
    // (edge function == 0) is drawn only if that edge "owns" it.
    //
    // TODO(corrina): return 1 only for top and left edges, so two triangles
    // sharing an edge never both draw (or both skip) the pixels on it.
    // Returning 1 unconditionally, as below, double-draws shared edges:
    // invisible with opaque depth-tested geometry, wrong the moment blending
    // or stencil counting exists.
    function owns_edge;
        input signed [31:0] ex, ey;
        begin
            owns_edge = 1'b1;
        end
    endfunction

    // ------------------------------------------------------------------
    // Pipeline state
    // ------------------------------------------------------------------
    localparam [4:0]
        S_IDLE = 5'd0, S_LD_VS = 5'd1, S_LD_FS = 5'd2, S_LD_UNI = 5'd3,
        S_CLR_C = 5'd4, S_CLR_Z = 5'd5, S_TRI = 5'd6, S_VFETCH = 5'd7,
        S_VSTART = 5'd8, S_VRUN = 5'd9, S_VDIV = 5'd10, S_VDIVW = 5'd11,
        S_VPOST = 5'd12, S_SETUP1 = 5'd13, S_SETUP2 = 5'd14, S_SETUP3 = 5'd15,
        S_PIX = 5'd16, S_INT1 = 5'd17, S_INT2 = 5'd18, S_ZRD = 5'd19,
        S_PDIV = 5'd20, S_PDIVW = 5'd21, S_PVARY = 5'd22, S_FSTART = 5'd23,
        S_FRUN = 5'd24, S_CWR = 5'd25, S_ZWR = 5'd26, S_ADV = 5'd27,
        S_NEXT = 5'd28, S_FIN = 5'd29;
    localparam signed [31:0] W_MIN = 32'sh0000_0400;  // 1/64: whole-triangle near reject

    reg [4:0]  state;
    reg [23:0] cnt;
    reg [31:0] vtx_idx;
    reg [1:0]  vert;
    reg        reject, swapped;

    // Per-vertex results (index = corner 0..2)
    reg signed [31:0] vx [0:2], vy [0:2];   // 28.4 screen
    reg signed [31:0] vz [0:2];             // 24-bit depth
    reg signed [31:0] vrw [0:2];            // 1/w, Q8.24
    reg signed [31:0] vp [0:11];            // varying * 1/w, Q8.24, [corner*4 + k]
    reg signed [31:0] rw_cur;

    // Triangle setup
    reg signed [47:0] area;
    reg [5:0]         nshift;
    reg [47:0]        recip;                // 2^40 / (area >> nshift)
    reg [11:0]        xmin, xmax, ymin, ymax, px, py;
    reg signed [47:0] w0, w1, w2, w0r, w1r, w2r;
    reg signed [47:0] w0dx, w1dx, w2dx, w0dy, w1dy, w2dy;
    reg               own0, own1, own2;

    // Per-pixel
    reg [16:0]        l1, l2;
    reg [23:0]        pz;
    reg signed [31:0] prw;
    reg signed [31:0] pvp [0:3];
    reg signed [31:0] pw;                   // w = 1/(1/w), Q16.16
    reg [31:0]        color;

    wire signed [47:0] area_c = orient(vx[0], vy[0], vx[1], vy[1], vx[2], vy[2]);

    // Bounding box of the triangle, in pixels whose centres can be covered.
    function signed [31:0] min3; input signed [31:0] a, b, c;
        begin min3 = (a < b) ? ((a < c) ? a : c) : ((b < c) ? b : c); end endfunction
    function signed [31:0] max3; input signed [31:0] a, b, c;
        begin max3 = (a > b) ? ((a > c) ? a : c) : ((b > c) ? b : c); end endfunction
    wire signed [31:0] bx0 = (min3(vx[0], vx[1], vx[2]) + 32'sd7) >>> 4;
    wire signed [31:0] bx1 = (max3(vx[0], vx[1], vx[2]) - 32'sd8) >>> 4;
    wire signed [31:0] by0 = (min3(vy[0], vy[1], vy[2]) + 32'sd7) >>> 4;
    wire signed [31:0] by1 = (max3(vy[0], vy[1], vy[2]) - 32'sd8) >>> 4;
    wire signed [31:0] wm1 = {20'd0, rt_w} - 32'sd1;
    wire signed [31:0] hm1 = {20'd0, rt_h} - 32'sd1;
    wire signed [31:0] cx0 = (bx0 < 0) ? 32'sd0 : bx0;
    wire signed [31:0] cx1 = (bx1 > wm1) ? wm1 : bx1;
    wire signed [31:0] cy0 = (by0 < 0) ? 32'sd0 : by0;
    wire signed [31:0] cy1 = (by1 > hm1) ? hm1 : by1;
    wire               bbox_empty = (cx0 > cx1) || (cy0 > cy1);
    wire signed [31:0] sx4 = (cx0 <<< 4) + 32'sd8;   // first pixel centre, 28.4
    wire signed [31:0] sy4 = (cy0 <<< 4) + 32'sd8;

    // Normalisation shift so that area fits 24 bits before the reciprocal.
    reg [5:0] nshift_c;
    integer   bi;
    always @* begin
        nshift_c = 6'd0;
        for (bi = 24; bi < 48; bi = bi + 1)
            if (area[bi]) nshift_c = bi[5:0] - 6'd23;
    end
    wire [47:0] area_n = area >> nshift_c;

    // Barycentric weights of corners 1 and 2 as Q0.16.
    wire [47:0] w1n = w1 >> nshift;
    wire [47:0] w2n = w2 >> nshift;
    wire [79:0] l1p = w1n[31:0] * recip;
    wire [79:0] l2p = w2n[31:0] * recip;
    wire [16:0] l1c = (|l1p[79:40]) ? 17'h10000 : l1p[40:24];
    wire [16:0] l2c = (|l2p[79:40]) ? 17'h10000 : l2p[40:24];

    wire signed [31:0] z_i = interp(vz[0], vz[1], vz[2], l1, l2);

    wire covered = (w0 > 0 || (w0 == 0 && own0)) &&
                  (w1 > 0 || (w1 == 0 && own1)) &&
                  (w2 > 0 || (w2 == 0 && own2));

    wire [23:0] pix_idx = py * rt_w + {12'd0, px};

    // Texture address: repeat wrap, nearest texel.
    wire [15:0] tx = tex_u[15:0] >> (5'd16 - {1'b0, tex_lw});
    wire [15:0] ty = tex_v[15:0] >> (5'd16 - {1'b0, tex_lh});
    wire [23:0] texel = ({8'd0, ty} << tex_lw) | {8'd0, tx};

    wire signed [31:0] ndc_x = to_ndc(so0, rw_cur);
    wire signed [31:0] ndc_y = to_ndc(so1, rw_cur);
    wire signed [31:0] ndc_z = to_ndc(so2, rw_cur);
    wire signed [31:0] z_raw = (ndc_z + 32'sd65536) <<< 7;
    wire [23:0]        z_vtx = (z_raw < 0) ? 24'd0 :
                               (z_raw > 32'sh00FF_FFFF) ? 24'hFFFFFF : z_raw[23:0];

    // ------------------------------------------------------------------
    // DMA master: the request is a pure function of the state, so it drops
    // on the same edge the FSM accepts m_ready.
    // ------------------------------------------------------------------
    wire [31:0] vword = (vtx_idx + {30'd0, vert}) * {28'd0, stride} + {8'd0, cnt};
    always @* begin
        m_valid = 1'b0; m_we = 1'b0; m_addr = 64'd0; m_wdata = 32'd0;
        case (state)
        S_LD_VS:  begin m_valid = cnt[8:0] != vs_len;  m_addr = vs_addr  + {38'd0, cnt, 2'b00}; end
        S_LD_FS:  begin m_valid = cnt[8:0] != fs_len;  m_addr = fs_addr  + {38'd0, cnt, 2'b00}; end
        S_LD_UNI: begin m_valid = cnt[5:0] != uni_len; m_addr = uni_addr + {38'd0, cnt, 2'b00}; end
        S_CLR_C:  begin m_valid = 1'b1; m_we = 1'b1; m_addr = rt_addr + {38'd0, cnt, 2'b00}; m_wdata = cfg[R_CLEAR_COLOR]; end
        S_CLR_Z:  begin m_valid = 1'b1; m_we = 1'b1; m_addr = z_addr  + {38'd0, cnt, 2'b00}; m_wdata = cfg[R_CLEAR_DEPTH]; end
        S_VFETCH: begin m_valid = 1'b1; m_addr = vtx_addr + {30'd0, vword, 2'b00}; end
        S_ZRD:    begin m_valid = 1'b1; m_addr = z_addr + {38'd0, pix_idx, 2'b00}; end
        S_CWR:    begin m_valid = 1'b1; m_we = 1'b1; m_addr = rt_addr + {38'd0, pix_idx, 2'b00}; m_wdata = color; end
        S_ZWR:    begin m_valid = 1'b1; m_we = 1'b1; m_addr = z_addr  + {38'd0, pix_idx, 2'b00}; m_wdata = {8'd0, pz}; end
        S_VRUN, S_FRUN: begin m_valid = tex_req && !tex_ack; m_addr = tex_addr + {38'd0, texel, 2'b00}; end
        default: ;
        endcase
    end

    wire [23:0] pix_total = rt_w * rt_h;

    integer k;
    always @(posedge clk) begin
        sh_start  <= 1'b0;
        div_start <= 1'b0;
        tex_ack   <= 1'b0;

        if (s_valid && s_we) begin
            if (!busy && s_idx >= R_RT_LO && s_idx <= R_CLEAR_DEPTH)
                cfg[s_idx] <= s_wdata;
            if (s_idx == R_IRQ_STATUS && s_wdata[0]) irq_status <= 1'b0;
            if (s_idx == R_IRQ_ENABLE) irq_enable <= s_wdata[0];
        end
        if (busy) perf_cycles <= perf_cycles + 32'd1;

        if (core_rst) begin
            state <= S_IDLE; busy <= 1'b0; fault <= 1'b0;
            irq_status <= 1'b0; irq_enable <= 1'b0;
            perf_cycles <= 32'd0; perf_pixels <= 32'd0;
        end else case (state)
        S_IDLE: if (start) begin
            busy <= 1'b1; fault <= 1'b0; cnt <= 24'd0;
            perf_cycles <= 32'd0; perf_pixels <= 32'd0;
            state <= S_LD_VS;
        end

        // ---- load vertex program, fragment program, uniforms ----
        S_LD_VS: if (cnt[8:0] == vs_len) begin cnt <= 24'd0; state <= S_LD_FS; end
                 else if (m_ready) begin prog[{1'b0, cnt[7:0]}] <= m_rdata; cnt <= cnt + 24'd1; end
        S_LD_FS: if (cnt[8:0] == fs_len) begin cnt <= 24'd0; state <= S_LD_UNI; end
                 else if (m_ready) begin prog[{1'b1, cnt[7:0]}] <= m_rdata; cnt <= cnt + 24'd1; end
        S_LD_UNI: if (cnt[5:0] == uni_len) begin
                      cnt <= 24'd0;
                      state <= f_clear_c ? S_CLR_C : (f_clear_z ? S_CLR_Z : S_TRI);
                      vtx_idx <= 32'd0;
                  end else if (m_ready) begin uni[cnt[4:0]] <= m_rdata; cnt <= cnt + 24'd1; end

        // ---- clears ----
        S_CLR_C: if (m_ready) begin
            if (cnt + 24'd1 >= pix_total) begin cnt <= 24'd0; state <= f_clear_z ? S_CLR_Z : S_TRI; end
            else cnt <= cnt + 24'd1;
        end
        S_CLR_Z: if (m_ready) begin
            if (cnt + 24'd1 >= pix_total) begin cnt <= 24'd0; state <= S_TRI; end
            else cnt <= cnt + 24'd1;
        end

        // ---- geometry ----
        S_TRI: begin
            vert <= 2'd0; cnt <= 24'd0; reject <= 1'b0; swapped <= 1'b0;
            state <= (vtx_idx + 32'd3 > vtx_count) ? S_FIN : S_VFETCH;
        end
        S_VFETCH: if (m_ready) begin
            sin[cnt[2:0]] <= m_rdata;
            if (cnt[3:0] + 4'd1 == stride) state <= S_VSTART;
            else cnt <= cnt + 24'd1;
        end
        S_VSTART: begin sh_start <= 1'b1; sh_base <= 1'b0; state <= S_VRUN; end
        S_VRUN: begin
            if (m_valid && m_ready) begin tex_data <= m_rdata; tex_ack <= 1'b1; end
            if (sh_done) begin
                if (sh_fault) begin fault <= 1'b1; state <= S_FIN; end
                else state <= S_VDIV;
            end
        end
        S_VDIV: begin
            if (so3 < W_MIN) begin
                reject <= 1'b1;
                state  <= S_VPOST;
            end else begin
                div_start <= 1'b1; div_num <= TWO40; div_den <= so3;
                state <= S_VDIVW;
            end
        end
        S_VDIVW: if (div_done) begin rw_cur <= div_quo[31:0]; state <= S_VPOST; end
        S_VPOST: begin
            vx[vert]  <= to_screen(ndc_x, rt_w);
            vy[vert]  <= to_screen(-ndc_y, rt_h);
            vz[vert]  <= {8'd0, z_vtx};
            vrw[vert] <= rw_cur;
            vp[{vert, 2'd0}] <= mul_q(so4, rw_cur, 6'd16);
            vp[{vert, 2'd1}] <= mul_q(so5, rw_cur, 6'd16);
            vp[{vert, 2'd2}] <= mul_q(so6, rw_cur, 6'd16);
            vp[{vert, 2'd3}] <= mul_q(so7, rw_cur, 6'd16);
            cnt <= 24'd0;
            if (vert == 2'd2) state <= S_SETUP1;
            else begin vert <= vert + 2'd1; state <= S_VFETCH; end
        end

        // ---- triangle setup ----
        S_SETUP1: begin
            if (reject || area_c == 0) state <= S_NEXT;
            else if (area_c < 0) begin
                // Front-facing (CCW in GL space is clockwise on a y-down
                // screen). Swap corners 1 and 2 so the interior is positive.
                vx[1] <= vx[2]; vx[2] <= vx[1]; vy[1] <= vy[2]; vy[2] <= vy[1];
                vz[1] <= vz[2]; vz[2] <= vz[1]; vrw[1] <= vrw[2]; vrw[2] <= vrw[1];
                for (k = 0; k < 4; k = k + 1) begin
                    vp[4 + k] <= vp[8 + k]; vp[8 + k] <= vp[4 + k];
                end
                swapped <= 1'b1;
            end else if (!swapped && f_cull) state <= S_NEXT;
            else begin area <= area_c; state <= S_SETUP2; end
        end
        S_SETUP2: begin
            xmin <= cx0[11:0]; xmax <= cx1[11:0]; ymin <= cy0[11:0]; ymax <= cy1[11:0];
            px <= cx0[11:0]; py <= cy0[11:0];
            nshift <= nshift_c;
            // w0 belongs to corner 0 (edge 1->2), w1 to corner 1 (edge 2->0),
            // w2 to corner 2 (edge 0->1).
            w0  <= orient(vx[1], vy[1], vx[2], vy[2], sx4, sy4);
            w0r <= orient(vx[1], vy[1], vx[2], vy[2], sx4, sy4);
            w1  <= orient(vx[2], vy[2], vx[0], vy[0], sx4, sy4);
            w1r <= orient(vx[2], vy[2], vx[0], vy[0], sx4, sy4);
            w2  <= orient(vx[0], vy[0], vx[1], vy[1], sx4, sy4);
            w2r <= orient(vx[0], vy[0], vx[1], vy[1], sx4, sy4);
            // One pixel step = 16 sub-pixel units.
            w0dx <= -((vy[2] - vy[1]) <<< 4); w0dy <= (vx[2] - vx[1]) <<< 4;
            w1dx <= -((vy[0] - vy[2]) <<< 4); w1dy <= (vx[0] - vx[2]) <<< 4;
            w2dx <= -((vy[1] - vy[0]) <<< 4); w2dy <= (vx[1] - vx[0]) <<< 4;
            own0 <= owns_edge(vx[2] - vx[1], vy[2] - vy[1]);
            own1 <= owns_edge(vx[0] - vx[2], vy[0] - vy[2]);
            own2 <= owns_edge(vx[1] - vx[0], vy[1] - vy[0]);
            if (bbox_empty) state <= S_NEXT;
            else begin
                div_start <= 1'b1; div_num <= TWO40; div_den <= area_n[31:0];
                state <= S_SETUP3;
            end
        end
        S_SETUP3: if (div_done) begin recip <= div_quo; state <= S_PIX; end

        // ---- per pixel ----
        S_PIX: state <= covered ? S_INT1 : S_ADV;
        S_INT1: begin l1 <= l1c; l2 <= l2c; state <= S_INT2; end
        S_INT2: begin
            pz  <= (z_i < 0) ? 24'd0 : (z_i > 32'sh00FF_FFFF) ? 24'hFFFFFF : z_i[23:0];
            prw <= interp(vrw[0], vrw[1], vrw[2], l1, l2);
            for (k = 0; k < 4; k = k + 1)
                pvp[k] <= interp(vp[k], vp[4 + k], vp[8 + k], l1, l2);
            state <= f_ztest ? S_ZRD : S_PDIV;
        end
        S_ZRD: if (m_ready) state <= (pz < m_rdata[23:0]) ? S_PDIV : S_ADV;   // LESS
        S_PDIV: begin
            div_start <= 1'b1; div_num <= TWO40;
            div_den <= (prw <= 0) ? 32'd1 : prw;
            state <= S_PDIVW;
        end
        S_PDIVW: if (div_done) begin
            pw <= (|div_quo[47:31]) ? 32'sh7FFF_FFFF : div_quo[31:0];
            state <= S_PVARY;
        end
        S_PVARY: begin
            // Perspective-correct varyings: (v/w) / (1/w)
            for (k = 0; k < 4; k = k + 1) sin[k] <= mul_q(pvp[k], pw, 6'd24);
            sin[4] <= {20'd0, px};
            sin[5] <= {20'd0, py};
            sin[6] <= {8'd0, pz};
            sin[7] <= pw;
            state  <= S_FSTART;
        end
        S_FSTART: begin sh_start <= 1'b1; sh_base <= 1'b1; state <= S_FRUN; end
        S_FRUN: begin
            if (m_valid && m_ready) begin tex_data <= m_rdata; tex_ack <= 1'b1; end
            if (sh_done) begin
                if (sh_fault) begin fault <= 1'b1; state <= S_FIN; end
                else if (sh_killed) state <= S_ADV;
                else begin
                    color <= {chan(so3), chan(so0), chan(so1), chan(so2)};  // ARGB
                    state <= S_CWR;
                end
            end
        end
        S_CWR: if (m_ready) begin
            perf_pixels <= perf_pixels + 32'd1;
            state <= f_zwrite ? S_ZWR : S_ADV;
        end
        S_ZWR: if (m_ready) state <= S_ADV;
        S_ADV: begin
            if (px == xmax) begin
                if (py == ymax) state <= S_NEXT;
                else begin
                    px <= xmin; py <= py + 12'd1;
                    w0 <= w0r + w0dy; w0r <= w0r + w0dy;
                    w1 <= w1r + w1dy; w1r <= w1r + w1dy;
                    w2 <= w2r + w2dy; w2r <= w2r + w2dy;
                    state <= S_PIX;
                end
            end else begin
                px <= px + 12'd1;
                w0 <= w0 + w0dx; w1 <= w1 + w1dx; w2 <= w2 + w2dx;
                state <= S_PIX;
            end
        end
        S_NEXT: begin vtx_idx <= vtx_idx + 32'd3; state <= S_TRI; end
        S_FIN: begin busy <= 1'b0; irq_status <= 1'b1; state <= S_IDLE; end
        default: state <= S_IDLE;
        endcase
    end
endmodule
`default_nettype wire
