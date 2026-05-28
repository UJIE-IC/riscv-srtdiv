module rv32m_srt_core (
    input logic clk_i,
    input logic rst_ni,
    input logic flush_i,
    input logic start_i,
    input logic [31:0] dividend_i,
    input logic [31:0] divisor_i,
    output logic done_o,
    output logic [31:0] quotient_o,
    output logic [31:0] remainder_o
);

    localparam int OTF_WIDTH = 33;
    localparam int REM_INT_BITS = 4;
    localparam int REM_FRAC_BITS = 31;
    localparam int REM_WIDTH = REM_INT_BITS + REM_FRAC_BITS;

    typedef enum logic [1:0] {
        ST_IDLE,
        ST_ITERATE,
        ST_CORRECT,
        ST_POST
    } state_e;

    state_e state_q;

    logic [31:0] dividend_q;
    logic [31:0] divisor_q;
    logic [31:0] dividend_norm;
    logic [31:0] divisor_norm;
    logic [5:0] dividend_lz;
    logic [5:0] divisor_lz;
    logic [6:0] exponent_disp_d;
    logic [5:0] exponent_d;
    logic [5:0] radix4_frac_digits_d;
    logic [5:0] total_digits_d;
    logic disp_zero_d;
    logic shift_down_q;
    logic [5:0] divisor_lz_q;

    // partial remainder 使用 Q4.31，并拆成 WS/WC carry-save 分量
    logic signed [REM_WIDTH-1:0] rem_sum_q;
    logic signed [REM_WIDTH-1:0] rem_carry_q;
    logic signed [REM_WIDTH-1:0] rem_sum_next;
    logic signed [REM_WIDTH-1:0] rem_carry_next;
    logic signed [REM_WIDTH-1:0] rem_sum_iter_d;
    logic signed [REM_WIDTH-1:0] rem_carry_iter_d;
    logic signed [REM_WIDTH-1:0] csa_sum;
    logic signed [REM_WIDTH-1:0] csa_carry;
    logic signed [REM_WIDTH-1:0] divisor_norm_q;
    logic signed [REM_WIDTH-1:0] divisor_addend;
    logic signed [2:0] digit;
    logic signed [2:0] digit_eff;

    logic [5:0] iter_left_q;
    logic final_iter;
    logic [OTF_WIDTH-1:0] q_otf_q;
    logic [OTF_WIDTH-1:0] qm_otf_q;
    logic [OTF_WIDTH-1:0] q_otf_next;
    logic [OTF_WIDTH-1:0] qm_otf_next;

    logic signed [REM_WIDTH-1:0] residual_d;
    logic signed [REM_WIDTH-1:0] residual_q;
    logic residual_negative_d;
    logic residual_negative_q;

    logic [31:0] quotient_post;
    logic [31:0] remainder_post;
    logic done_q;

    rv32m_srt_lzc u_lzc_dividend (
        .data_i(dividend_i),
        .lz_o(dividend_lz),
        .msb_o()
    );

    rv32m_srt_lzc u_lzc_divisor (
        .data_i(divisor_i),
        .lz_o(divisor_lz),
        .msb_o()
    );

    rv32m_srt_qds_radix4 #(
        .REM_WIDTH(REM_WIDTH),
        .REM_FRAC_BITS(REM_FRAC_BITS)
    ) u_qds (
        .rem_sum_i(rem_sum_q),
        .rem_carry_i(rem_carry_q),
        .divisor_norm_i(divisor_norm_q[31:0]),
        .digit_o(digit)
    );

    rv32m_srt_csa #(
        .WIDTH(REM_WIDTH)
    ) u_residual_csa (
        .a_i(rem_sum_q),
        .b_i(rem_carry_q),
        .c_i(divisor_addend),
        .sum_o(csa_sum),
        .carry_o(csa_carry)
    );

    rv32m_srt_otf #(
        .WIDTH(OTF_WIDTH)
    ) u_otf (
        .q_i(q_otf_q),
        .qm_i(qm_otf_q),
        .digit_i(digit_eff),
        .q_o(q_otf_next),
        .qm_o(qm_otf_next)
    );

    rv32m_srt_postprocess #(
        .REM_WIDTH(REM_WIDTH),
        .OTF_WIDTH(OTF_WIDTH)
    ) u_postprocess (
        .residual_i(residual_q),
        .residual_negative_i(residual_negative_q),
        .divisor_norm_i(divisor_norm_q),
        .q_otf_i(q_otf_q),
        .qm_otf_i(qm_otf_q),
        .shift_down_i(shift_down_q),
        .remainder_shift_i(divisor_lz_q),
        .quotient_o(quotient_post),
        .remainder_o(remainder_post)
    );

    // exp_disp = dvr_lz - dvd_lz，符号位为 1 时商为 0
    assign exponent_disp_d = {1'b0, divisor_lz} - {1'b0, dividend_lz};
    assign exponent_d = exponent_disp_d[5:0];
    assign disp_zero_d = exponent_disp_d[6];

    // 迭代次数为 ceil(e / 2) + 1
    assign radix4_frac_digits_d = (exponent_d + 6'd1) >> 1;
    assign total_digits_d = radix4_frac_digits_d + 6'd1;

    assign dividend_norm = dividend_i << dividend_lz[4:0];
    assign divisor_norm = divisor_i << divisor_lz[4:0];
    assign final_iter = (iter_left_q == 6'd1);

    // e 为奇数时，最后 digit 从 q4 折叠成 q_keep = 2*q1
    always_comb begin
        digit_eff = digit;

        if (final_iter && shift_down_q) begin
            if (digit > 3'sd0) begin
                digit_eff = 3'sd2;
            end else if (digit < 3'sd0) begin
                digit_eff = -3'sd2;
            end else begin
                digit_eff = 3'sd0;
            end
        end
    end

    always_comb begin
        unique case (digit_eff)
            3'sd2: begin
                divisor_addend = -(divisor_norm_q << 1);
            end

            3'sd1: begin
                divisor_addend = -divisor_norm_q;
            end

            3'sd0: begin
                divisor_addend = '0;
            end

            -3'sd1: begin
                divisor_addend = divisor_norm_q;
            end

            -3'sd2: begin
                divisor_addend = divisor_norm_q << 1;
            end

            default: begin
                divisor_addend = '0;
            end
        endcase
    end

    assign rem_sum_next = csa_sum << 2;
    assign rem_carry_next = csa_carry << 2;
    assign rem_sum_iter_d = (iter_left_q == 6'd1) ? csa_sum : rem_sum_next;
    assign rem_carry_iter_d = (iter_left_q == 6'd1) ? csa_carry : rem_carry_next;

    // ST_CORRECT 把 carry-save residual 合成为 residual。
    assign residual_d = rem_sum_q + rem_carry_q;
    assign residual_negative_d = residual_d[REM_WIDTH-1];
    assign done_o = done_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q <= ST_IDLE;
            dividend_q <= 32'h0000_0000;
            divisor_q <= 32'h0000_0000;
            divisor_norm_q <= '0;
            rem_sum_q <= '0;
            rem_carry_q <= '0;
            residual_q <= '0;
            residual_negative_q <= 1'b0;
            iter_left_q <= 6'd0;
            shift_down_q <= 1'b0;
            divisor_lz_q <= 6'd0;
            q_otf_q <= '0;
            qm_otf_q <= '1;
            quotient_o <= 32'h0000_0000;
            remainder_o <= 32'h0000_0000;
            done_q <= 1'b0;
        end else if (flush_i) begin
            state_q <= ST_IDLE;
            rem_sum_q <= '0;
            rem_carry_q <= '0;
            residual_q <= '0;
            residual_negative_q <= 1'b0;
            iter_left_q <= 6'd0;
            shift_down_q <= 1'b0;
            divisor_lz_q <= 6'd0;
            q_otf_q <= '0;
            qm_otf_q <= '1;
            done_q <= 1'b0;
        end else begin
            done_q <= 1'b0;

            unique case (state_q)
                ST_IDLE: begin
                    if (start_i) begin
                        dividend_q <= dividend_i;
                        divisor_q <= divisor_i;

                        if (disp_zero_d) begin
                            quotient_o <= 32'h0000_0000;
                            remainder_o <= dividend_i;
                            done_q <= 1'b1;
                            state_q <= ST_IDLE;
                        end else begin
                            divisor_norm_q <= {{(REM_WIDTH-32){1'b0}}, divisor_norm};
                            rem_sum_q <= {{(REM_WIDTH-32){1'b0}}, dividend_norm};
                            rem_carry_q <= '0;
                            residual_q <= '0;
                            residual_negative_q <= 1'b0;
                            iter_left_q <= total_digits_d;
                            shift_down_q <= exponent_d[0];
                            divisor_lz_q <= divisor_lz;
                            q_otf_q <= '0;
                            qm_otf_q <= '1;
                            state_q <= ST_ITERATE;
                        end
                    end
                end

                ST_ITERATE: begin
                    rem_sum_q <= rem_sum_iter_d;
                    rem_carry_q <= rem_carry_iter_d;
                    q_otf_q <= q_otf_next;
                    qm_otf_q <= qm_otf_next;

                    if (iter_left_q == 6'd1) begin
                        iter_left_q <= 6'd0;
                        state_q <= ST_CORRECT;
                    end else begin
                        iter_left_q <= iter_left_q - 6'd1;
                    end
                end

                ST_CORRECT: begin
                    residual_q <= residual_d;
                    residual_negative_q <= residual_negative_d;
                    state_q <= ST_POST;
                end

                ST_POST: begin
                    quotient_o <= quotient_post;
                    remainder_o <= remainder_post;
                    done_q <= 1'b1;
                    state_q <= ST_IDLE;
                end

                default: begin
                    state_q <= ST_IDLE;
                end
            endcase
        end
    end

endmodule
