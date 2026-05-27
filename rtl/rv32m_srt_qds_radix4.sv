module rv32m_srt_qds_radix4 #(
    parameter int REM_WIDTH = 35,
    parameter int REM_FRAC_BITS = 31
) (
    input logic signed [REM_WIDTH-1:0] rem_sum_i,
    input logic signed [REM_WIDTH-1:0] rem_carry_i,
    input logic [31:0] divisor_norm_i,
    output logic signed [2:0] digit_o
);

    localparam int QDS_FRAC_BITS = 3;
    localparam int QDS_WIDTH = 4 + QDS_FRAC_BITS;
    localparam int RESIDUAL_FRAC_BITS = 4;
    localparam int RESIDUAL_HI_WIDTH = 4 + RESIDUAL_FRAC_BITS;
    localparam int RESIDUAL_HI_LSB = REM_FRAC_BITS - RESIDUAL_FRAC_BITS;

    logic [2:0] divisor_index;
    logic signed [RESIDUAL_HI_WIDTH-1:0] rem_sum_hi_q4_4;
    logic signed [RESIDUAL_HI_WIDTH-1:0] rem_carry_hi_q4_4;
    logic signed [RESIDUAL_HI_WIDTH:0] rem_hi_sum_q5_4;
    logic signed [QDS_WIDTH-1:0] rem_hi_q4_3;
    logic signed [QDS_WIDTH-1:0] m2;
    logic signed [QDS_WIDTH-1:0] m1;
    logic signed [QDS_WIDTH-1:0] m0;
    logic signed [QDS_WIDTH-1:0] m_n1;

    // divisor_norm_i 是 U1.31，最高位 bit31 恒为 1。
    assign divisor_index = divisor_norm_i[30:28];

    // rem_sum_i/rem_carry_i 是 Q4.31 的 carry-save residual。
    assign rem_sum_hi_q4_4 = rem_sum_i[REM_WIDTH-1:RESIDUAL_HI_LSB];
    assign rem_carry_hi_q4_4 = rem_carry_i[REM_WIDTH-1:RESIDUAL_HI_LSB];
    assign rem_hi_sum_q5_4 = rem_sum_hi_q4_4 + rem_carry_hi_q4_4;
    assign rem_hi_q4_3 = rem_hi_sum_q5_4[QDS_WIDTH:1];

    always_comb begin
        m2 = 7'sd12;
        m1 = 7'sd4;
        m0 = -7'sd4;
        m_n1 = -7'sd13;

        unique case (divisor_index)
            3'b000: begin
                m2 = 7'sd12;
                m1 = 7'sd4;
                m0 = -7'sd4;
                m_n1 = -7'sd13;
            end

            3'b001: begin
                m2 = 7'sd14;
                m1 = 7'sd4;
                m0 = -7'sd4;
                m_n1 = -7'sd14;
            end

            3'b010: begin
                m2 = 7'sd16;
                m1 = 7'sd4;
                m0 = -7'sd6;
                m_n1 = -7'sd16;
            end

            3'b011: begin
                m2 = 7'sd16;
                m1 = 7'sd4;
                m0 = -7'sd6;
                m_n1 = -7'sd17;
            end

            3'b100: begin
                m2 = 7'sd18;
                m1 = 7'sd6;
                m0 = -7'sd6;
                m_n1 = -7'sd18;
            end

            3'b101: begin
                m2 = 7'sd20;
                m1 = 7'sd6;
                m0 = -7'sd8;
                m_n1 = -7'sd20;
            end

            3'b110: begin
                m2 = 7'sd20;
                m1 = 7'sd8;
                m0 = -7'sd8;
                m_n1 = -7'sd22;
            end

            3'b111: begin
                m2 = 7'sd24;
                m1 = 7'sd8;
                m0 = -7'sd8;
                m_n1 = -7'sd22;
            end

            default: begin
                m2 = 7'sd12;
                m1 = 7'sd4;
                m0 = -7'sd4;
                m_n1 = -7'sd13;
            end
        endcase
    end

    always_comb begin
        if (rem_hi_q4_3 >= m2) begin
            digit_o = 3'sd2;
        end else if (rem_hi_q4_3 >= m1) begin
            digit_o = 3'sd1;
        end else if (rem_hi_q4_3 >= m0) begin
            digit_o = 3'sd0;
        end else if (rem_hi_q4_3 >= m_n1) begin
            digit_o = -3'sd1;
        end else begin
            digit_o = -3'sd2;
        end
    end

endmodule
