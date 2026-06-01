# Step 05 — Instruction and data memory

A CPU needs somewhere to fetch instructions from and somewhere to keep data.
In this step we build both. After this we have every *storage* element the
machine needs; the remaining steps are about decoding and wiring.

Files for this step:
- `rtl/imem.v` — instruction memory (read-only)
- `rtl/dmem.v` — data memory (read/write)
- `sw/test_imem.hex` — a tiny hex file to test loading
- `tb/imem_tb.v`, `tb/dmem_tb.v` — testbenches

We keep instruction and data memory as **separate** blocks. A single-cycle CPU
must fetch an instruction *and* possibly access data in the same cycle, so two
independent memories (a "Harvard" arrangement in simulation) is the simplest
thing that works.

---

## Part A — Instruction memory

The PC hands instruction memory a **byte address**; it returns the 32-bit
instruction stored there. Two facts drive the design:

- Instructions are 4 bytes and word-aligned, so consecutive instructions live
  at byte addresses 0, 4, 8, ... The word index is therefore `addr >> 2`
  (drop the low 2 bits).
- The read is combinational — fetch has to complete within the cycle.

```verilog
module imem #(
    parameter WORDS = 256,
    parameter INIT_FILE = ""
) (
    input  wire [31:0] addr,
    output wire [31:0] instr
);
    localparam IDX = $clog2(WORDS);
    reg [31:0] mem [0:WORDS-1];

    integer i;
    initial begin
        for (i = 0; i < WORDS; i = i + 1) mem[i] = 32'd0;
        if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    end

    wire [IDX-1:0] word_index = addr[IDX+1:2];
    assign instr = mem[word_index];
endmodule
```

### New ideas here

- **Parameters with `#(...)`**: `WORDS` (capacity) and `INIT_FILE` (which hex
  file to preload) are module parameters. The testbench overrides them at
  instantiation: `imem #(.WORDS(256), .INIT_FILE("sw/test_imem.hex")) dut(...)`.
  Parameters let one module serve many sizes/configs.

- **`$clog2(WORDS)`**: a compile-time function giving the ceiling of log2 — the
  number of address bits needed to index `WORDS` entries. With `WORDS=256` it's
  8, so the word index is `addr[9:2]` (8 bits, after dropping the low 2).

- **`$readmemh(file, mem)`**: at time 0 this reads a text file of hex values,
  one per line, into consecutive elements of `mem`. This is the bridge between
  software and hardware: in Step 08 we'll assemble a RISC-V program into exactly
  this format and load it the same way. Each line is one 32-bit instruction.

### About that `$readmemh` warning

When the hex file has fewer words than the array (almost always — programs are
small, memory is generously sized), Icarus prints:

```
WARNING: ... Not enough words in the file for the requested range [0:255].
```

This is **informational, not an error**. `$readmemh` fills the locations it has
data for; the rest keep the zeros we pre-loaded with the `initial` loop (an
all-zero word happens to be an illegal-ish instruction, which is fine for
unused space). You'll see this warning with every real program; ignore it.

### Test it

```bash
iverilog -g2012 -Wall -o build/imem_tb.vvp rtl/imem.v tb/imem_tb.v
vvp build/imem_tb.vvp
```

The test loads four words from `sw/test_imem.hex` and fetches them at byte
addresses 0, 4, 8, 12, plus one unloaded address that reads back as zero:

```
ok   pc=00000000 -> deadbeef
ok   pc=00000004 -> 00000013      <- this word is actually a NOP: addi x0,x0,0
ok   pc=00000008 -> cafef00d
ok   pc=0000000c -> 12345678
ok   pc=00000010 -> 00000000      <- unloaded location
ALL TESTS PASSED
```

---

## Part B — Data memory

Data memory is read/write and must serve every RV32I load/store width. RISC-V
is **little-endian**: the byte at the lowest address is the least significant.
The width and signedness come from the instruction's `funct3` field:

