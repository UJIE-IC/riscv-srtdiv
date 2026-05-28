module rv32m_srt_postprocess #(
    parameter int REM_WIDTH = 35,
    parameter int OTF_WIDTH = 33
) (
    input logic signed [REM_WIDTH-1:0] residual_i,
    input logic residual_negative_i,
    input logic signed [REM_WIDTH-1:0] divisor_norm_i,
    input logic [OTF_WIDTH-1:0] q_otf_i,
    input logic [OTF_WIDTH-1:0] qm_otf_i,
    input logic shift_down_i,
    input logic [5:0] remainder_shift_i,
    output logic [31:0] quotient_o,
    output logic [31:0] remainder_o
);

    logic signed [REM_WIDTH-1:0] restore_addend;
    logic signed [REM_WIDTH-1:0] remainder_restored;
    logic signed [REM_WIDTH-1:0] remainder_aligned;
    logic signed [REM_WIDTH-1:0] remainder_shifted;
    logic [OTF_WIDTH-1:0] quotient_selected;
    logic [OTF_WIDTH-1:0] quotient_full;

    // residual 为负时选择 Q-1，并按 e 奇偶加回 D 或 2D。
    assign quotient_selected = residual_negative_i ? qm_otf_i : q_otf_i;
    assign quotient_full = shift_down_i ? (quotient_selected >> 1) : quotient_selected;
    always_comb begin
        unique case ({residual_negative_i, shift_down_i})
            2'b10: begin
                restore_addend = divisor_norm_i;
            end

            2'b11: begin
                restore_addend = divisor_norm_i << 1;
            end

            default: begin
                restore_addend = '0;
            end
        endcase
    end

    assign remainder_restored = residual_i + restore_addend;
    assign remainder_aligned = shift_down_i ? (remainder_restored >>> 1) : remainder_restored;
    assign remainder_shifted = remainder_aligned >>> remainder_shift_i;

    assign quotient_o = quotient_full[31:0];
    assign remainder_o = remainder_shifted[31:0];

endmodule
