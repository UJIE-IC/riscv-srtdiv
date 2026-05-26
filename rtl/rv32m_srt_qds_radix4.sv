module rv32m_srt_qds_radix4 (
    input logic signed [39:0] rem_i,
    input logic [31:0] divisor_norm_i,
    output logic signed [2:0] digit_o
);

    logic [2:0] divisor_index;
    logic signed [7:0] rem_hi_q4_3;
    logic signed [7:0] m2;
    logic signed [7:0] m1;
    logic signed [7:0] m0;
    logic signed [7:0] m_n1;

    assign divisor_index = divisor_norm_i[30:28];
    assign rem_hi_q4_3 = rem_i >>> 28;

    always_comb begin
        m2 = 8'sd12;
        m1 = 8'sd4;
        m0 = -8'sd4;
        m_n1 = -8'sd13;

        unique case (divisor_index)
            3'b000: begin
                m2 = 8'sd12;
                m1 = 8'sd4;
                m0 = -8'sd4;
                m_n1 = -8'sd13;
            end

            3'b001: begin
                m2 = 8'sd14;
                m1 = 8'sd4;
                m0 = -8'sd4;
                m_n1 = -8'sd14;
            end

            3'b010: begin
                m2 = 8'sd16;
                m1 = 8'sd4;
                m0 = -8'sd6;
                m_n1 = -8'sd16;
            end

            3'b011: begin
                m2 = 8'sd16;
                m1 = 8'sd4;
                m0 = -8'sd6;
                m_n1 = -8'sd17;
            end

            3'b100: begin
                m2 = 8'sd18;
                m1 = 8'sd6;
                m0 = -8'sd6;
                m_n1 = -8'sd18;
            end

            3'b101: begin
                m2 = 8'sd20;
                m1 = 8'sd6;
                m0 = -8'sd8;
                m_n1 = -8'sd20;
            end

            3'b110: begin
                m2 = 8'sd20;
                m1 = 8'sd8;
                m0 = -8'sd8;
                m_n1 = -8'sd22;
            end

            3'b111: begin
                m2 = 8'sd24;
                m1 = 8'sd8;
                m0 = -8'sd8;
                m_n1 = -8'sd22;
            end

            default: begin
                m2 = 8'sd12;
                m1 = 8'sd4;
                m0 = -8'sd4;
                m_n1 = -8'sd13;
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
