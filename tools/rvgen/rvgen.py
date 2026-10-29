#!/usr/bin/env python3
"""rvgen - turn a Kconfig .config into an OpenZynq project (Step 45).

    python3 tools/rvgen/rvgen.py [--config .config] [--out build/oz]
                                 [--oz /path/to/OpenZynq] [--sim] [--force]

Reads the configuration made by `make menuconfig`, builds the self-test
firmware for exactly that core, and writes a self-contained OpenZynq PL
project:

    <out>/projects/<name>/
        project.mk          TOP / SRCS / SIM_TOP / SIM_SRCS / XDC / SYNTH_OPTS
        <name>_top.v        synthesis top: pins (standalone) or PS7 + core (PS)
        <name>.v            PS builds: the core + AXI bridge, simulated without PS7
        <name>.xdc          clock, reset, LEDs (+ UART TX pin, buttons)
        tb_<sim top>.v      runs the firmware, checks "ALL PASS" + exit code 0
        rtl/                exactly the RTL this configuration needs
        fw/firmware.hex     the program (one 32-bit word per line)
        ps/                 PS builds: the Cortex-A9 loader / console relay
        rvconfig            the .config it was generated from
        README.md           what was configured, how to build and run it

--oz copies that directory into an OpenZynq checkout (projects/<name>/).
--sim simulates it the way OpenZynq's `make sim` would, from <out>.
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import zlib

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(REPO, "tools", "kconfig"))
import kconfiglib  # noqa: E402  (vendored, tools/kconfig/)

CROSS = "riscv64-unknown-elf-"
PL_CLK_HZ = 50_000_000          # Mitra-7010 PL oscillator (Y2 -> U18)
MARKER = ".rvgen"               # marks a directory this tool generated


def die(msg):
    sys.exit("rvgen: error: " + msg)


def run(cmd, cwd=None):
    r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if r.returncode:
        die("command failed: %s\n%s%s" % (" ".join(cmd), r.stdout, r.stderr))
    return r.stdout


# ---------------------------------------------------------------------------
# configuration
# ---------------------------------------------------------------------------
class Cfg:
    """The .config, resolved through Kconfig (defaults and dependencies)."""

    def __init__(self, path):
        self.kconf = kconfiglib.Kconfig(os.path.join(REPO, "Kconfig"), warn_to_stderr=False)
        if os.path.exists(path):
            self.kconf.load_config(path)
        elif path != ".config":
            die("no such config: " + path)
        k = self.kconf.syms

        def b(n):
            return k[n].str_value == "y"

        def i(n):
            return int(k[n].str_value) if k[n].str_value else 0

        self.name = k["PROJECT_NAME"].str_value
        if not re.fullmatch(r"[a-z][a-z0-9_]*", self.name):
            die("PROJECT_NAME %r: use lower-case letters, digits and '_'" % self.name)
        self.ps = b("SYS_PS")
        self.pipe = b("CORE_PIPE")
        self.m, self.a = b("ISA_M"), b("ISA_A")
        self.c, self.f = b("ISA_C"), b("ISA_F")
        self.zba, self.zbb, self.zbc, self.zbs = b("ISA_ZBA"), b("ISA_ZBB"), b("ISA_ZBC"), b("ISA_ZBS")
        self.v = b("ISA_V")
        self.cnt = b("ISA_ZICNTR")
        self.vlen = 64 if b("VLEN_64") else 256 if b("VLEN_256") else 128
        self.u, self.s, self.mmu = b("PRIV_U"), b("PRIV_S"), b("MMU")
        self.tlb = i("TLB_ENTRIES") or 4
        self.bp = b("BPRED")
        self.bp_bits = i("BP_IDX_BITS") or 5
        self.imem_kb, self.dmem_kb = i("IMEM_KB"), i("DMEM_KB")
        self.caches = b("CACHES")
        self.line_words = i("LINE_WORDS") or 8
        self.i_lines, self.d_lines = i("ICACHE_LINES") or 32, i("DCACHE_LINES") or 32
        self.timer, self.gpio = b("TIMER"), b("GPIO")
        self.uart_pin = k["UART_TX_PIN"].str_value or "J18"
        self.baud = i("UART_BAUD") or 115200
        self.fw_custom = b("FW_CUSTOM")
        self.fw_hex = k["FW_HEX"].str_value

        for what, v in (("IMEM_KB", self.imem_kb), ("DMEM_KB", self.dmem_kb)):
            if v & (v - 1):
                die("%s=%d: memory sizes must be powers of two" % (what, v))
        if self.caches:
            for what, v in (("ICACHE_LINES", self.i_lines), ("DCACHE_LINES", self.d_lines),
                            ("LINE_WORDS", self.line_words)):
                if v & (v - 1):
                    die("%s=%d: must be a power of two" % (what, v))
        if self.fw_custom and not os.path.exists(self.fw_hex):
            die("FW_HEX %r does not exist" % self.fw_hex)

        self.core_id = 0 if self.pipe else (2 if self.c else 3 if self.f else 1)
        self.core_module = ["cpu_pipe_u", "cpu_mc", "cpu_mc_c", "cpu_mc_f"][self.core_id]

    # ---- derived ----
    def march(self):
        isa = "rv32i" + ("m" if self.m else "") + ("a" if self.a else "") + \
              ("f" if self.f else "") + ("c" if self.c else "")
        isa += "_zicsr"
        for on, z in ((self.zba, "zba"), (self.zbb, "zbb"), (self.zbc, "zbc"), (self.zbs, "zbs")):
            if on:
                isa += "_" + z
        if self.v:
            isa += "_zve32x"
        return isa

    def mabi(self):
        return "ilp32f" if self.f else "ilp32"

    def summary(self):
        parts = [self.march(), self.core_module]
        if self.pipe:
            if self.v:
                parts.append("vlen=%d" % self.vlen)
            parts.append("priv=M" + ("S" if self.s else "") + ("U" if self.u else ""))
            if self.mmu:
                parts.append("sv32(tlb=%d)" % self.tlb)
            parts.append("bpred=%d" % (1 << self.bp_bits) if self.bp else "bpred=off")
            parts.append("caches=%d+%dx%dw" % (self.i_lines, self.d_lines, self.line_words)
                         if self.caches else "caches=off")
        parts.append("ps-attached" if self.ps else "standalone")
        return " ".join(parts)

    def features(self):
        bits = [self.m, self.a, self.c, self.f, self.u, self.s, self.mmu, self.bp,
                self.caches, self.timer, self.gpio, self.ps]
        v = sum(1 << n for n, on in enumerate(bits) if on)
        zb = [self.zba, self.zbb, self.zbc, self.zbs]
        v |= sum(1 << (16 + n) for n, on in enumerate(zb) if on)
        v |= int(self.v) << 20
        return v | (self.core_id << 12)

    def _written(self, minimal):
        tmp = os.path.join(REPO, "build", ".rvgen_config")
        os.makedirs(os.path.dirname(tmp), exist_ok=True)
        (self.kconf.write_min_config if minimal else self.kconf.write_config)(tmp, header="")
        with open(tmp) as f:
            text = f.read()
        os.remove(tmp)
        return text

    def text(self):
        """The full resolved .config -- what rvconfig records."""
        return self._written(False)

    def cfg_hash(self):
        """CRC-32 of every resolved value: bitstream and PS program must agree."""
        lines = [l for l in self.text().splitlines() if l and not l.startswith("#")]
        return zlib.crc32("\n".join(sorted(lines)).encode()) & 0xFFFFFFFF

    def clks_per_bit(self):
        return round(PL_CLK_HZ / self.baud)


# ---------------------------------------------------------------------------
# firmware
# ---------------------------------------------------------------------------
LINKER = """/* generated by tools/rvgen -- self-test layout for this configuration */
ENTRY(_start)
SECTIONS
{
    . = 0x00000000;
    .text   : { *(.text.init) *(.text*) }
    .rodata : { *(.rodata*) *(.srodata*) }
    .data   : { *(.data*) *(.sdata*) }
    .bss    : { __bss_start = .; *(.bss*) *(.sbss*) *(COMMON) . = ALIGN(4); __bss_end = .; }
    __stack_top = %(dmem)d;
    ASSERT(__bss_end + 1024 <= __stack_top, "image + .bss + 1 KiB of stack do not fit in DMEM")
    ASSERT(SIZEOF(.text) + SIZEOF(.rodata) + SIZEOF(.data) <= %(imem)d, "image does not fit in IMEM")
}
"""


def build_firmware(cfg, work):
    fw = os.path.join(work, "fw")
    os.makedirs(fw, exist_ok=True)
    if cfg.fw_custom:
        shutil.copy(cfg.fw_hex, os.path.join(fw, "firmware.hex"))
        return os.path.join(fw, "firmware.hex"), None
    cfg.kconf.write_autoconf(os.path.join(fw, "oz_config.h"))
    with open(os.path.join(fw, "oz_config.h"), "a") as f:
        f.write('#define CONFIG_OZ_SUMMARY "%s"\n' % cfg.summary())
        f.write('#define CONFIG_OZ_VLEN %d\n' % cfg.vlen)
        for n in ("ISA_M", "ISA_A", "ISA_C", "ISA_F", "PRIV_U", "PRIV_S", "MMU", "TIMER", "GPIO",
                  "CORE_PIPE", "ISA_ZBA", "ISA_ZBB", "ISA_ZBC", "ISA_ZBS", "ISA_V", "ISA_ZICNTR"):
            f.write("#ifndef CONFIG_%s\n#define CONFIG_%s 0\n#endif\n" % (n, n))
    with open(os.path.join(fw, "oz.ld"), "w") as f:
        f.write(LINKER % {"dmem": cfg.dmem_kb * 1024, "imem": cfg.imem_kb * 1024})
    elf = os.path.join(fw, "firmware.elf")
    run([CROSS + "gcc", "-march=" + cfg.march(), "-mabi=" + cfg.mabi(), "-O2",
         "-ffreestanding", "-nostdlib", "-nostartfiles", "-ffp-contract=off", "-fno-math-errno",
         "-I", fw, "-I", os.path.join(REPO, "sw"), "-T", os.path.join(fw, "oz.ld"),
         os.path.join(REPO, "sw", "oz", "start.S"), os.path.join(REPO, "sw", "oz", "selftest.c"),
         os.path.join(REPO, "sw", "firmware.c"), "-o", elf, "-lgcc"])
    run([CROSS + "objcopy", "-O", "binary", elf, os.path.join(fw, "firmware.bin")])
    data = open(os.path.join(fw, "firmware.bin"), "rb").read()
    data += b"\0" * (-len(data) % 4)
    with open(os.path.join(fw, "firmware.hex"), "w") as f:
        for n in range(0, len(data), 4):
            f.write("%08x\n" % int.from_bytes(data[n:n + 4], "little"))
    size = run([CROSS + "size", elf]).splitlines()[-1].split()
    return os.path.join(fw, "firmware.hex"), (int(size[0]), int(size[1]), int(size[2]))


# ---------------------------------------------------------------------------
# RTL selection
# ---------------------------------------------------------------------------
def rtl_files(cfg):
    f = ["rtl/oz/oz_dpram.v", "rtl/oz/oz_rv_soc.v", "rtl/alu.v", "rtl/regfile.v",
         "rtl/immgen.v", "rtl/control.v"]
    if cfg.timer:
        f.append("rtl/timer.v")
    if cfg.pipe:
        f += ["rtl/csr_s.v", "rtl/zb_unit.v", "rtl/cpu_pipe_u.v", "rtl/oz/oz_burst_mem.v"]
        if cfg.v:
            f.append("rtl/vec_unit.v")
        if cfg.bp:
            f.append("rtl/branch_predictor.v")
            f.append("rtl/bpred_b.v")
        if cfg.mmu:
            f += ["rtl/tlb.v", "rtl/ptw.v"]
        f += ["rtl/icache.v", "rtl/dcache.v"] if cfg.caches else ["rtl/mem_bridge.v"]
    else:
        f += ["rtl/csr.v", "rtl/%s.v" % cfg.core_module]
        if cfg.c:
            f.append("rtl/rvc_expand.v")
        if cfg.f:
            f += ["rtl/fregfile.v", "rtl/fpu_f.v"]
    if cfg.ps:
        f += ["rtl/oz/oz_host.v", "rtl/oz/oz_async_fifo.v"]
    else:
        f += ["rtl/oz/oz_uart.v", "rtl/uart_tx.v"]
    return f


def soc_params(cfg, fw_path):
    p = dict(CORE=cfg.core_id, M_EXT=int(cfg.m), A_EXT=int(cfg.a), HAS_U=int(cfg.u),
             HAS_S=int(cfg.s), MMU=int(cfg.mmu), TLB_ENTRIES=cfg.tlb, BPRED=int(cfg.bp),
             BP_IDX_BITS=cfg.bp_bits, CACHES=int(cfg.caches), LINE_WORDS=cfg.line_words,
             I_LINES=cfg.i_lines, D_LINES=cfg.d_lines, IMEM_WORDS=cfg.imem_kb * 256,
             DMEM_WORDS=cfg.dmem_kb * 256, TIMER=int(cfg.timer), GPIO=int(cfg.gpio),
             ZBA=int(cfg.zba), ZBB=int(cfg.zbb), ZBC=int(cfg.zbc), ZBS=int(cfg.zbs),
             V_EXT=int(cfg.v), VLEN=cfg.vlen, ZICNTR=int(cfg.cnt))
    lines = [".%s(%s)" % (k, v) for k, v in p.items()]
    if fw_path:
        lines += [".IMEM_INIT(%s)" % fw_path, ".DMEM_INIT(%s)" % fw_path]
    return ",\n        ".join(lines)


# ---------------------------------------------------------------------------
# generated sources
# ---------------------------------------------------------------------------
HEADER = """// ---------------------------------------------------------------------------
// GENERATED by riscv-from-scratch tools/rvgen from rvconfig -- do not edit;
// change the configuration (make menuconfig) and regenerate instead.
//
//   %(summary)s
// ---------------------------------------------------------------------------
"""

STANDALONE_TOP = HEADER + """`default_nettype none

module %(name)s_top #(
    // the firmware is baked into block RAM. Synthesis runs from the OpenZynq
    // root; the testbench overrides these with its own relative paths.
    parameter FW_HEX       = "projects/%(name)s/fw/firmware.hex",
    parameter CLKS_PER_BIT = %(cpb)d             // %(clk)d Hz / %(baud)d baud
) (
    input  wire clk,          // 50 MHz PL oscillator (U18)
    input  wire resetn,       // PL reset button K1 (U19), active low
    output wire led,          // D6
    output wire led2,         // D7
%(btn_ports)s    output wire uart_tx       // %(pin)s
);
    // ---- reset: power-on counter + synchronised button ----
    reg [7:0] por = 8'd0;
    reg [1:0] rbtn = 2'b00;
    always @(posedge clk) begin
        rbtn <= {rbtn[0], resetn};
        if (!rbtn[1])          por <= 8'd0;
        else if (!por[7])      por <= por + 8'd1;
    end
    wire rst = ~por[7];

    wire       con_valid, con_ready, halted;
    wire [7:0] con_data;
    wire [1:0] gpio_out;
    wire [31:0] exit_code;
%(btn_sync)s
    oz_rv_soc #(
        %(params)s
    ) u_soc (
        .clk(clk), .rst(rst),
        .con_valid(con_valid), .con_data(con_data), .con_ready(con_ready),
        .gpio_out(gpio_out), .gpio_in(gpio_in),
        .halted(halted), .exit_code(exit_code), .retire(),
        .h_en(1'b0), .h_dmem(1'b0), .h_we(1'b0), .h_addr(16'd0), .h_wdata(32'd0), .h_rdata()
    );

    oz_uart #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_uart (
        .clk(clk), .rst(rst), .valid(con_valid), .data(con_data), .ready(con_ready),
        .tx(uart_tx));

    // ---- LEDs ----
    reg [24:0] beat = 25'd0;
    always @(posedge clk) beat <= beat + 25'd1;
%(leds)s
endmodule

`default_nettype wire
"""

PS_CORE = HEADER + """`default_nettype none

// The core plus its AXI4-Lite bridge, with M_AXI_GP0 as plain ports: this is
// what the testbench drives (the PS7 has no simulation model); <name>_top
// binds it to the real PS7.
module %(name)s (
    input  wire        clk,       // 50 MHz PL oscillator: the core clock
    input  wire        resetn,    // PL reset button K1
    output wire        led,
    output wire        led2,
%(btn_ports)s
    input  wire        m_axi_gp0_aclk,
    input  wire        m_axi_gp0_aresetn,
    input  wire [31:0] m_axi_gp0_awaddr,
    input  wire        m_axi_gp0_awvalid,
    output wire        m_axi_gp0_awready,
    input  wire [31:0] m_axi_gp0_wdata,
    input  wire [3:0]  m_axi_gp0_wstrb,
    input  wire        m_axi_gp0_wvalid,
    output wire        m_axi_gp0_wready,
    output wire [1:0]  m_axi_gp0_bresp,
    output wire        m_axi_gp0_bvalid,
    input  wire        m_axi_gp0_bready,
    input  wire [31:0] m_axi_gp0_araddr,
    input  wire        m_axi_gp0_arvalid,
    output wire        m_axi_gp0_arready,
    output wire [31:0] m_axi_gp0_rdata,
    output wire [1:0]  m_axi_gp0_rresp,
    output wire        m_axi_gp0_rvalid,
    input  wire        m_axi_gp0_rready
);
    // ---- core-domain reset: power-on, the button, and CTRL.run from the PS ----
    reg [7:0] por = 8'd0;
    reg [1:0] rbtn = 2'b00;
    always @(posedge clk) begin
        rbtn <= {rbtn[0], resetn};
        if (!rbtn[1])          por <= 8'd0;
        else if (!por[7])      por <= por + 8'd1;
    end
    wire crst = ~por[7];
    wire run;
    wire rst  = crst | ~run;

    wire        con_valid, con_ready, halted, h_en, h_dmem, h_we;
    wire [7:0]  con_data;
    wire [1:0]  gpio_out;
    wire [15:0] h_addr;
    wire [31:0] exit_code, h_wdata, h_rdata;
%(btn_sync)s
    oz_rv_soc #(
        %(params)s
    ) u_soc (
        .clk(clk), .rst(rst),
        .con_valid(con_valid), .con_data(con_data), .con_ready(con_ready),
        .gpio_out(gpio_out), .gpio_in(gpio_in),
        .halted(halted), .exit_code(exit_code), .retire(),
        .h_en(h_en), .h_dmem(h_dmem), .h_we(h_we), .h_addr(h_addr),
        .h_wdata(h_wdata), .h_rdata(h_rdata)
    );

    oz_host #(.FEATURES(32'h%(features)08x), .IMEM_BYTES(%(imem_b)d), .DMEM_BYTES(%(dmem_b)d),
              .CFG_HASH(32'h%(hash)08x), .CORE_HZ(%(clk)d)) u_host (
        .aclk(m_axi_gp0_aclk), .aresetn(m_axi_gp0_aresetn),
        .awaddr(m_axi_gp0_awaddr), .awvalid(m_axi_gp0_awvalid), .awready(m_axi_gp0_awready),
        .wdata(m_axi_gp0_wdata), .wstrb(m_axi_gp0_wstrb), .wvalid(m_axi_gp0_wvalid),
        .wready(m_axi_gp0_wready), .bresp(m_axi_gp0_bresp), .bvalid(m_axi_gp0_bvalid),
        .bready(m_axi_gp0_bready), .araddr(m_axi_gp0_araddr), .arvalid(m_axi_gp0_arvalid),
        .arready(m_axi_gp0_arready), .rdata(m_axi_gp0_rdata), .rresp(m_axi_gp0_rresp),
        .rvalid(m_axi_gp0_rvalid), .rready(m_axi_gp0_rready),
        .cclk(clk), .crst(crst), .run(run),
        .con_valid(con_valid), .con_data(con_data), .con_ready(con_ready),
        .halted(halted), .exit_code(exit_code),
        .h_en(h_en), .h_dmem(h_dmem), .h_we(h_we), .h_addr(h_addr),
        .h_wdata(h_wdata), .h_rdata(h_rdata)
    );

    reg [24:0] beat = 25'd0;
    always @(posedge clk) beat <= beat + 25'd1;
%(leds)s
endmodule

`default_nettype wire
"""

PS_TOP = HEADER + """`default_nettype none

// synthesis top: %(name)s bound to the PS7 (rtl/ps7_gp0.v, OpenZynq shared RTL)
module %(name)s_top (
    input  wire clk,
    input  wire resetn,
%(btn_ports)s    output wire led,
    output wire led2
);
    wire        aclk, aresetn;
    wire [31:0] awaddr, wdata, araddr, rdata;
    wire [3:0]  wstrb;
    wire        awvalid, awready, wvalid, wready, bvalid, bready;
    wire        arvalid, arready, rvalid, rready;
    wire [1:0]  bresp, rresp;

    ps7_gp0 u_ps7 (
        .aclk(aclk), .aresetn(aresetn),
        .m_awaddr(awaddr), .m_awvalid(awvalid), .m_awready(awready),
        .m_wdata(wdata), .m_wstrb(wstrb), .m_wvalid(wvalid), .m_wready(wready),
        .m_bresp(bresp), .m_bvalid(bvalid), .m_bready(bready),
        .m_araddr(araddr), .m_arvalid(arvalid), .m_arready(arready),
        .m_rdata(rdata), .m_rresp(rresp), .m_rvalid(rvalid), .m_rready(rready)
    );

    %(name)s u_core (
        .clk(clk), .resetn(resetn), .led(led), .led2(led2),%(btn_conn)s
        .m_axi_gp0_aclk(aclk), .m_axi_gp0_aresetn(aresetn),
        .m_axi_gp0_awaddr(awaddr), .m_axi_gp0_awvalid(awvalid), .m_axi_gp0_awready(awready),
        .m_axi_gp0_wdata(wdata), .m_axi_gp0_wstrb(wstrb), .m_axi_gp0_wvalid(wvalid),
        .m_axi_gp0_wready(wready), .m_axi_gp0_bresp(bresp), .m_axi_gp0_bvalid(bvalid),
        .m_axi_gp0_bready(bready), .m_axi_gp0_araddr(araddr), .m_axi_gp0_arvalid(arvalid),
        .m_axi_gp0_arready(arready), .m_axi_gp0_rdata(rdata), .m_axi_gp0_rresp(rresp),
        .m_axi_gp0_rvalid(rvalid), .m_axi_gp0_rready(rready)
    );
endmodule

`default_nettype wire
"""

TB_STANDALONE = HEADER + """`timescale 1ns/1ps
`default_nettype none

