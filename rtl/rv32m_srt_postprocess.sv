module rv32m_srt_postprocess #(
    parameter int REM_WIDTH = 35,
    parameter int OTF_WIDTH = 36
) (
    input logic signed [REM_WIDTH-1:0] rem_sum_i,
    input logic signed [REM_WIDTH-1:0] rem_carry_i,
    input logic signed [REM_WIDTH-1:0] divisor_norm_i,
    input logic [OTF_WIDTH-1:0] q_otf_i,
    input logic [OTF_WIDTH-1:0] qm_otf_i,
    input logic shift_down_i,
    input logic [5:0] remainder_shift_i,
    output logic [31:0] quotient_o,
    output logic [31:0] remainder_o
);

    localparam int POST_WIDTH = REM_WIDTH + 3;

    logic signed [POST_WIDTH-1:0] residual_sum;
    logic signed [POST_WIDTH-1:0] divisor_norm_ext;
    logic signed [POST_WIDTH-1:0] correction_addend;
    logic signed [POST_WIDTH-1:0] remainder_norm;
    logic signed [POST_WIDTH-1:0] remainder_shifted;
    logic signed [REM_WIDTH-1:0] residual_compact;
    logic [OTF_WIDTH-1:0] quotient_scaled;
    logic [OTF_WIDTH-1:0] quotient_full;
    logic [OTF_WIDTH-1:0] quotient_back_scaled;
    logic [OTF_WIDTH-1:0] correction_units;

    assign residual_compact = rem_sum_i + rem_carry_i;
    assign residual_sum = {{3{residual_compact[REM_WIDTH-1]}}, residual_compact};
    assign divisor_norm_ext = {{3{divisor_norm_i[REM_WIDTH-1]}}, divisor_norm_i};

    assign quotient_scaled = residual_sum[POST_WIDTH-1] ? qm_otf_i : q_otf_i;
    assign quotient_full = shift_down_i ? (quotient_scaled >> 1) : quotient_scaled;
    assign quotient_back_scaled = shift_down_i ? (quotient_full << 1) : quotient_full;
    assign correction_units = q_otf_i - quotient_back_scaled;

    always_comb begin
        unique case (correction_units[1:0])
            2'd0: begin
                correction_addend = '0;
            end

            2'd1: begin
                correction_addend = divisor_norm_ext << 2;
            end

            2'd2: begin
                correction_addend = divisor_norm_ext << 3;
            end

            default: begin
                correction_addend = '0;
            end
        endcase
    end

    assign remainder_norm = residual_sum + correction_addend;
    assign remainder_shifted = remainder_norm >>> remainder_shift_i;

    assign quotient_o = quotient_full[31:0];
    assign remainder_o = remainder_shifted[31:0];

endmodule
