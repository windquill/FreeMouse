#ifndef FM_ARCHIVE_CODECS_H
#define FM_ARCHIVE_CODECS_H
#include <stddef.h>
int fm_stream_available(const char *id);
int fm_stream_compress(const char *id,const char *input,const char *output,char *error,size_t size);
int fm_stream_decompress(const char *id,const char *input,const char *output,char *error,size_t size);
#endif
