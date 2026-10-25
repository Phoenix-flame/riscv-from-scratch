/* =====================================================================
 * fdt.h  -  a small flattened-device-tree (DTB) library
 * ---------------------------------------------------------------------
 * The DTB is the binary form of a device tree, as dtc emits it and as
 * Linux expects it in a1: a header, a memory-reservation map, a STRUCTURE
 * block (a token stream: BEGIN_NODE name / PROP len nameoff value /
 * END_NODE / END) and a STRINGS block holding each property name once.
 * Every integer in it is big-endian.
 *
 * This is the subset of libfdt's API the boot ROM and its payloads use,
 * with libfdt's conventions: a node is the byte offset of its BEGIN_NODE
 * token inside the structure block, and errors are negative numbers.
 * fdt_setprop() edits a tree in place -- growing or shrinking the
 * property and moving everything after it -- inside a buffer of
 * `capacity` bytes; that is how the ROM fixes up the tree it hands on.
 * ===================================================================== */
#ifndef FDT_H
#define FDT_H

#include <stdint.h>

#define FDT_MAGIC       0xd00dfeedu
#define FDT_BEGIN_NODE  1
#define FDT_END_NODE    2
#define FDT_PROP        3
#define FDT_NOP         4
#define FDT_END         9

#define FDT_ERR_NOTFOUND  -1
#define FDT_ERR_BADMAGIC  -2
#define FDT_ERR_BADSTRUCT -3
#define FDT_ERR_NOSPACE   -4
#define FDT_ERR_BADLAYOUT -5

struct fdt_header {                 /* all fields big-endian */
    uint32_t magic, totalsize, off_dt_struct, off_dt_strings, off_mem_rsvmap,
             version, last_comp_version, boot_cpuid_phys,
             size_dt_strings, size_dt_struct;
};

static inline uint32_t fdt32(uint32_t be)
{
    return (be >> 24) | ((be >> 8) & 0xff00u) | ((be << 8) & 0xff0000u) | (be << 24);
}
#define cpu_to_fdt32 fdt32
static inline uint32_t fdt_hdr(const void *fdt, int field)   /* field: word index */
{
    return fdt32(((const uint32_t *)fdt)[field]);
}
#define fdt_totalsize(f)  fdt_hdr((f), 1)

int         fdt_check(const void *fdt);                     /* 0 or an error */
int         fdt_next_tag(const void *fdt, int off, int *next);
const char *fdt_get_name(const void *fdt, int node);        /* "" for the root */
int         fdt_path_offset(const void *fdt, const char *path);
int         fdt_first_subnode(const void *fdt, int node);
int         fdt_next_subnode(const void *fdt, int node);
int         fdt_first_prop(const void *fdt, int node);      /* offset of a PROP tag */
int         fdt_next_prop(const void *fdt, int prop);
const void *fdt_prop_value(const void *fdt, int prop, const char **name, int *len);
const void *fdt_getprop(const void *fdt, int node, const char *name, int *len);
int         fdt_getprop_u32(const void *fdt, int node, const char *name, uint32_t *val);
/* does a "compatible"-style string list contain s? */
int         fdt_stringlist_contains(const char *list, int len, const char *s);
/* resolve "serial0" (an /aliases entry) or "/path" to a node */
int         fdt_resolve(const void *fdt, const char *path_or_alias);
/* the node whose "phandle" property is ph (what <&label> compiles to) */
int         fdt_node_by_phandle(const void *fdt, uint32_t ph);

int fdt_setprop(void *fdt, int capacity, int node, const char *name,
                const void *val, int len);
int fdt_setprop_string(void *fdt, int capacity, int node, const char *name, const char *s);

#endif
