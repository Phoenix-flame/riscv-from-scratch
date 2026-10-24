/* vgen programs: code at 0, the random data / index tables at 0x2000 */
ENTRY(_start)
SECTIONS
{
    . = 0x00000000;
    .text  : { *(.text.init) *(.text*) }
    . = 0x00002000;
    .vdata : { *(.vdata) }
}