// Runs the firmware on %(name)s_top, decodes the UART TX pin bit by bit
// (as a USB-serial adapter would), and passes if the program printed
// "ALL PASS" and halted with exit code 0. `make sim PROJECT=%(name)s`.
module tb_%(name)s_top;
    localparam CPB = 8;                         // fast UART for simulation
    reg clk = 0, resetn = 0;
    wire led, led2, tx;
    always #10 clk = ~clk;                      // 50 MHz

    %(name)s_top #(.FW_HEX("../../projects/%(name)s/fw/firmware.hex"), .CLKS_PER_BIT(CPB)) dut (
        .clk(clk), .resetn(resetn), .led(led), .led2(led2),%(btn_tb)s .uart_tx(tx));

    // ---- UART receiver on the pin ----
    reg [7:0] line [0:4095]; integer nl = 0, k;
    reg [7:0] b;
    initial forever begin
        @(negedge tx);
        repeat (CPB + CPB/2) @(posedge clk);
        for (k = 0; k < 8; k = k + 1) begin b[k] = tx; repeat (CPB) @(posedge clk); end
        $write("%%c", b);
        line[nl] = b; nl = nl + 1;
    end

    function seen_all_pass; input dummy; integer i;
        begin
            seen_all_pass = 0;
            for (i = 0; i + 8 <= nl; i = i + 1)
                if (line[i]=="A" && line[i+1]=="L" && line[i+2]=="L" && line[i+3]==" " &&
                    line[i+4]=="P" && line[i+5]=="A" && line[i+6]=="S" && line[i+7]=="S")
                    seen_all_pass = 1;
        end
    endfunction

    integer cyc = 0;
    initial begin
        $dumpfile("tb_%(name)s_top.vcd"); $dumpvars(1, tb_%(name)s_top);
        repeat (5) @(posedge clk); resetn = 1;
        while (!dut.u_soc.halted && cyc < 4000000) begin @(posedge clk); cyc = cyc + 1; end
        repeat (40 * CPB) @(posedge clk);       // let the last byte drain
        if (dut.u_soc.halted && dut.u_soc.exit_code == 0 && seen_all_pass(0))
            $display("\\nPASS: %(name)s self-test, %%0d cycles, exit code 0", cyc);
        else
            $display("\\nFAIL: %(name)s halted=%%0d exit=%%0d all_pass=%%0d",
                     dut.u_soc.halted, dut.u_soc.exit_code, seen_all_pass(0));
        $finish;
    end
