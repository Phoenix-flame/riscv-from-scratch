/* =====================================================================
 * fdt.c  -  walk, query and edit a flattened device tree (see fdt.h)
 * ===================================================================== */
#include "fdt.h"
#include "lib.h"

#define ALIGN4(x)  (((x) + 3) & ~3)

static const char *strs(const void *fdt)  { return (const char *)fdt + fdt_hdr(fdt, 3); }
static const uint8_t *st(const void *fdt) { return (const uint8_t *)fdt + fdt_hdr(fdt, 2); }
static uint32_t be32_at(const void *p)    { return fdt32(*(const uint32_t *)p); }

int fdt_check(const void *fdt)
{
    if (((uintptr_t)fdt & 3) || fdt_hdr(fdt, 0) != FDT_MAGIC) return FDT_ERR_BADMAGIC;
    if (fdt_hdr(fdt, 6) > 17 || fdt_hdr(fdt, 5) < 17)         return FDT_ERR_BADMAGIC;
    uint32_t tot = fdt_totalsize(fdt);
    if (fdt_hdr(fdt, 2) + fdt_hdr(fdt, 9) > tot || fdt_hdr(fdt, 3) + fdt_hdr(fdt, 8) > tot)
        return FDT_ERR_BADSTRUCT;
    int next;
    if (fdt_next_tag(fdt, 0, &next) != FDT_BEGIN_NODE) return FDT_ERR_BADSTRUCT;
    return 0;
}

/* The tag at `off` (offsets are relative to the structure block); *next
 * is where the tag after it starts. Returns FDT_END on any overrun. */
int fdt_next_tag(const void *fdt, int off, int *next)
{
    int size = (int)fdt_hdr(fdt, 9);
    if (off < 0 || off + 4 > size) return FDT_END;
    const uint8_t *p = st(fdt);
    uint32_t tag = be32_at(p + off);
    int n = off + 4;
    switch (tag) {
    case FDT_BEGIN_NODE:
        while (n < size && p[n]) n++;
        n = ALIGN4(n + 1);
        break;
    case FDT_PROP:
        if (n + 8 > size) return FDT_END;
        n = ALIGN4(n + 8 + (int)be32_at(p + n));
        break;
    case FDT_END_NODE: case FDT_NOP: case FDT_END:
        break;
    default:
        return FDT_END;
    }
    if (n > size) return FDT_END;
    *next = n;
    return (int)tag;
}

const char *fdt_get_name(const void *fdt, int node)
{
    return (const char *)st(fdt) + node + 4;
}

/* skip a whole node (its BEGIN at `node`); returns the offset after its END */
static int skip_node(const void *fdt, int node)
{
    int depth = 0, off = node, next, tag;
    do {
        tag = fdt_next_tag(fdt, off, &next);
        if (tag == FDT_BEGIN_NODE) depth++;
        else if (tag == FDT_END_NODE) depth--;
        else if (tag == FDT_END) return FDT_ERR_BADSTRUCT;
        off = next;
    } while (depth > 0);
    return off;
}

/* the first tag after `off` that is not a property or a NOP */
static int skip_props(const void *fdt, int off)
{
    int next, tag;
    for (;;) {
        tag = fdt_next_tag(fdt, off, &next);
        if (tag != FDT_PROP && tag != FDT_NOP) return off;
        off = next;
    }
}

int fdt_first_subnode(const void *fdt, int node)
{
    int next;
    if (fdt_next_tag(fdt, node, &next) != FDT_BEGIN_NODE) return FDT_ERR_BADSTRUCT;
    int off = skip_props(fdt, next);
    return fdt_next_tag(fdt, off, &next) == FDT_BEGIN_NODE ? off : FDT_ERR_NOTFOUND;
}

int fdt_next_subnode(const void *fdt, int node)
{
    int next, off = skip_node(fdt, node);
    if (off < 0) return off;
    while (fdt_next_tag(fdt, off, &next) == FDT_NOP) off = next;
    return fdt_next_tag(fdt, off, &next) == FDT_BEGIN_NODE ? off : FDT_ERR_NOTFOUND;
}

