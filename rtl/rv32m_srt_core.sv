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

    localparam int OTF_WIDTH = 36;

    typedef enum logic [1:0] {
        ST_IDLE,
        ST_ITERATE,
        ST_POST
    } state_e;

    state_e state_q;

    logic [31:0] dividend_q;
    logic [31:0] divisor_q;
    logic [31:0] dividend_norm;
    logic [31:0] divisor_norm;
    logic [5:0] dividend_lz;
    logic [5:0] divisor_lz;
    logic [5:0] dividend_msb;
    logic [5:0] divisor_msb;
    logic [5:0] exponent_d;
    logic [5:0] radix4_frac_digits_d;
    logic [5:0] total_digits_d;
    logic shift_down_q;

    logic signed [39:0] rem_q;
    logic signed [39:0] rem_next;
    logic signed [39:0] divisor_norm_q;
    logic signed [39:0] divisor_multiple;
    logic signed [2:0] digit;

    logic [5:0] iter_left_q;
    logic [OTF_WIDTH-1:0] q_otf_q;
    logic [OTF_WIDTH-1:0] qm_otf_q;
    logic [OTF_WIDTH-1:0] q_otf_next;
    logic [OTF_WIDTH-1:0] qm_otf_next;

    logic [33:0] quotient_raw;
    logic [31:0] quotient_post;
    logic [31:0] remainder_post;
    logic done_q;

    rv32m_srt_lzc u_lzc_dividend (
        .data_i(dividend_i),
        .lz_o(dividend_lz)
    );

    rv32m_srt_lzc u_lzc_divisor (
        .data_i(divisor_i),
        .lz_o(divisor_lz)
    );

    rv32m_srt_qds_radix4 u_qds (
        .rem_i(rem_q),
        .divisor_norm_i(divisor_norm_q[31:0]),
        .digit_o(digit)
    );

    rv32m_srt_otf #(
        .WIDTH(OTF_WIDTH)
    ) u_otf (
        .q_i(q_otf_q),
        .qm_i(qm_otf_q),
        .digit_i(digit),
        .q_o(q_otf_next),
        .qm_o(qm_otf_next)
    );

    rv32m_srt_postprocess u_postprocess (
        .dividend_i(dividend_q),
        .divisor_i(divisor_q),
        .quotient_raw_i(quotient_raw),
        .quotient_o(quotient_post),
        .remainder_o(remainder_post)
    );

    assign dividend_msb = 6'd31 - dividend_lz;
    assign divisor_msb = 6'd31 - divisor_lz;
    assign exponent_d = dividend_msb - divisor_msb;
    assign radix4_frac_digits_d = (exponent_d + 6'd1) >> 1;
    assign total_digits_d = radix4_frac_digits_d + 6'd1;

    assign dividend_norm = dividend_i << dividend_lz[4:0];
    assign divisor_norm = divisor_i << divisor_lz[4:0];

    always_comb begin
        unique case (digit)
            3'sd2: begin
                divisor_multiple = divisor_norm_q <<< 1;
            end

            3'sd1: begin
                divisor_multiple = divisor_norm_q;
            end

            3'sd0: begin
                divisor_multiple = 40'sd0;
            end

            -3'sd1: begin
                divisor_multiple = -divisor_norm_q;
            end

            -3'sd2: begin
                divisor_multiple = -(divisor_norm_q <<< 1);
            end

            default: begin
                divisor_multiple = 40'sd0;
            end
        endcase
    end

    assign rem_next = (rem_q - divisor_multiple) <<< 2;
    assign quotient_raw = shift_down_q ? (q_otf_q[33:0] >> 1) : q_otf_q[33:0];
    assign done_o = done_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q <= ST_IDLE;
            dividend_q <= 32'h0000_0000;
            divisor_q <= 32'h0000_0000;
            divisor_norm_q <= 40'sd0;
            rem_q <= 40'sd0;
            iter_left_q <= 6'd0;
            shift_down_q <= 1'b0;
            q_otf_q <= '0;
            qm_otf_q <= '1;
            quotient_o <= 32'h0000_0000;
            remainder_o <= 32'h0000_0000;
            done_q <= 1'b0;
        end else if (flush_i) begin
            state_q <= ST_IDLE;
            rem_q <= 40'sd0;
            iter_left_q <= 6'd0;
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
                        divisor_norm_q <= {8'd0, divisor_norm};
                        rem_q <= {8'd0, dividend_norm};
                        iter_left_q <= total_digits_d;
                        shift_down_q <= exponent_d[0];
                        q_otf_q <= '0;
                        qm_otf_q <= '1;
                        state_q <= ST_ITERATE;
                    end
                end

                ST_ITERATE: begin
                    rem_q <= rem_next;
                    q_otf_q <= q_otf_next;
                    qm_otf_q <= qm_otf_next;

                    if (iter_left_q == 6'd1) begin
                        iter_left_q <= 6'd0;
                        state_q <= ST_POST;
                    end else begin
                        iter_left_q <= iter_left_q - 6'd1;
                    end
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
