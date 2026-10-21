#ifndef FREEMOUSE_ARCHIVE_BRIDGE_H
#define FREEMOUSE_ARCHIVE_BRIDGE_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
int fm_archive_available(const char *format);
int fm_archive_compress(const char *const *paths, size_t count, const char *format, const char *output, char *error, size_t error_size);
int fm_archive_extract(const char *input, const char *output_directory, char *error, size_t error_size);
#ifdef __cplusplus
}
#endif
#endif
