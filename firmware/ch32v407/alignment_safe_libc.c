/* The ESP GCC bundled newlib assumes hardware accepts unaligned word accesses.
 * QingKe V3V traps instead. Override the four affected routines used here.
 * Compile with -fno-builtin -fno-tree-loop-distribute-patterns -mstrict-align.
 * Word copies remain available when BOTH pointers are aligned, with no overread.
 */
#include <stddef.h>
#include <stdint.h>

typedef uint32_t alias_word __attribute__((__may_alias__));

void *memcpy(void *restrict dest, const void *restrict source, size_t n) {
    unsigned char *d = dest;
    const unsigned char *s = source;
    while (n && (((uintptr_t)d | (uintptr_t)s) & 3u)) {
        *d++ = *s++; --n;
    }
    while (n >= 4) {
        *(alias_word *)d = *(const alias_word *)s;
        d += 4; s += 4; n -= 4;
    }
    while (n--) *d++ = *s++;
    return dest;
}

void *memmove(void *dest, const void *source, size_t n) {
    unsigned char *d = dest;
    const unsigned char *s = source;
    if ((uintptr_t)d <= (uintptr_t)s) {
        /* Cannot call restrict-qualified memcpy when the regions overlap. */
        while (n && (((uintptr_t)d | (uintptr_t)s) & 3u)) {
            *d++ = *s++; --n;
        }
        while (n >= 4) {
            alias_word v = *(const alias_word *)s;
            *(alias_word *)d = v;
            d += 4; s += 4; n -= 4;
        }
        while (n--) *d++ = *s++;
    } else {
        d += n; s += n;
        while (n && (((uintptr_t)d | (uintptr_t)s) & 3u)) {
            *--d = *--s; --n;
        }
        while (n >= 4) {
            d -= 4; s -= 4;
            alias_word v = *(const alias_word *)s;
            *(alias_word *)d = v; n -= 4;
        }
        while (n--) *--d = *--s;
    }
    return dest;
}

int memcmp(const void *left, const void *right, size_t n) {
    const unsigned char *a = left, *b = right;
    while (n && (((uintptr_t)a | (uintptr_t)b) & 3u)) {
        int delta = (int)*a++ - (int)*b++;
        if (delta) return delta;
        --n;
    }
    while (n >= 4 && *(const alias_word *)a == *(const alias_word *)b) {
        a += 4; b += 4; n -= 4;
    }
    while (n--) {
        int delta = (int)*a++ - (int)*b++;
        if (delta) return delta;
    }
    return 0;
}

int strcmp(const char *left, const char *right) {
    const unsigned char *a = (const unsigned char *)left;
    const unsigned char *b = (const unsigned char *)right;
    for (;;) {
        unsigned char x = *a++, y = *b++;
        if (x != y || !x) return (int)x - (int)y;
    }
}