| `funct3` | Load | Store | Meaning |
|----------|------|-------|---------|
| `000` | LB  | SB | byte, sign-extended on load |
| `001` | LH  | SH | half-word (2 bytes), sign-extended |
| `010` | LW  | SW | word (4 bytes) |
| `100` | LBU | —  | byte, zero-extended |
| `101` | LHU | —  | half-word, zero-extended |

We store memory as a **byte array** so byte/half/word accesses are natural:

```verilog
reg [7:0] mem [0:BYTES-1];

wire [ABITS-1:0] a = addr[ABITS-1:0];
wire [7:0]  b0 = mem[a],  b1 = mem[a+1], b2 = mem[a+2], b3 = mem[a+3];
wire [15:0] half = {b1, b0};            // little-endian assembly
wire [31:0] word = {b3, b2, b1, b0};
```

**Combinational read** with sign/zero extension:

```verilog
always @(*) begin
    case (funct3)
        3'b000 : rdata = {{24{b0[7]}},   b0};    // LB  sign-extend
        3'b001 : rdata = {{16{half[15]}}, half}; // LH  sign-extend
        3'b010 : rdata = word;                   // LW
        3'b100 : rdata = {24'd0, b0};            // LBU zero-extend
        3'b101 : rdata = {16'd0, half};          // LHU zero-extend
        default: rdata = word;
    endcase
end
```

The sign-extension idiom `{{24{b0[7]}}, b0}` replicates the byte's top bit
(`b0[7]`) 24 times and prepends it — that's exactly what "sign-extend a byte to
32 bits" means. Zero-extension just prepends literal zeros.

**Clocked write** of 1/2/4 bytes:

```verilog
always @(posedge clk)
    if (we) case (funct3)
        3'b000 : mem[a] <= wdata[7:0];                        // SB
        3'b001 : {mem[a+1], mem[a]} <= wdata[15:0];           // SH (shown expanded in RTL)
        3'b010 : {mem[a+3],mem[a+2],mem[a+1],mem[a]} <= wdata; // SW
        default: ; // not a store
    endcase
```

Read is combinational (the loaded value must be available within the cycle to
write back to a register); write is clocked (state changes on the edge) — the
same split you saw in the register file.

### Test it

```bash
iverilog -g2012 -Wall -o build/dmem_tb.vvp rtl/dmem.v tb/dmem_tb.v
vvp build/dmem_tb.vvp
```

The test stores a word `0xAABBCCDD` and then reads it back in every width to
prove endianness and extension are right:

```
ok   load f3=010 @00000000 -> aabbccdd   <- LW: whole word
ok   load f3=100 @00000000 -> 000000dd   <- LBU: lowest byte (little-endian)
ok   load f3=100 @00000003 -> 000000aa   <- LBU: highest byte
ok   load f3=000 @00000003 -> ffffffaa   <- LB:  0xAA sign-extends
ok   load f3=101 @00000002 -> 0000aabb   <- LHU: upper half
ok   load f3=001 @00000002 -> ffffaabb   <- LH:  sign-extends
...
ALL TESTS PASSED
```

That `0xDD` is at the lowest address while `0xAA` is at the highest is the
visible proof of little-endian storage. The `LB`/`LH` results show
sign-extension kicking in because `0xAA`/`0xAABB` have their top bit set.

## Look at it in GTKWave

```bash
gtkwave build/dmem_tb.vcd
```

Add `clk`, `we`, `addr`, `wdata`, `funct3`, `rdata`. Watch a store land on a
rising edge (when `we` is high), and watch `rdata` change combinationally as
you vary `addr`/`funct3` during the load checks. Expanding `dut` → `mem` lets
you see individual bytes change.

## Checkpoint

All storage now exists and is tested: register file (Step 04), instruction
memory, and data memory. New tools picked up: module parameters `#(...)`,
`$clog2`, `$readmemh` for program loading, little-endian byte assembly, and the
sign/zero-extension idioms.

## Next

`docs/06-immediate-and-control.md` — decoding. We'll build the immediate
generator (reassembling those scattered immediate bits into a usable 32-bit
constant) and the control unit (turning an opcode/funct into the control
signals that steer the datapath, including the ALU op codes from Step 03).