endmodule

`default_nettype wire
"""

TB_PS = HEADER + """`timescale 1ns/1ps
`default_nettype none

// Plays the Cortex-A9 against %(name)s over AXI4-Lite, exactly as ps/main.c
// does on the board: check ID / config hash, load the firmware into IMEM and
// DMEM, read it back, set CTRL.run, relay the console, and pass if the
// program printed "ALL PASS" and halted with exit code 0.
module tb_%(name)s;
    reg clk = 0, aclk = 0, resetn = 0, aresetn = 0;
    always #10 clk  = ~clk;                     // 50 MHz core clock
    always #5  aclk = ~aclk;                    // 100 MHz FCLK0
    wire led, led2;

    reg  [31:0] awaddr = 0, wdata = 0, araddr = 0;
    reg         awvalid = 0, wvalid = 0, arvalid = 0;
    wire        awready, wready, bvalid, arready, rvalid;
    wire [31:0] rdata;
    wire [1:0]  bresp, rresp;

    %(name)s dut (
        .clk(clk), .resetn(resetn), .led(led), .led2(led2),%(btn_tb)s
        .m_axi_gp0_aclk(aclk), .m_axi_gp0_aresetn(aresetn),
        .m_axi_gp0_awaddr(awaddr), .m_axi_gp0_awvalid(awvalid), .m_axi_gp0_awready(awready),
        .m_axi_gp0_wdata(wdata), .m_axi_gp0_wstrb(4'hF), .m_axi_gp0_wvalid(wvalid),
        .m_axi_gp0_wready(wready), .m_axi_gp0_bresp(bresp), .m_axi_gp0_bvalid(bvalid),
        .m_axi_gp0_bready(1'b1), .m_axi_gp0_araddr(araddr), .m_axi_gp0_arvalid(arvalid),
        .m_axi_gp0_arready(arready), .m_axi_gp0_rdata(rdata), .m_axi_gp0_rresp(rresp),
        .m_axi_gp0_rvalid(rvalid), .m_axi_gp0_rready(1'b1));

    task axi_wr; input [31:0] a, d;
        begin
            @(posedge aclk); awaddr <= a; wdata <= d; awvalid <= 1; wvalid <= 1;
            @(posedge aclk); while (!(awready && wready)) @(posedge aclk);
            awvalid <= 0; wvalid <= 0;
            while (!bvalid) @(posedge aclk);
        end
    endtask
    task axi_rd; input [31:0] a; output [31:0] d;
        begin
            @(posedge aclk); araddr <= a; arvalid <= 1;
            @(posedge aclk); while (!arready) @(posedge aclk);
            arvalid <= 0;
            while (!rvalid) @(posedge aclk);
            d = rdata;
        end
    endtask

    localparam BASE = 32'h4000_0000, IMEM = BASE + 32'h10_0000, DMEM = BASE + 32'h20_0000;
    reg [31:0] img [0:%(img_words)d];
    reg [31:0] v, st;
    reg [7:0]  line [0:4095];
    integer    n, nw, nl = 0, bad = 0, polls = 0, pass_seen;

    initial begin
        for (n = 0; n <= %(img_words)d; n = n + 1) img[n] = 32'hxxxxxxxx;
        $readmemh("../../projects/%(name)s/fw/firmware.hex", img);
        nw = 0; while (nw <= %(img_words)d && img[nw] !== 32'hxxxxxxxx) nw = nw + 1;
        repeat (4) @(posedge clk); resetn = 1; aresetn = 1;

        axi_rd(BASE + 32'h00, v);
        if (v !== 32'h4F5A5256) begin $display("FAIL: ID %%h", v); $finish; end
        axi_rd(BASE + 32'h20, v);
        if (v !== 32'h%(hash)08x) begin $display("FAIL: config hash %%h", v); $finish; end
        for (n = 0; n < nw; n = n + 1) begin
            axi_wr(IMEM + 4*n, img[n]);
            axi_wr(DMEM + 4*n, img[n]);           // data side holds the image too
        end
        for (n = 0; n < nw; n = n + 1) begin
            axi_rd(IMEM + 4*n, v); if (v !== img[n]) bad = bad + 1;
        end
        $display("loaded %%0d words, %%0d readback mismatches", nw, bad);
        axi_wr(BASE + 32'h04, 1);                 // CTRL.run

        st = 0;
        while (!(st[1] && !st[2]) && polls < 2000000) begin
            axi_rd(BASE + 32'h10, v);             // CONSOLE (pops)
            if (v[8]) begin $write("%%c", v[7:0]); line[nl] = v[7:0]; nl = nl + 1; end
            axi_rd(BASE + 32'h08, st);
            polls = polls + 1;
        end
        axi_rd(BASE + 32'h0C, v);
        pass_seen = 0;
        for (n = 0; n + 8 <= nl; n = n + 1)
            if (line[n]=="A" && line[n+1]=="L" && line[n+2]=="L" && line[n+3]==" " &&
                line[n+4]=="P" && line[n+5]=="A" && line[n+6]=="S" && line[n+7]=="S") pass_seen = 1;
        if (st[1] && v == 0 && pass_seen && bad == 0)
            $display("\\nPASS: %(name)s self-test over AXI, exit code 0");
        else
            $display("\\nFAIL: %(name)s halted=%%0d exit=%%0d all_pass=%%0d bad=%%0d", st[1], v, pass_seen, bad);
        $finish;
    end
endmodule

`default_nettype wire
"""

XDC = """# ----------------------------------------------------------------------------
#  GENERATED by riscv-from-scratch tools/rvgen -- %(summary)s
#  Pins from boards/mitra7010/mitra7010.xdc and boards/mitra7010/pinout.md.
# ----------------------------------------------------------------------------
set_property PACKAGE_PIN U18     [get_ports clk]
set_property IOSTANDARD LVCMOS33 [get_ports clk]
create_clock -period 20.000 -name sys_clk [get_ports clk]

