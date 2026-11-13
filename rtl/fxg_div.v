// Sequential restoring divider: quo = num / den, unsigned, NW cycles.
// One of these is shared by the pipeline (1/w, 1/area, per-pixel 1/(1/w));
// the shader core owns a second one for its RCP instruction.
`default_nettype none
module fxg_div #(parameter NW = 48, parameter DW = 32) (
    input  wire          clk,
    input  wire          rst,
    input  wire          start,
    input  wire [NW-1:0] num,
    input  wire [DW-1:0] den,
    output reg           busy,
    output reg           done,
    output reg  [NW-1:0] quo
);
    reg [NW-1:0] n;
    reg [DW-1:0] d;
    reg [DW:0]   rem;
    reg [7:0]    cnt;

    wire [DW:0] sh  = {rem[DW-1:0], n[NW-1]};
    wire [DW:0] sub = sh - {1'b0, d};

    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            busy <= 1'b0;
        end else if (start && !busy) begin
            n <= num; d <= den; rem <= 0; quo <= 0;
            cnt <= NW[7:0]; busy <= 1'b1;
        end else if (busy) begin
            if (!sub[DW]) begin rem <= sub; quo <= {quo[NW-2:0], 1'b1}; end
            else          begin rem <= sh;  quo <= {quo[NW-2:0], 1'b0}; end
            n   <= {n[NW-2:0], 1'b0};
            cnt <= cnt - 8'd1;
            if (cnt == 8'd1) begin busy <= 1'b0; done <= 1'b1; end
        end
    end
endmodule
`default_nettype wire
