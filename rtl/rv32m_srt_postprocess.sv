module rv32m_srt_postprocess (
    input logic [31:0] dividend_i,
    input logic [31:0] divisor_i,
    input logic [33:0] quotient_raw_i,
    output logic [31:0] quotient_o,
    output logic [31:0] remainder_o
);

    logic [65:0] dividend_ext;
    logic [65:0] divisor_ext;
    logic [65:0] product_raw;
    logic [65:0] product_corr;
    logic [33:0] quotient_corr;
    logic need_decrement;

    assign dividend_ext = {34'd0, dividend_i};
    assign divisor_ext = {34'd0, divisor_i};
    assign product_raw = quotient_raw_i * divisor_i;
    assign need_decrement = (product_raw > dividend_ext);

    assign quotient_corr = need_decrement ? (quotient_raw_i - 34'd1) : quotient_raw_i;
    assign product_corr = need_decrement ? (product_raw - divisor_ext) : product_raw;

    assign quotient_o = quotient_corr[31:0];
    assign remainder_o = dividend_i - product_corr[31:0];

endmodule
