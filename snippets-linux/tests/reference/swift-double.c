/* Original test harness. Upstream SwiftDtoa is a separate development reference,
 * never an application dependency. All generated numbers are public fixtures. */
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "swift/Runtime/SwiftDtoa.h"

static void emit(uint64_t bits) {
    if (((bits >> 52) & 2047) == 2047) return;
    char output[64];
    if (!swift_dtoa_optimal_binary64_p(&bits, output, sizeof(output))) return;
    printf("%016" PRIx64 "\t%s\n", bits, output);
}

int main(void) {
    uint64_t edges[] = {
        0, UINT64_C(0x8000000000000000), 1, UINT64_C(0x000fffffffffffff),
        UINT64_C(0x0010000000000000), UINT64_C(0x7fefffffffffffff),
        UINT64_C(0x4340000000000000), UINT64_C(0x4340000000000001),
        UINT64_C(0x433fffffffffffff)
    };
    for (size_t i = 0; i < sizeof(edges) / sizeof(*edges); i++) emit(edges[i]);
    uint64_t bits = UINT64_C(0x123456789abcdef0);
    for (int i = 0; i < 10000; i++) {
        bits ^= bits << 13; bits ^= bits >> 7; bits ^= bits << 17;
        emit(bits);
    }
    for (int i = -324; i < 309; i++) {
        char decimal[32];
        snprintf(decimal, sizeof(decimal), "1e%d", i);
        double value = strtod(decimal, NULL);
        uint64_t bits;
        memcpy(&bits, &value, sizeof(bits));
        emit(bits);
        if (bits > 0) emit(bits - 1);
        emit(bits + 1);
    }
}