int fdt_first_prop(const void *fdt, int node)
{
    int next, tag;
    if (fdt_next_tag(fdt, node, &next) != FDT_BEGIN_NODE) return FDT_ERR_BADSTRUCT;
    int off = next;
    while ((tag = fdt_next_tag(fdt, off, &next)) == FDT_NOP) off = next;
    return tag == FDT_PROP ? off : FDT_ERR_NOTFOUND;
}

int fdt_next_prop(const void *fdt, int prop)
{
    int next, tag, off;
    fdt_next_tag(fdt, prop, &off);
    while ((tag = fdt_next_tag(fdt, off, &next)) == FDT_NOP) off = next;
    return tag == FDT_PROP ? off : FDT_ERR_NOTFOUND;
}

const void *fdt_prop_value(const void *fdt, int prop, const char **name, int *len)
{
    const uint8_t *p = st(fdt) + prop;
    if (len)  *len  = (int)be32_at(p + 4);
    if (name) *name = strs(fdt) + be32_at(p + 8);
    return p + 12;
}

const void *fdt_getprop(const void *fdt, int node, const char *name, int *len)
{
    for (int p = fdt_first_prop(fdt, node); p >= 0; p = fdt_next_prop(fdt, p)) {
        const char *n;
        const void *v = fdt_prop_value(fdt, p, &n, len);
        if (strcmp(n, name) == 0) return v;
    }
    return 0;
}

int fdt_getprop_u32(const void *fdt, int node, const char *name, uint32_t *val)
{
    int len;
    const void *v = fdt_getprop(fdt, node, name, &len);
    if (!v || len != 4) return FDT_ERR_NOTFOUND;
    *val = be32_at(v);
    return 0;
}

int fdt_stringlist_contains(const char *list, int len, const char *s)
{
    int n = (int)strlen(s) + 1;
    for (int i = 0; i < len; ) {
        int l = (int)strlen(list + i) + 1;
        if (l == n && memcmp(list + i, s, n) == 0) return 1;
        i += l;
    }
    return 0;
}

/* "uart" matches "uart" and "uart@1000"; "uart@1000" only itself */
static int name_matches(const char *name, const char *comp, int clen)
{
    if (strncmp(name, comp, clen) != 0) return 0;
    return name[clen] == '\0' || (name[clen] == '@' && !memchr(comp, '@', clen));
}

int fdt_path_offset(const void *fdt, const char *path)
{
    if (*path != '/') return FDT_ERR_NOTFOUND;
    int node = 0;
    while (*path) {
        while (*path == '/') path++;
        if (!*path) break;
        const char *end = path;
        while (*end && *end != '/') end++;
        int sub;
        for (sub = fdt_first_subnode(fdt, node); sub >= 0; sub = fdt_next_subnode(fdt, sub))
            if (name_matches(fdt_get_name(fdt, sub), path, (int)(end - path))) break;
        if (sub < 0) return FDT_ERR_NOTFOUND;
        node = sub;
        path = end;
    }
    return node;
}

int fdt_resolve(const void *fdt, const char *p)
{
    char buf[64];
    int n = 0;
    while (p[n] && p[n] != ':' && n < (int)sizeof buf - 1) { buf[n] = p[n]; n++; }  /* "serial0:115200n8" */
    buf[n] = '\0';
    if (buf[0] == '/') return fdt_path_offset(fdt, buf);
    int aliases = fdt_path_offset(fdt, "/aliases");
    if (aliases < 0) return aliases;
    const char *target = fdt_getprop(fdt, aliases, buf, 0);
    return target ? fdt_path_offset(fdt, target) : FDT_ERR_NOTFOUND;
}

int fdt_node_by_phandle(const void *fdt, uint32_t ph)
{
    int off = 0, next, tag;
    while ((tag = fdt_next_tag(fdt, off, &next)) != FDT_END) {
        uint32_t v;
        if (tag == FDT_BEGIN_NODE && fdt_getprop_u32(fdt, off, "phandle", &v) == 0 && v == ph)
            return off;
        off = next;
    }
    return FDT_ERR_NOTFOUND;
}

/* ---- editing ----------------------------------------------------------
 * Only the layout dtc produces is accepted -- header, reservation map,
 * structure block, strings block, in that order, the strings block
 * ending the blob -- so that moving bytes at a point inside the
 * structure block only ever has to move the strings block with it. */