set_property PACKAGE_PIN U19     [get_ports resetn]
set_property IOSTANDARD LVCMOS33 [get_ports resetn]

set_property PACKAGE_PIN R19     [get_ports led]
set_property IOSTANDARD LVCMOS33 [get_ports led]
set_property PACKAGE_PIN V13     [get_ports led2]
set_property IOSTANDARD LVCMOS33 [get_ports led2]
%(extra)s"""

PROJECT_MK = """# GENERATED by riscv-from-scratch tools/rvgen -- %(summary)s
# Regenerate instead of editing: make menuconfig && make oz-export OZ=<this repo>
TOP      := %(top)s
SIM_TOP  := %(sim_top)s
XDC      := projects/%(name)s/%(name)s.xdc

RV_RTL   := %(rtl)s
SIM_SRCS := $(addprefix projects/%(name)s/,$(RV_RTL)) %(sim_extra)s
SRCS     := $(SIM_SRCS) %(syn_extra)s

# The program lives in block RAM, so let Yosys infer it (the flow's default
# passes -nobram).
SYNTH_OPTS := -flatten -abc9 -arch xc7
%(ps_mk)s"""


def leds(cfg):
    if cfg.gpio:
        return "    assign led  = gpio_out[0];\n    assign led2 = gpio_out[1];"
    return "    assign led  = halted;              // LED1: halted\n" \
           "    assign led2 = beat[24];            // LED2: heartbeat"


def btn_bits(cfg):
    if not cfg.gpio:
        return "", "    wire [1:0] gpio_in = 2'b00;\n", "", ""
    ports = "    input  wire btn1,         // K2 (G14), active low\n" \
            "    input  wire btn2,         // K3 (J15), active low\n"
    sync = ("    reg [1:0] b1 = 2'b11, b2 = 2'b11;\n"
            "    always @(posedge clk) begin b1 <= {b1[0], btn1}; b2 <= {b2[0], btn2}; end\n"
            "    wire [1:0] gpio_in = {~b2[1], ~b1[1]};   // 1 = pressed\n")
    return ports, sync, " .btn1(btn1), .btn2(btn2),", " .btn1(1'b1), .btn2(1'b1),"


def generate(cfg, out, fw_hex, fw_size):
    name = cfg.name
    pdir = os.path.join(out, "projects", name)
    if os.path.exists(pdir):
        shutil.rmtree(pdir)
    os.makedirs(os.path.join(pdir, "fw"))
    os.makedirs(os.path.join(pdir, "rtl"))
    open(os.path.join(pdir, MARKER), "w").write("generated by riscv-from-scratch tools/rvgen\n")

    files = rtl_files(cfg)
    rel = []
    for f in files:
        dst = os.path.join(pdir, "rtl", os.path.basename(f))
        shutil.copy(os.path.join(REPO, f), dst)
        rel.append("rtl/" + os.path.basename(f))
    shutil.copy(fw_hex, os.path.join(pdir, "fw", "firmware.hex"))
    img_words = sum(1 for _ in open(fw_hex))

    btn_ports, btn_sync, btn_conn, btn_tb = btn_bits(cfg)
    d = dict(name=name, summary=cfg.summary(), cpb=cfg.clks_per_bit(), clk=PL_CLK_HZ,
             baud=cfg.baud, pin=cfg.uart_pin, btn_ports=btn_ports, btn_sync=btn_sync,
             btn_conn=btn_conn, btn_tb=btn_tb, leds=leds(cfg), features=cfg.features(),
             hash=cfg.cfg_hash(), imem_b=cfg.imem_kb * 1024, dmem_b=cfg.dmem_kb * 1024,
             img_words=img_words)

    btn_xdc = ("set_property PACKAGE_PIN G14     [get_ports btn1]\n"
               "set_property IOSTANDARD LVCMOS33 [get_ports btn1]\n"
               "set_property PACKAGE_PIN J15     [get_ports btn2]\n"
               "set_property IOSTANDARD LVCMOS33 [get_ports btn2]\n") if cfg.gpio else ""
    if cfg.ps:
        d["params"] = soc_params(cfg, None)
        open(os.path.join(pdir, name + ".v"), "w").write(PS_CORE % d)
        open(os.path.join(pdir, name + "_top.v"), "w").write(PS_TOP % d)
        open(os.path.join(pdir, "tb_%s.v" % name), "w").write(TB_PS % d)
        extra = btn_xdc
        top, sim_top = name + "_top", name
        sim_extra = "projects/%s/%s.v" % (name, name)
        syn_extra = "rtl/ps7_gp0.v rtl/axi3_to_axilite.v projects/%s/%s_top.v" % (name, name)
        ps_mk = ("\n# FCLK0 (the AXI clock) comes from the PS and cannot carry a create_clock.\n"
                 "NEXTPNR_OPTS := --freq 50\n")
        write_ps_app(cfg, pdir, fw_hex)
    else:
        d["params"] = soc_params(cfg, "FW_HEX")
        open(os.path.join(pdir, name + "_top.v"), "w").write(STANDALONE_TOP % d)
        open(os.path.join(pdir, "tb_%s_top.v" % name), "w").write(TB_STANDALONE % d)
        extra = btn_xdc + ("\n# UART TX (3.3 V) -- connect a USB-serial adapter's RX here, GND to JM1 pin 3/4\n"
                           "set_property PACKAGE_PIN %s     [get_ports uart_tx]\n"
                           "set_property IOSTANDARD LVCMOS33 [get_ports uart_tx]\n" % cfg.uart_pin)
        top = sim_top = name + "_top"
        sim_extra = "projects/%s/%s_top.v" % (name, name)
        syn_extra = ""
        ps_mk = ""
    open(os.path.join(pdir, name + ".xdc"), "w").write(XDC % dict(summary=cfg.summary(), extra=extra))
    open(os.path.join(pdir, "project.mk"), "w").write(PROJECT_MK % dict(
        summary=cfg.summary(), top=top, sim_top=sim_top, name=name,
        rtl=" \\\n            ".join(rel), sim_extra=sim_extra, syn_extra=syn_extra, ps_mk=ps_mk))
    open(os.path.join(pdir, "rvconfig"), "w").write(cfg.text())
    write_readme(cfg, pdir, fw_size)
    return pdir


# ---------------------------------------------------------------------------
# the PS side (Cortex-A9 loader + console relay)
# ---------------------------------------------------------------------------
PS_MAIN = r"""// ---------------------------------------------------------------------------
// GENERATED by riscv-from-scratch tools/rvgen -- %(summary)s
//
// The Cortex-A9 side of a PS-attached RISC-V: checks that the bitstream is
// the configuration this program was built for, loads the RISC-V firmware
// (rv_firmware.h) into the PL instruction and data memories over M_AXI_GP0,
// releases the core, and copies everything it prints to UART0 (the CH340
// USB-UART, 115200 8N1) until it halts. Then it reports the exit code.
//
//   docker compose run --rm oz make run PROJECT=%(name)s
// ---------------------------------------------------------------------------
#include <stdint.h>
#include "rv_firmware.h"

