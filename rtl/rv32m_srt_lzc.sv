module rv32m_srt_lzc (
    input logic [31:0] data_i,
    output logic [5:0] lz_o,
    output logic [5:0] msb_o
);

    integer i;
    logic found;

    always_comb begin
        lz_o = 6'd32;
        msb_o = 6'd0;
        found = 1'b0;

        for (i = 31; i >= 0; i = i - 1) begin
            if (!found && data_i[i]) begin
                lz_o = 31 - i;
                msb_o = i;
                found = 1'b1;
            end
        end
    end

endmodule
