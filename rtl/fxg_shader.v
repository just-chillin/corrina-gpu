// FXG-1 programmable shader core.
//
// 16 x 32-bit registers, Q16.16 fixed point, 32-bit instructions:
//   [31:24] opcode  [23:20] rd  [19:16] ra  [15:12] rb  /  [15:0] imm16
// The same core runs vertex programs (program RAM 0..255) and fragment
// programs (256..511). Branches exist, so a step watchdog guarantees that a
// buggy shader cannot hang the pipeline: it faults instead.
`default_nettype none
module fxg_shader (
    input  wire         clk,
    input  wire         rst,
    input  wire         start,
    input  wire         base,        // 0 = vertex program, 1 = fragment program
    output reg          busy,
    output reg          done,
    output reg          fault,
    output reg          killed,
    output wire [8:0]   prog_addr,   // synchronous-read program RAM
    input  wire [31:0]  prog_data,
    output wire [4:0]   uni_addr,    // asynchronous-read uniform RAM
    input  wire [31:0]  uni_data,
    input  wire [255:0] in_flat,     // 8 input slots (attributes / varyings)
    output wire [255:0] out_flat,    // 8 output slots
    output reg          tex_req,
    output reg  [31:0]  tex_u,
    output reg  [31:0]  tex_v,
    input  wire         tex_ack,
    input  wire [31:0]  tex_data
);
    localparam [7:0]
        OP_HALT = 8'h00, OP_LDI  = 8'h01, OP_LUI  = 8'h02, OP_MOV  = 8'h03,
        OP_ADD  = 8'h04, OP_SUB  = 8'h05, OP_MUL  = 8'h06, OP_MULF = 8'h07,
        OP_AND  = 8'h08, OP_OR   = 8'h09, OP_XOR  = 8'h0A, OP_SHL  = 8'h0B,
        OP_SHR  = 8'h0C, OP_SAR  = 8'h0D, OP_SLT  = 8'h0E, OP_MIN  = 8'h0F,
        OP_MAX  = 8'h10, OP_IN   = 8'h11, OP_OUT  = 8'h12, OP_UNI  = 8'h13,
        OP_TEX  = 8'h14, OP_BZ   = 8'h15, OP_BNZ  = 8'h16, OP_JMP  = 8'h17,
        OP_RCP  = 8'h18, OP_KILL = 8'h19, OP_ADDI = 8'h1A, OP_SHLI = 8'h1B,
        OP_SHRI = 8'h1C, OP_SARI = 8'h1D;

    localparam [1:0] ST_IDLE = 2'd0, ST_FETCH = 2'd1, ST_EXEC = 2'd2, ST_WAIT = 2'd3;
    localparam [11:0] MAX_STEPS = 12'd4000;

    reg [1:0]  state;
    reg [7:0]  pc;
    reg        base_r;
    reg [11:0] steps;
    reg [3:0]  wr;          // destination latched across multi-cycle ops
    reg        wait_div;    // ST_WAIT: 1 = divider, 0 = texture
    reg        div_neg;

    reg [31:0] r    [0:15];
    reg [31:0] outr [0:7];

    wire [31:0] ir   = prog_data;
    wire [7:0]  op   = ir[31:24];
    wire [3:0]  rd   = ir[23:20];
    wire [3:0]  ra   = ir[19:16];
    wire [3:0]  rb   = ir[15:12];
    wire [15:0] imm  = ir[15:0];
    wire [31:0] simm = {{16{imm[15]}}, imm};
    wire [31:0] a    = r[ra];
    wire [31:0] b    = r[rb];
    wire signed [63:0] prod = $signed(a) * $signed(b);
    wire        lt   = $signed(a) < $signed(b);

    assign prog_addr = {base_r, pc};
    assign uni_addr  = imm[4:0];

    genvar g;
    wire [31:0] inw [0:7];
    generate for (g = 0; g < 8; g = g + 1) begin : io
        assign inw[g] = in_flat[32*g +: 32];
        assign out_flat[32*g +: 32] = outr[g];
    end endgenerate

    // RCP: Q16.16 reciprocal = 2^32 / |a|, saturated, sign restored.
    reg         div_start;
    reg  [31:0] div_den;
    wire        div_done;
    wire [47:0] div_quo;
    fxg_div #(.NW(48), .DW(32)) u_div (
        .clk(clk), .rst(rst), .start(div_start),
        .num(48'h0001_0000_0000), .den(div_den),
        .busy(), .done(div_done), .quo(div_quo));
    wire [31:0] rcp_mag = (|div_quo[47:31]) ? 32'h7FFF_FFFF : div_quo[31:0];

    always @(posedge clk) begin
        done      <= 1'b0;
        div_start <= 1'b0;
        if (rst) begin
            state <= ST_IDLE; busy <= 1'b0; tex_req <= 1'b0;
            fault <= 1'b0; killed <= 1'b0;
        end else case (state)
        ST_IDLE: if (start) begin
            pc <= 8'd0; base_r <= base; steps <= 12'd0;
            busy <= 1'b1; fault <= 1'b0; killed <= 1'b0;
            state <= ST_FETCH;
        end
        ST_FETCH: state <= ST_EXEC;   // program RAM read latency
        ST_EXEC: begin
            pc    <= pc + 8'd1;
            steps <= steps + 12'd1;
            state <= ST_FETCH;
            case (op)
            OP_HALT: begin busy <= 1'b0; done <= 1'b1; state <= ST_IDLE; end
            OP_LDI:  r[rd] <= simm;
            OP_LUI:  r[rd] <= {imm, r[rd][15:0]};
            OP_MOV:  r[rd] <= a;
            OP_ADD:  r[rd] <= a + b;
            OP_SUB:  r[rd] <= a - b;
            OP_MUL:  r[rd] <= prod[31:0];
            OP_MULF: r[rd] <= prod[47:16];
            OP_AND:  r[rd] <= a & b;
            OP_OR:   r[rd] <= a | b;
            OP_XOR:  r[rd] <= a ^ b;
            OP_SHL:  r[rd] <= a << b[4:0];
            OP_SHR:  r[rd] <= a >> b[4:0];
            OP_SAR:  r[rd] <= $signed(a) >>> b[4:0];
            OP_SLT:  r[rd] <= {31'd0, lt};
            OP_MIN:  r[rd] <= lt ? a : b;
            OP_MAX:  r[rd] <= lt ? b : a;
            OP_IN:   r[rd] <= inw[imm[2:0]];
            OP_OUT:  outr[imm[2:0]] <= a;
            OP_UNI:  r[rd] <= uni_data;
            OP_TEX:  begin
                tex_req <= 1'b1; tex_u <= a; tex_v <= b;
                wr <= rd; wait_div <= 1'b0; state <= ST_WAIT;
            end
            OP_BZ:   if (a == 32'd0) pc <= imm[7:0];
            OP_BNZ:  if (a != 32'd0) pc <= imm[7:0];
            OP_JMP:  pc <= imm[7:0];
            OP_RCP:  begin
                div_start <= 1'b1;
                div_den   <= a[31] ? (~a + 32'd1) : a;
                div_neg   <= a[31];
                wr <= rd; wait_div <= 1'b1; state <= ST_WAIT;
            end
            OP_KILL: if (a != 32'd0) begin
                killed <= 1'b1; busy <= 1'b0; done <= 1'b1; state <= ST_IDLE;
            end
            OP_ADDI: r[rd] <= a + simm;
            OP_SHLI: r[rd] <= a << imm[4:0];
            OP_SHRI: r[rd] <= a >> imm[4:0];
            OP_SARI: r[rd] <= $signed(a) >>> imm[4:0];
            default: begin   // illegal opcode
                fault <= 1'b1; busy <= 1'b0; done <= 1'b1; state <= ST_IDLE;
            end
            endcase
            if (steps == MAX_STEPS) begin   // runaway shader
                fault <= 1'b1; busy <= 1'b0; done <= 1'b1; state <= ST_IDLE;
                tex_req <= 1'b0;
            end
        end
        ST_WAIT: begin
            if (wait_div) begin
                if (div_done) begin
                    r[wr] <= div_neg ? (~rcp_mag + 32'd1) : rcp_mag;
                    state <= ST_FETCH;
                end
            end else if (tex_ack) begin
                r[wr] <= tex_data; tex_req <= 1'b0; state <= ST_FETCH;
            end
        end
        endcase
    end
endmodule
`default_nettype wire