#ifdef HAS_PS7_INIT
extern int ps7_init(void);
extern int ps7_post_config(void);
#endif

#define RV_BASE     0x40000000u
#define RV_ID       (*(volatile uint32_t *)(RV_BASE + 0x00))
#define RV_CTRL     (*(volatile uint32_t *)(RV_BASE + 0x04))
#define RV_STATUS   (*(volatile uint32_t *)(RV_BASE + 0x08))
#define RV_EXIT     (*(volatile uint32_t *)(RV_BASE + 0x0C))
#define RV_CONSOLE  (*(volatile uint32_t *)(RV_BASE + 0x10))
#define RV_FEATURES (*(volatile uint32_t *)(RV_BASE + 0x14))
#define RV_HASH     (*(volatile uint32_t *)(RV_BASE + 0x20))
#define RV_IMEM     ((volatile uint32_t *)(RV_BASE + 0x100000))
#define RV_DMEM     ((volatile uint32_t *)(RV_BASE + 0x200000))

// ---- UART0 (Cadence UART, MIO 10/11) -- as projects/ps_pl_demo/ps/main.c ----
#define UART0_BASE  0xE0000000u
#define UART_CR     0x00
#define UART_MR     0x04
#define UART_BAUDGEN 0x18
#define UART_SR     0x2C
#define UART_TXRX   0x30
#define UART_BDIV   0x34
static void uart_init(void) {
    volatile uint32_t *u = (volatile uint32_t *)UART0_BASE;
    u[UART_CR / 4] = 0x03;                       // reset RX/TX
    u[UART_MR / 4] = 0x20;                       // 8N1
    u[UART_BAUDGEN / 4] = 124;                   // 100 MHz / (124 * 7) = 115207
    u[UART_BDIV / 4] = 6;
    u[UART_CR / 4] = 0x14;                       // TX + RX enable
}
static void putc_(char c) {
    volatile uint32_t *u = (volatile uint32_t *)UART0_BASE;
    if (c == '\n') putc_('\r');
    while (u[UART_SR / 4] & (1u << 4)) { }       // TX FIFO full
    u[UART_TXRX / 4] = (uint32_t)c;
}
static void puts_(const char *s) { while (*s) putc_(*s++); }
static void puthex(uint32_t v) {
    puts_("0x");
    for (int i = 28; i >= 0; i -= 4) putc_("0123456789abcdef"[(v >> i) & 15]);
}

