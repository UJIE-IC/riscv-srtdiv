module rv32m_srt_csa #(
    parameter int WIDTH = 35
) (
    input logic signed [WIDTH-1:0] a_i,
    input logic signed [WIDTH-1:0] b_i,
    input logic signed [WIDTH-1:0] c_i,
    output logic signed [WIDTH-1:0] sum_o,
    output logic signed [WIDTH-1:0] carry_o
);

    assign sum_o = a_i ^ b_i ^ c_i;
    assign carry_o = ((a_i & b_i) | (a_i & c_i) | (b_i & c_i)) << 1;

endmodule
