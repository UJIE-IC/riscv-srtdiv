module tb_rv32m_srt_divider;

    localparam logic [1:0] OP_DIV = 2'b00;
    localparam logic [1:0] OP_DIVU = 2'b01;
    localparam logic [1:0] OP_REM = 2'b10;
    localparam logic [1:0] OP_REMU = 2'b11;

    logic clk;
    logic rst_n;
    logic flush;
    logic req_valid;
    logic req_ready;
    logic [1:0] req_op;
    logic [31:0] req_rs1;
    logic [31:0] req_rs2;
    logic rsp_valid;
    logic rsp_ready;
    logic [31:0] rsp_result;
    logic rsp_div_by_zero;
    logic rsp_overflow;
    logic busy;

    int unsigned test_count;
    int unsigned error_count;

    rv32m_srt_divider_top u_dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .flush_i(flush),
        .req_valid_i(req_valid),
        .req_ready_o(req_ready),
        .req_op_i(req_op),
        .req_rs1_i(req_rs1),
        .req_rs2_i(req_rs2),
        .rsp_valid_o(rsp_valid),
        .rsp_ready_i(rsp_ready),
        .rsp_result_o(rsp_result),
        .rsp_div_by_zero_o(rsp_div_by_zero),
        .rsp_overflow_o(rsp_overflow),
        .busy_o(busy)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    function automatic logic [31:0] abs32(input logic [31:0] value);
        if (value[31]) begin
            abs32 = ~value + 32'd1;
        end else begin
            abs32 = value;
        end
    endfunction

    task automatic calc_ref(
        input logic [1:0] op,
        input logic [31:0] rs1,
        input logic [31:0] rs2,
        output logic [31:0] result,
        output logic div_by_zero,
        output logic overflow
    );
        logic is_signed;
        logic is_rem;
        logic rs1_neg;
        logic rs2_neg;
        logic quotient_neg;
        logic remainder_neg;
        logic [31:0] a_mag;
        logic [31:0] b_mag;
        logic [31:0] q_mag;
        logic [31:0] r_mag;

        is_signed = (op == OP_DIV) || (op == OP_REM);
        is_rem = (op == OP_REM) || (op == OP_REMU);
        div_by_zero = (rs2 == 32'h0000_0000);
        overflow = is_signed && (rs1 == 32'h8000_0000) && (rs2 == 32'hffff_ffff);

        if (div_by_zero) begin
            result = is_rem ? rs1 : 32'hffff_ffff;
        end else if (overflow) begin
            result = is_rem ? 32'h0000_0000 : 32'h8000_0000;
        end else begin
            rs1_neg = is_signed && rs1[31];
            rs2_neg = is_signed && rs2[31];
            quotient_neg = rs1_neg ^ rs2_neg;
            remainder_neg = rs1_neg;
            a_mag = rs1_neg ? abs32(rs1) : rs1;
            b_mag = rs2_neg ? abs32(rs2) : rs2;
            q_mag = a_mag / b_mag;
            r_mag = a_mag % b_mag;

            if (is_rem) begin
                result = remainder_neg ? (~r_mag + 32'd1) : r_mag;
            end else begin
                result = quotient_neg ? (~q_mag + 32'd1) : q_mag;
            end
        end
    endtask

    task automatic run_one(
        input logic [1:0] op,
        input logic [31:0] rs1,
        input logic [31:0] rs2
    );
        logic [31:0] expected_result;
        logic expected_div_by_zero;
        logic expected_overflow;

        calc_ref(op, rs1, rs2, expected_result, expected_div_by_zero, expected_overflow);

        @(posedge clk);
        req_valid <= 1'b1;
        req_op <= op;
        req_rs1 <= rs1;
        req_rs2 <= rs2;

        while (!req_ready) begin
            @(posedge clk);
        end

        @(posedge clk);
        req_valid <= 1'b0;
        req_op <= OP_DIV;
        req_rs1 <= 32'h0000_0000;
        req_rs2 <= 32'h0000_0000;

        while (!rsp_valid) begin
            @(posedge clk);
        end

        test_count++;

        if ((rsp_result !== expected_result)
                || (rsp_div_by_zero !== expected_div_by_zero)
                || (rsp_overflow !== expected_overflow)) begin
            error_count++;
            $display("FAIL op=%0d rs1=%08h rs2=%08h got=%08h dbz=%0b ovf=%0b exp=%08h exp_dbz=%0b exp_ovf=%0b",
                op,
                rs1,
                rs2,
                rsp_result,
                rsp_div_by_zero,
                rsp_overflow,
                expected_result,
                expected_div_by_zero,
                expected_overflow);
        end

        @(posedge clk);
    endtask

    initial begin
        rst_n = 1'b0;
        flush = 1'b0;
        req_valid = 1'b0;
        req_op = OP_DIV;
        req_rs1 = 32'h0000_0000;
        req_rs2 = 32'h0000_0000;
        rsp_ready = 1'b1;
        test_count = 0;
        error_count = 0;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        run_one(OP_DIVU, 32'd100, 32'd3);
        run_one(OP_REMU, 32'd100, 32'd3);
        run_one(OP_DIV, 32'hffff_fff6, 32'd3);
        run_one(OP_REM, 32'hffff_fff6, 32'd3);
        run_one(OP_DIV, 32'd10, 32'hffff_fffa);
        run_one(OP_REM, 32'd10, 32'hffff_fffa);
        run_one(OP_DIV, 32'h8000_0000, 32'hffff_ffff);
        run_one(OP_REM, 32'h8000_0000, 32'hffff_ffff);
        run_one(OP_DIVU, 32'hffff_ffff, 32'd1);
        run_one(OP_DIVU, 32'hffff_ffff, 32'd3);
        run_one(OP_DIV, 32'd1234, 32'd0);
        run_one(OP_REM, 32'hffff_1234, 32'd0);
        run_one(OP_DIVU, 32'd5, 32'd10);
        run_one(OP_REMU, 32'd5, 32'd10);

        for (int i = 0; i < 2000; i++) begin
            run_one($urandom_range(0, 3), $urandom, $urandom);
        end

        if (error_count == 0) begin
            $display("PASS %0d tests", test_count);
        end else begin
            $display("FAIL %0d / %0d tests", error_count, test_count);
        end

        $finish;
    end

endmodule
