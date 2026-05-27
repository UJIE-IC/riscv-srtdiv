module rv32m_srt_divider_top (
    input logic clk_i,
    input logic rst_ni,

    // 取消当前在途请求。后续接入 CPU 流水线时，分支恢复、异常恢复
    // 或全局 flush 都可以通过这个信号杀掉当前除法操作。
    input logic flush_i,

    // 请求通道：req_valid_i && req_ready_o 为 1 时接收一条新请求。
    input logic req_valid_i,
    output logic req_ready_o,
    input logic [1:0] req_op_i,
    input logic [31:0] req_rs1_i,
    input logic [31:0] req_rs2_i,

    // 响应通道：rsp_valid_o && rsp_ready_i 为 1 时结果被下游接收。
    output logic rsp_valid_o,
    input logic rsp_ready_i,
    output logic [31:0] rsp_result_o,

    // 仅作为调试/验证状态。RV32M 的除 0 和有符号溢出不会触发 trap。
    output logic rsp_div_by_zero_o,
    output logic rsp_overflow_o,

    output logic busy_o
);

    // RV32M 除法类指令编码。
    localparam logic [1:0] OP_DIV = 2'b00;
    localparam logic [1:0] OP_DIVU = 2'b01;
    localparam logic [1:0] OP_REM = 2'b10;
    localparam logic [1:0] OP_REMU = 2'b11;

    // 顶层只做请求分发、特殊情况处理和结果返回；SRT 细节放在 core 中。
    typedef enum logic [1:0] {
        ST_IDLE,
        ST_DISPATCH,
        ST_WAIT_CORE,
        ST_OUTPUT
    } state_e;

    state_e state_q;
    state_e state_d;

    logic [31:0] rs1_q;
    logic [31:0] dividend_mag_q;
    logic [31:0] divisor_mag_q;
    logic result_is_rem_q;
    logic quotient_neg_q;
    logic remainder_neg_q;
    logic div_by_zero_q;
    logic overflow_q;

    logic [31:0] result_q;
    logic [31:0] result_d;
    logic result_div_by_zero_q;
    logic result_div_by_zero_d;
    logic result_overflow_q;
    logic result_overflow_d;

    logic req_fire;
    logic rsp_fire;

    logic req_is_signed;
    logic req_is_rem;
    logic req_rs1_neg;
    logic req_rs2_neg;
    logic [31:0] req_rs1_mag;
    logic [31:0] req_rs2_mag;
    logic req_div_by_zero;
    logic req_overflow;

    logic [31:0] special_result;

    logic core_start;
    logic core_done;
    logic [31:0] core_quotient_mag;
    logic [31:0] core_remainder_mag;

    logic [31:0] signed_quotient;
    logic [31:0] signed_remainder;
    logic [31:0] normal_result;

    assign req_ready_o = (state_q == ST_IDLE) && !flush_i;
    assign rsp_valid_o = (state_q == ST_OUTPUT) && !flush_i;
    assign busy_o = (state_q != ST_IDLE) && !flush_i;

    assign rsp_result_o = result_q;
    assign rsp_div_by_zero_o = result_div_by_zero_q;
    assign rsp_overflow_o = result_overflow_q;

    assign req_fire = req_valid_i && req_ready_o;
    assign rsp_fire = rsp_valid_o && rsp_ready_i;

    // 有符号指令先取绝对值，core 只处理无符号幅值。
    assign req_is_signed = (req_op_i == OP_DIV) || (req_op_i == OP_REM);
    assign req_is_rem = (req_op_i == OP_REM) || (req_op_i == OP_REMU);
    assign req_rs1_neg = req_is_signed && req_rs1_i[31];
    assign req_rs2_neg = req_is_signed && req_rs2_i[31];

    assign req_rs1_mag = req_rs1_neg ? (~req_rs1_i + 32'd1) : req_rs1_i;
    assign req_rs2_mag = req_rs2_neg ? (~req_rs2_i + 32'd1) : req_rs2_i;

    // RV32M 对除 0 和 signed overflow 规定了固定返回值，不进入 SRT 迭代。
    assign req_div_by_zero = (req_rs2_i == 32'h0000_0000);
    assign req_overflow = req_is_signed
        && (req_rs1_i == 32'h8000_0000)
        && (req_rs2_i == 32'hffff_ffff);

    always_comb begin
        special_result = 32'h0000_0000;

        if (div_by_zero_q) begin
            special_result = result_is_rem_q ? rs1_q : 32'hffff_ffff;
        end else if (overflow_q) begin
            special_result = result_is_rem_q ? 32'h0000_0000 : 32'h8000_0000;
        end
    end

    // core 输出的是正数商/余数幅值，顶层根据 RV32M 指令语义恢复符号。
    assign signed_quotient = quotient_neg_q ? (~core_quotient_mag + 32'd1) : core_quotient_mag;
    assign signed_remainder = remainder_neg_q ? (~core_remainder_mag + 32'd1) : core_remainder_mag;
    assign normal_result = result_is_rem_q ? signed_remainder : signed_quotient;

    // SRT core 只接收正数幅值。core 内部负责：
    // 1. 对被除数和除数做归一化；
    // 2. 计算 q_bits = msb(dividend) - msb(divisor) + 1；
    // 3. 使用论文 Table VI 的 radix-4 选商表产生 q in {-2,-1,0,+1,+2}；
    // 4. 使用 on-the-fly conversion 更新 Q/QM；
    // 5. 当 q_bits 为奇数时，用 q4 -> q1 规则折叠最后 1 个商位。
    rv32m_srt_core u_core (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .flush_i(flush_i),
        .start_i(core_start),
        .dividend_i(dividend_mag_q),
        .divisor_i(divisor_mag_q),
        .done_o(core_done),
        .quotient_o(core_quotient_mag),
        .remainder_o(core_remainder_mag)
    );

    always_comb begin
        state_d = state_q;
        result_d = result_q;
        result_div_by_zero_d = result_div_by_zero_q;
        result_overflow_d = result_overflow_q;
        core_start = 1'b0;

        if (flush_i) begin
            state_d = ST_IDLE;
        end else begin
            unique case (state_q)
                ST_IDLE: begin
                    if (req_fire) begin
                        state_d = ST_DISPATCH;
                    end
                end

                ST_DISPATCH: begin
                    if (div_by_zero_q || overflow_q) begin
                        result_d = special_result;
                        result_div_by_zero_d = div_by_zero_q;
                        result_overflow_d = overflow_q;
                        state_d = ST_OUTPUT;
                    end else begin
                        core_start = 1'b1;
                        state_d = ST_WAIT_CORE;
                    end
                end

                ST_WAIT_CORE: begin
                    if (core_done) begin
                        result_d = normal_result;
                        result_div_by_zero_d = 1'b0;
                        result_overflow_d = 1'b0;
                        state_d = ST_OUTPUT;
                    end
                end

                ST_OUTPUT: begin
                    if (rsp_fire) begin
                        state_d = ST_IDLE;
                    end
                end

                default: begin
                    state_d = ST_IDLE;
                end
            endcase
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q <= ST_IDLE;
            rs1_q <= 32'h0000_0000;
            dividend_mag_q <= 32'h0000_0000;
            divisor_mag_q <= 32'h0000_0000;
            result_is_rem_q <= 1'b0;
            quotient_neg_q <= 1'b0;
            remainder_neg_q <= 1'b0;
            div_by_zero_q <= 1'b0;
            overflow_q <= 1'b0;
            result_q <= 32'h0000_0000;
            result_div_by_zero_q <= 1'b0;
            result_overflow_q <= 1'b0;
        end else if (flush_i) begin
            state_q <= ST_IDLE;
            result_q <= 32'h0000_0000;
            result_div_by_zero_q <= 1'b0;
            result_overflow_q <= 1'b0;
        end else begin
            state_q <= state_d;
            result_q <= result_d;
            result_div_by_zero_q <= result_div_by_zero_d;
            result_overflow_q <= result_overflow_d;

            if (req_fire) begin
                rs1_q <= req_rs1_i;
                dividend_mag_q <= req_rs1_mag;
                divisor_mag_q <= req_rs2_mag;
                result_is_rem_q <= req_is_rem;
                quotient_neg_q <= req_rs1_neg ^ req_rs2_neg;
                remainder_neg_q <= req_rs1_neg;
                div_by_zero_q <= req_div_by_zero;
                overflow_q <= req_overflow;
            end
        end
    end

endmodule