static int layout_ok(const void *fdt)
{
    uint32_t rsv = fdt_hdr(fdt, 4), so = fdt_hdr(fdt, 2), ss = fdt_hdr(fdt, 9),
             to = fdt_hdr(fdt, 3), ts = fdt_hdr(fdt, 8);
    return rsv < so && so + ss <= to && to + ts == fdt_totalsize(fdt);
}

static void set_hdr(void *fdt, int field, uint32_t v) { ((uint32_t *)fdt)[field] = cpu_to_fdt32(v); }

/* open (delta > 0) or close (delta < 0) a gap at structure offset `at` */
static int splice(void *fdt, int capacity, int at, int delta)
{
    uint32_t tot = fdt_totalsize(fdt);
    if ((int)tot + delta > capacity) return FDT_ERR_NOSPACE;
    uint8_t *p = (uint8_t *)fdt + fdt_hdr(fdt, 2) + at;
    int tail = (int)tot - (int)(p - (uint8_t *)fdt);
    if (delta < 0) tail += delta;
    memmove(p + (delta > 0 ? delta : 0), p + (delta > 0 ? 0 : -delta), tail);
    set_hdr(fdt, 9, fdt_hdr(fdt, 9) + delta);           /* size_dt_struct */
    set_hdr(fdt, 3, fdt_hdr(fdt, 3) + delta);           /* off_dt_strings */
    set_hdr(fdt, 1, tot + delta);                       /* totalsize */
    return 0;
}

/* offset of `name` in the strings block, appending it if it is not there */
static int string_offset(void *fdt, int capacity, const char *name)
{
    const char *s = strs(fdt);
    int size = (int)fdt_hdr(fdt, 8), n = (int)strlen(name) + 1;
    for (int i = 0; i + n <= size; i++)
        if (memcmp(s + i, name, n) == 0) return i;
    if ((int)fdt_totalsize(fdt) + n > capacity) return FDT_ERR_NOSPACE;
    memcpy((char *)s + size, name, n);
    set_hdr(fdt, 8, size + n);
    set_hdr(fdt, 1, fdt_totalsize(fdt) + n);
    return size;
}

int fdt_setprop(void *fdt, int capacity, int node, const char *name, const void *val, int len)
{
    if (!layout_ok(fdt)) return FDT_ERR_BADLAYOUT;
    int prop, olen = 0;
    for (prop = fdt_first_prop(fdt, node); prop >= 0; prop = fdt_next_prop(fdt, prop)) {
        const char *n;
        fdt_prop_value(fdt, prop, &n, &olen);
        if (strcmp(n, name) == 0) break;
    }
    int err;
    if (prop >= 0) {                                    /* resize it in place */
        int keep = ALIGN4(len) < ALIGN4(olen) ? ALIGN4(len) : ALIGN4(olen);
        err = splice(fdt, capacity, prop + 12 + keep, ALIGN4(len) - ALIGN4(olen));
    } else {                                            /* a new first property */
        int nameoff = string_offset(fdt, capacity, name);
        if (nameoff < 0) return nameoff;
        int next;
        fdt_next_tag(fdt, node, &next);
        prop = next;
        err = splice(fdt, capacity, prop, 12 + ALIGN4(len));
        if (!err) {
            uint32_t *w = (uint32_t *)((uint8_t *)fdt + fdt_hdr(fdt, 2) + prop);
            w[0] = cpu_to_fdt32(FDT_PROP);
            w[2] = cpu_to_fdt32((uint32_t)nameoff);
        }
    }
    if (err) return err;
    uint8_t *p = (uint8_t *)fdt + fdt_hdr(fdt, 2) + prop;
    ((uint32_t *)p)[1] = cpu_to_fdt32((uint32_t)len);
    memcpy(p + 12, val, len);
    memset(p + 12 + len, 0, ALIGN4(len) - len);
    return 0;
}

int fdt_setprop_string(void *fdt, int capacity, int node, const char *name, const char *s)
{
    return fdt_setprop(fdt, capacity, node, name, s, (int)strlen(s) + 1);
}
