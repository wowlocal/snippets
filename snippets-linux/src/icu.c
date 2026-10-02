#include <unicode/udat.h>

/* ICU headers select the host's versioned ABI. No guessed symbol names. */
int32_t snippets_format_date(double millis, int kind, const char *locale,
                            const UChar *pattern, int32_t pattern_len,
                            UChar *output, int32_t capacity) {
    UErrorCode error = U_ZERO_ERROR;
    UDateFormatStyle time = pattern_len ? UDAT_PATTERN : (kind == 0 ? UDAT_NONE : UDAT_MEDIUM);
    UDateFormatStyle date = pattern_len ? UDAT_PATTERN : (kind == 1 ? UDAT_NONE : UDAT_MEDIUM);
    UDateFormat *format = udat_open(time, date, locale, NULL, 0, pattern, pattern_len, &error);
    if (U_FAILURE(error) || !format) return -1;
    int32_t length = udat_format(format, millis, output, capacity, NULL, &error);
    udat_close(format);
    return U_FAILURE(error) ? -1 : length;
}
