module rv32m_srt_otf #(
    parameter int WIDTH = 36
) (
    input logic [WIDTH-1:0] q_i,
    input logic [WIDTH-1:0] qm_i,
    input logic signed [2:0] digit_i,
    output logic [WIDTH-1:0] q_o,
    output logic [WIDTH-1:0] qm_o
);

    logic [WIDTH-1:0] inject_1;
    logic [WIDTH-1:0] inject_2;
    logic [WIDTH-1:0] inject_3;

    assign inject_1 = {{(WIDTH-2){1'b0}}, 2'b01};
    assign inject_2 = {{(WIDTH-2){1'b0}}, 2'b10};
    assign inject_3 = {{(WIDTH-2){1'b0}}, 2'b11};

    always_comb begin
        q_o = q_i;
        qm_o = qm_i;

        unique case (digit_i)
            3'sd2: begin
                q_o = (q_i << 2) | inject_2;
                qm_o = (q_i << 2) | inject_1;
            end

            3'sd1: begin
                q_o = (q_i << 2) | inject_1;
                qm_o = q_i << 2;
            end

            3'sd0: begin
                q_o = q_i << 2;
                qm_o = (qm_i << 2) | inject_3;
            end

            -3'sd1: begin
                q_o = (qm_i << 2) | inject_3;
                qm_o = (qm_i << 2) | inject_2;
            end

            -3'sd2: begin
                q_o = (qm_i << 2) | inject_2;
                qm_o = (qm_i << 2) | inject_1;
            end

            default: begin
                q_o = q_i << 2;
                qm_o = (qm_i << 2) | inject_3;
            end
        endcase
    end

endmodule
