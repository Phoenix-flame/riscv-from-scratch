// =====================================================================
// cpu.v  -  Single-cycle RV32I core (top-level datapath)
// ---------------------------------------------------------------------
// Wires together the six blocks built in Steps 03-06, plus the PC and
// the "glue": next-PC logic, the branch comparator, the ALU operand
// muxes, and the write-back mux. One instruction completes per clock.
// =====================================================================
`default_nettype none

module cpu #(
    parameter INIT_FILE = "",         // program hex for instruction memory
    parameter RESET_PC  = 32'h0000_0000
) (
    input  wire        clk,
    input  wire        rst,
    output wire [31:0] pc_out,        // debug: current PC
    output wire [31:0] instr_out      // debug: current instruction
);

    // -----------------------------------------------------------------
    // Program counter (the only architectural state besides regs/mem)
    // -----------------------------------------------------------------
    reg  [31:0] pc;
    wire [31:0] pc_plus4 = pc + 32'd4;
    reg  [31:0] next_pc;

    always @(posedge clk) begin
        if (rst) pc <= RESET_PC;
        else     pc <= next_pc;
    end

    assign pc_out = pc;

    // -----------------------------------------------------------------
    // Fetch: read the instruction at PC
    // -----------------------------------------------------------------
    wire [31:0] instr;
    assign instr_out = instr;

    imem #(.WORDS(1024), .INIT_FILE(INIT_FILE)) u_imem (
        .addr (pc),
        .instr(instr)
    );

    // -----------------------------------------------------------------
    // Decode: pull the fixed-position fields out of the instruction
    // -----------------------------------------------------------------
    wire [6:0] opcode  = instr[6:0];
    wire [4:0] rd_addr = instr[11:7];
    wire [2:0] funct3  = instr[14:12];
    wire [4:0] rs1_addr= instr[19:15];
    wire [4:0] rs2_addr= instr[24:20];
    wire       funct7b5= instr[30];

    // -----------------------------------------------------------------
    // Control unit: opcode/funct -> control signals
    // -----------------------------------------------------------------
    wire       reg_write, alu_src_a, alu_src_b, mem_read, mem_write;
    wire       branch, jump, jalr;
    wire [1:0] wb_sel;
    wire [2:0] imm_type;
    wire [3:0] alu_op;

    control u_control (
        .opcode(opcode), .funct3(funct3), .funct7b5(funct7b5),
        .reg_write(reg_write), .alu_src_a(alu_src_a), .alu_src_b(alu_src_b),
        .mem_read(mem_read), .mem_write(mem_write),
        .branch(branch), .jump(jump), .jalr(jalr),
        .wb_sel(wb_sel), .imm_type(imm_type), .alu_op(alu_op)
    );

    // -----------------------------------------------------------------
    // Immediate generator
    // -----------------------------------------------------------------
    wire [31:0] imm;
    immgen u_immgen (.instr(instr), .imm_type(imm_type), .imm(imm));

    // -----------------------------------------------------------------
    // Register file (write-back value `wb_data` defined further down)
    // -----------------------------------------------------------------
    wire [31:0] rs1_data, rs2_data;
    reg  [31:0] wb_data;

    regfile u_regfile (
        .clk(clk), .we(reg_write),
        .rs1_addr(rs1_addr), .rs2_addr(rs2_addr),
        .rd_addr(rd_addr),   .rd_data(wb_data),
        .rs1_data(rs1_data), .rs2_data(rs2_data)
    );

    // -----------------------------------------------------------------
    // ALU and its operand muxes
    //   A: rs1, or PC (for auipc)
    //   B: rs2, or the immediate
    // -----------------------------------------------------------------
    wire [31:0] alu_a = alu_src_a ? pc  : rs1_data;
    wire [31:0] alu_b = alu_src_b ? imm : rs2_data;
    wire [31:0] alu_result;
    wire        alu_zero;

    alu u_alu (
        .a(alu_a), .b(alu_b), .alu_op(alu_op),
        .result(alu_result), .zero(alu_zero)
    );

    // -----------------------------------------------------------------
    // Data memory (loads/stores). Address is the ALU result (rs1+imm).
    // -----------------------------------------------------------------
    wire [31:0] mem_rdata;

    dmem #(.BYTES(4096)) u_dmem (
        .clk(clk), .we(mem_write),
        .addr(alu_result), .wdata(rs2_data),
        .funct3(funct3), .rdata(mem_rdata)
    );

    // -----------------------------------------------------------------
    // Branch comparator: decide taken/not-taken from funct3
    // -----------------------------------------------------------------
    reg branch_cond;
    always @(*) begin
        case (funct3)
            3'b000 : branch_cond = (rs1_data == rs2_data);                 // beq
            3'b001 : branch_cond = (rs1_data != rs2_data);                 // bne
            3'b100 : branch_cond = ($signed(rs1_data) <  $signed(rs2_data)); // blt
            3'b101 : branch_cond = ($signed(rs1_data) >= $signed(rs2_data)); // bge
            3'b110 : branch_cond = (rs1_data <  rs2_data);                 // bltu
            3'b111 : branch_cond = (rs1_data >= rs2_data);                 // bgeu
            default: branch_cond = 1'b0;
        endcase
    end
    wire branch_taken = branch & branch_cond;

    // -----------------------------------------------------------------
    // Next-PC logic
    //   jalr    : (rs1 + imm) with bit 0 cleared   (ALU already did rs1+imm)
    //   jal     : PC + imm
    //   branch  : PC + imm if taken
    //   default : PC + 4
    // -----------------------------------------------------------------
    wire [31:0] pc_target   = pc + imm;                 // jal & branches
    wire [31:0] jalr_target = {alu_result[31:1], 1'b0}; // clear LSB

    always @(*) begin
        if (jalr)             next_pc = jalr_target;
        else if (jump)        next_pc = pc_target;      // jal
        else if (branch_taken)next_pc = pc_target;
        else                  next_pc = pc_plus4;
    end

    // -----------------------------------------------------------------
    // Write-back mux: choose what gets written into rd
    // -----------------------------------------------------------------
    localparam WB_ALU=2'b00, WB_MEM=2'b01, WB_PC4=2'b10, WB_IMM=2'b11;
    always @(*) begin
        case (wb_sel)
            WB_ALU : wb_data = alu_result;
            WB_MEM : wb_data = mem_rdata;
            WB_PC4 : wb_data = pc_plus4;     // return address for jal/jalr
            WB_IMM : wb_data = imm;          // lui
            default: wb_data = alu_result;
        endcase
    end

endmodule

`default_nettype wire