int main(void) {
#ifdef HAS_PS7_INIT
    if (ps7_init() == 0) ps7_post_config();      // post_config: PS->PL level shifters
#endif
    uart_init();
    puts_("\n== OpenZynq RISC-V (%(name)s) ==\n");
    puts_("   %(summary)s\n");

    if (RV_ID != 0x4F5A5256u) { puts_("no RISC-V in the PL (ID "); puthex(RV_ID); puts_(")\n"); for (;;) { } }
    if (RV_HASH != RV_CFG_HASH) {
        puts_("bitstream config "); puthex(RV_HASH); puts_(" != firmware config "); puthex(RV_CFG_HASH);
        puts_("\nrebuild both from the same rvconfig\n");
        for (;;) { }
    }

    RV_CTRL = 0;                                  // hold the core in reset
    for (uint32_t i = 0; i < RV_FW_WORDS; i++) { RV_IMEM[i] = rv_fw[i]; RV_DMEM[i] = rv_fw[i]; }
    uint32_t bad = 0;
    for (uint32_t i = 0; i < RV_FW_WORDS; i++) if (RV_IMEM[i] != rv_fw[i]) bad++;
    puts_("   loaded "); puthex(RV_FW_WORDS * 4); puts_(" bytes, readback errors "); puthex(bad);
    puts_("\n-- RISC-V console --\n");

    RV_CTRL = 1;                                  // run
    for (;;) {
        uint32_t c = RV_CONSOLE;
        if (c & 0x100u) { putc_((char)c); continue; }
        if (RV_STATUS & 2u) break;                // halted, console drained
    }
    while (RV_CONSOLE & 0x100u) { }
    puts_("-- RISC-V halted, exit code "); puthex(RV_EXIT); puts_(RV_EXIT == 0 ? " (pass)\n" : " (FAIL)\n");
    for (;;) asm volatile ("wfi");
    return 0;
}
"""

PS_MAKEFILE = """# GENERATED by riscv-from-scratch tools/rvgen.
# The Cortex-A9 program for %(name)s: copied from projects/ps_pl_demo/ps,
# building ps/build/%(name)s.elf (the name `make run PROJECT=%(name)s` loads).
TOOLCHAIN := arm-none-eabi-
CC := $(TOOLCHAIN)gcc
OBJCP := $(TOOLCHAIN)objcopy
SIZE := $(TOOLCHAIN)size
BUILD_DIR := build
SRCS := main.c startup.S
PS7_INIT_C := $(wildcard ps7_init.c)
ifneq ($(PS7_INIT_C),)
SRCS += $(PS7_INIT_C)
PS7_INIT_DEF := -DHAS_PS7_INIT
endif
OBJS := $(SRCS:%%.S=$(BUILD_DIR)/%%.o)
OBJS := $(OBJS:%%.c=$(BUILD_DIR)/%%.o)
ARCH_FLAGS := -mcpu=cortex-a9 -mfloat-abi=hard -mfpu=neon-fp16 -mthumb-interwork
CFLAGS  := $(ARCH_FLAGS) -O2 -ffreestanding -nostdlib -fno-common -Wall -Wextra $(PS7_INIT_DEF) -I.
LDFLAGS := $(ARCH_FLAGS) -ffreestanding -nostdlib -Wl,-T,linker.ld -Wl,--gc-sections -lgcc

.PHONY: all genz vivado-init clean
all: $(BUILD_DIR)/%(name)s.elf
$(BUILD_DIR)/%%.o: %%.c rv_firmware.h | $(BUILD_DIR)
\t$(CC) $(CFLAGS) -c $< -o $@
$(BUILD_DIR)/%%.o: %%.S | $(BUILD_DIR)
\t$(CC) $(CFLAGS) -c $< -o $@
$(BUILD_DIR)/%(name)s.elf: $(OBJS) linker.ld
\t$(CC) $(LDFLAGS) $(OBJS) -o $@
\t$(SIZE) $@
$(BUILD_DIR):
\tmkdir -p $(BUILD_DIR)
clean:
\trm -rf $(BUILD_DIR)
BOARD    ?= mitra7010
genz:
\tcp ../../../boards/$(BOARD)/ps7_init/ps7_init.c ../../../boards/$(BOARD)/ps7_init/ps7_init.h .
vivado-init:
\tcp ../../../boards/$(BOARD)/ps7_init_vivado/ps7_init.c ../../../boards/$(BOARD)/ps7_init_vivado/ps7_init.h .
"""


def write_ps_app(cfg, pdir, fw_hex):
    ps = os.path.join(pdir, "ps")
    os.makedirs(ps)
    words = [l.strip() for l in open(fw_hex) if l.strip()]
    with open(os.path.join(ps, "rv_firmware.h"), "w") as f:
        f.write("// GENERATED by tools/rvgen: the RISC-V program (fw/firmware.hex) for the PS to load.\n")
        f.write("#include <stdint.h>\n#define RV_CFG_HASH 0x%08xu\n" % cfg.cfg_hash())
        f.write("#define RV_FW_WORDS %du\nstatic const uint32_t rv_fw[RV_FW_WORDS] = {\n" % len(words))
        for n in range(0, len(words), 8):
            f.write("    " + ", ".join("0x" + w for w in words[n:n + 8]) + ",\n")
        f.write("};\n")
    d = dict(name=cfg.name, summary=cfg.summary())
    open(os.path.join(ps, "main.c"), "w").write(PS_MAIN % d)
    open(os.path.join(ps, "Makefile"), "w").write(PS_MAKEFILE % d)
    # startup.S, linker.ld and xil_io.h are OpenZynq's own; oz-export copies
    # them from projects/ps_pl_demo/ps of the target checkout.


def write_readme(cfg, pdir, fw_size):
    name = cfg.name
    lines = ["# %s -- a generated RISC-V for the Mitra-7010" % name, "",
             "Generated by `tools/rvgen` in [riscv-from-scratch](https://github.com/Phoenix-flame/riscv-from-scratch)"
             " from `rvconfig` (`make menuconfig` there). Do not edit the files here;",
             "change the configuration and regenerate (`make oz-export OZ=<OpenZynq>`).", "",
             "**Configuration:** `%s`" % cfg.summary(), "",
             "| | |", "|---|---|",
             "| Core | `%s` (`-march=%s -mabi=%s`) |" % (cfg.core_module, cfg.march(), cfg.mabi()),
             "| Memory | IMEM %d KiB, DMEM %d KiB (block RAM)%s |" % (
                 cfg.imem_kb, cfg.dmem_kb,
                 ", I$ %d x %d words, D$ %d x %d words (write-back)" % (
                     cfg.i_lines, cfg.line_words, cfg.d_lines, cfg.line_words) if cfg.caches else ""),
             "| Clock | 50 MHz PL oscillator (U18) |",
             "| Console | %s |" % ("M_AXI_GP0 -> PS UART0 (CH340 USB-UART)" if cfg.ps else
                                  "UART TX on %s, %d baud (JM1 pin 21 by default; GND on JM1 pin 3/4)" % (
                                      cfg.uart_pin, cfg.baud)),
             "| LEDs | %s |" % ("GPIO: D6 = bit 0, D7 = bit 1 (self-test: both on = pass)" if cfg.gpio
                                else "D6 = halted, D7 = heartbeat"),
             "| Config hash | `0x%08x` |" % cfg.cfg_hash(), ""]
    if fw_size:
        lines += ["Firmware: self-test, %d bytes of code, %d data, %d bss." % fw_size, ""]
    lines += ["## Build and run", "", "```bash", "docker compose run --rm oz make sim PROJECT=%s" % name,
              "docker compose run --rm oz make bit PROJECT=%s" % name]
    if cfg.ps:
        lines += ["docker compose run --rm oz make -C projects/%s/ps vivado-init   # or: genz" % name,
                  "docker compose run --rm oz make run PROJECT=%s" % name, "```", "",
                  "`make run` programs the PL, loads `ps/build/%s.elf` on CPU0, and that program loads the "
                  "RISC-V firmware over M_AXI_GP0 and relays its console to UART0 (115200 8N1)." % name]
    else:
        lines += ["docker compose run --rm oz make prog PROJECT=%s" % name, "```", "",
                  "The firmware is in the bitstream: after `make prog` the core starts at once. "
                  "Watch %s at %d 8N1 with a 3.3 V USB-serial adapter; K1 (U19) restarts it." % (
                      cfg.uart_pin, cfg.baud)]
    lines += ["", "## Memory map (RISC-V side)", "",
              "| Address | Device |", "|---|---|",
              "| `0x0000_0000` | IMEM (fetch) / DMEM (data), %d / %d KiB |" % (cfg.imem_kb, cfg.dmem_kb),
              "| `0x1000_0000` | console: +0 TX, +4 STATUS (bit0 ready) |"]
    if cfg.timer:
        lines.append("| `0x1001_0000` | timer: +0 MTIME, +4 MTIMECMP (machine timer interrupt) |")
    if cfg.gpio:
        lines.append("| `0x1002_0000` | GPIO: +0 LEDs [1:0], +4 buttons [1:0] (1 = pressed) |")
    lines.append("| `0x2000_0000` | SYSCON: write = halt, value = exit code |")
    if cfg.ps:
        lines += ["", "## PS side (`0x4000_0000`, M_AXI_GP0)", "",
                  "See `rtl/oz_host.v`: ID, CTRL.run, STATUS, EXIT, CONSOLE (read pops), FEATURES, "
                  "sizes, CFG_HASH; IMEM window at `+0x10_0000`, DMEM at `+0x20_0000`."]
    open(os.path.join(pdir, "README.md"), "w").write("\n".join(lines) + "\n")


# ---------------------------------------------------------------------------
# export / simulate
# ---------------------------------------------------------------------------
def export(cfg, pdir, oz, force):
    if not os.path.isfile(os.path.join(oz, "boards", "mitra7010", "board.mk")):
        die("%s does not look like an OpenZynq checkout (no boards/mitra7010/board.mk)" % oz)
    dst = os.path.join(oz, "projects", cfg.name)
    if os.path.exists(dst) and not os.path.exists(os.path.join(dst, MARKER)) and not force:
        die("%s exists and was not generated by rvgen; pick another PROJECT_NAME or use --force" % dst)
    if os.path.exists(dst):
        keep = {}
        for f in ("ps7_init.c", "ps7_init.h", "xparameters.h"):     # board init the user copied in
            p = os.path.join(dst, "ps", f)
            if os.path.exists(p):
                keep[f] = open(p, "rb").read()
        shutil.rmtree(dst)
    shutil.copytree(pdir, dst)
    if cfg.ps:
        for f in ("startup.S", "linker.ld", "xil_io.h"):
            shutil.copy(os.path.join(oz, "projects", "ps_pl_demo", "ps", f), os.path.join(dst, "ps", f))
        for f, data in keep.items():
            open(os.path.join(dst, "ps", f), "wb").write(data)
    return dst


def simulate(cfg, root):
    """What OpenZynq's `make sim` does: iverilog from the root, vvp in build/<proj>."""
    pdir = os.path.join(root, "projects", cfg.name)
    mk = open(os.path.join(pdir, "project.mk")).read().replace("\\\n", " ")
    rv = re.search(r"^RV_RTL\s*:=\s*(.*)$", mk, re.M).group(1).split()
    extra = re.search(r"^SIM_SRCS\s*:=.*\$\(RV_RTL\)\)\s*(.*)$", mk, re.M).group(1).split()
    sim_top = re.search(r"^SIM_TOP\s*:=\s*(\S+)", mk, re.M).group(1)
    srcs = ["projects/%s/%s" % (cfg.name, f) for f in rv] + extra
    out = os.path.join(root, "build", cfg.name)
    os.makedirs(out, exist_ok=True)
    run(["iverilog", "-g2012", "-o", os.path.join(out, "tb.vvp"),
         "projects/%s/tb_%s.v" % (cfg.name, sim_top)] + srcs, cwd=root)
    r = subprocess.run(["vvp", "tb.vvp"], cwd=out, capture_output=True, text=True)
    print(r.stdout)
    return "\nPASS:" in r.stdout


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", default=os.environ.get("KCONFIG_CONFIG", ".config"))
    ap.add_argument("--out", default=os.path.join(REPO, "build", "oz"))
    ap.add_argument("--oz", help="OpenZynq checkout to copy the project into")
    ap.add_argument("--sim", action="store_true", help="simulate the generated project")
    ap.add_argument("--force", action="store_true", help="overwrite a project rvgen did not make")
    a = ap.parse_args()

    cfg = Cfg(a.config)
    work = os.path.join(REPO, "build", "rvgen", cfg.name)
    fw_hex, fw_size = build_firmware(cfg, work)
    pdir = generate(cfg, a.out, fw_hex, fw_size)
    print("rvgen: %s" % cfg.summary())
    print("rvgen: wrote %s (%d RTL files, config hash 0x%08x)" % (
        os.path.relpath(pdir, REPO), len(rtl_files(cfg)), cfg.cfg_hash()))
    ok = True
    if a.sim:
        if cfg.ps:      # the PS testbench needs OpenZynq's shared RTL only for synthesis
            pass
        ok = simulate(cfg, a.out)
        print("rvgen: simulation %s" % ("PASSED" if ok else "FAILED"))
    if a.oz:
        dst = export(cfg, pdir, os.path.abspath(a.oz), a.force)
        print("rvgen: exported to %s" % dst)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
