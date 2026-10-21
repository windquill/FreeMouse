#include "include/ArchiveCodecs.h"
#include "../../ThirdParty/libarchive/archive.h"
#include "../../ThirdParty/libarchive/archive_entry.h"
#include "../../ThirdParty/zstd/lib/zstd.h"
#include "../../ThirdParty/lz4/lib/lz4frame.h"
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#define LIMIT ((uint64_t)20*1024*1024*1024)
#define BLOCK 65536
static int filter(struct archive *a,const char *id){
 if(!strcmp(id,"gz"))return archive_write_add_filter_gzip(a);
 if(!strcmp(id,"bz2"))return archive_write_add_filter_bzip2(a);
 if(!strcmp(id,"xz"))return archive_write_add_filter_xz(a);
 if(!strcmp(id,"lzma"))return archive_write_add_filter_lzma(a);
 return ARCHIVE_FATAL;
}
int fm_stream_available(const char *id){
 if(!strcmp(id,"zst")||!strcmp(id,"lz4"))return 1;
 struct archive *a=archive_write_new();int ok=filter(a,id)==ARCHIVE_OK;archive_write_free(a);return ok;
}
static int put(int fd,const void *p,size_t n,uint64_t *total){
 if(n>LIMIT-*total)return -1;*total+=n;
 while(n){ssize_t w=write(fd,p,n);if(w<=0)return -1;p=(const char *)p+w;n-=w;}return 0;
}
static int magic(const char *id,const unsigned char *p,size_t n){
 if(!strcmp(id,"gz"))return n>=2&&p[0]==31&&p[1]==139;
 if(!strcmp(id,"bz2"))return n>=3&&!memcmp(p,"BZh",3);
 if(!strcmp(id,"xz")){const unsigned char m[]={253,55,122,88,90,0};return n>=6&&!memcmp(p,m,6);}
 if(!strcmp(id,"zst")){const unsigned char m[]={40,181,47,253};return n>=4&&!memcmp(p,m,4);}
 if(!strcmp(id,"lz4")){const unsigned char m[]={4,34,77,24};return n>=4&&!memcmp(p,m,4);}
 if(!strcmp(id,"lzma"))return n>=13&&p[0]<225&&p[1]==0;return 0;
}
/* libarchive's bzip2 reader accepts a truncated empty stream. Require the
   bit-aligned end marker and combined CRC before allowing it to publish. */
static int bzip_footer(int fd,off_t length){
 if(length<14)return 0;
 unsigned char tail[11];size_t count=length<11?(size_t)length:11;
 if(pread(fd,tail,count,length-count)!=(ssize_t)count)return 0;
 for(int pad=0;pad<8;pad++){
  int start=(int)count*8-80-pad;if(start<0)continue;
  uint64_t marker=0;
  for(int i=0;i<48;i++){int bit=start+i;marker=(marker<<1)|((tail[bit/8]>>(7-bit%8))&1);}
  if(marker!=UINT64_C(0x177245385090))continue;
  if(pad && (tail[count-1]&((1u<<pad)-1)))continue;
  return 1;
 }
 return 0;
}
static int run(const char *id,const char *input,const char *output,int decode,char *error,size_t size){
 int in=-1,out=-1,ok=0;unsigned char src[BLOCK],dst[BLOCK*2];uint64_t total=0,readtotal=0;
 struct archive *a=NULL;ZSTD_CCtx *zc=NULL;ZSTD_DCtx *zd=NULL;LZ4F_cctx *lc=NULL;LZ4F_dctx *ld=NULL;
 in=open(input,O_RDONLY|O_NOFOLLOW);struct stat st;
 if(in<0||fstat(in,&st)||!S_ISREG(st.st_mode)||(uint64_t)st.st_size>LIMIT)goto done;
 if(decode&&!strcmp(id,"bz2")&&!bzip_footer(in,st.st_size))goto done;
 if(decode){ssize_t n=read(in,src,16);if(n<0||!magic(id,src,(size_t)n)||lseek(in,0,SEEK_SET)<0)goto done;}
 out=open(output,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);if(out<0)goto done;
 if(!strcmp(id,"zst")||!strcmp(id,"lz4")){
  int z=!strcmp(id,"zst");size_t pending=1;
  if(z){if(decode){zd=ZSTD_createDCtx();if(!zd)goto done;if(ZSTD_isError(ZSTD_DCtx_setParameter(zd,ZSTD_d_windowLogMax,27)))goto done;}else{zc=ZSTD_createCCtx();if(!zc)goto done;}}
  else if(decode){if(LZ4F_isError(LZ4F_createDecompressionContext(&ld,LZ4F_VERSION)))goto done;}
  else{if(LZ4F_isError(LZ4F_createCompressionContext(&lc,LZ4F_VERSION)))goto done;size_t n=LZ4F_compressBegin(lc,dst,sizeof(dst),NULL);if(LZ4F_isError(n)||put(out,dst,n,&total))goto done;}
  for(;;){ssize_t nr=read(in,src,sizeof(src));if(nr<0)goto done;readtotal+=nr;if(readtotal>LIMIT)goto done;
   if(!nr&&decode){if(pending)goto done;break;}
   size_t pos=0;
   if(z){ZSTD_inBuffer ib={src,(size_t)nr,0};int full=0;do{ZSTD_outBuffer ob={dst,sizeof(dst),0};pending=decode?ZSTD_decompressStream(zd,&ob,&ib):ZSTD_compressStream2(zc,&ob,&ib,nr?ZSTD_e_continue:ZSTD_e_end);if(ZSTD_isError(pending)||put(out,dst,ob.pos,&total))goto done;full=ob.pos==ob.size;if(decode&&!nr)break;}while(ib.pos<ib.size||(decode&&pending&&full)||(!decode&&!nr&&pending));}
   else if(decode){
    int drain=0;
    do {
     size_t consumed=(size_t)nr-pos,produced=sizeof(dst);
     pending=LZ4F_decompress(ld,dst,&produced,src+pos,&consumed,NULL);
     if(LZ4F_isError(pending))goto done;
     /* A large block can leave decoded bytes buffered after all compressed
        input was consumed. Drain those bytes before requesting another read. */
     if(!consumed&&!produced){
      if(pos==(size_t)nr)break;
      goto done;
     }
     if(put(out,dst,produced,&total))goto done;
     pos+=consumed;
     drain=pending&&produced==sizeof(dst);
    }while(pos<(size_t)nr||drain);
   }
   else{size_t n=nr?LZ4F_compressUpdate(lc,dst,sizeof(dst),src,nr,NULL):LZ4F_compressEnd(lc,dst,sizeof(dst),NULL);if(LZ4F_isError(n)||put(out,dst,n,&total))goto done;}
   if(!nr){if(decode&&pending)goto done;break;}
  }ok=1;
 }else if(decode){
  a=archive_read_new();archive_read_support_filter_gzip(a);archive_read_support_filter_bzip2(a);archive_read_support_filter_xz(a);archive_read_support_filter_lzma(a);archive_read_support_format_raw(a);archive_read_support_format_empty(a);
  struct archive_entry *entry=NULL;if(archive_read_open_fd(a,in,BLOCK)!=ARCHIVE_OK)goto done;
  int header=archive_read_next_header(a,&entry);
  if(header==ARCHIVE_EOF&&archive_filter_count(a)>1){if(archive_read_close(a)!=ARCHIVE_OK)goto done;ok=1;goto done;}
  if(header!=ARCHIVE_OK)goto done;
  for(;;){la_ssize_t n=archive_read_data(a,src,sizeof(src));if(n<0)goto done;if(!n)break;if(put(out,src,n,&total))goto done;}if(archive_read_close(a)!=ARCHIVE_OK)goto done;ok=1;
 }else{
  a=archive_write_new();archive_write_set_bytes_per_block(a,0);if(archive_write_set_format_raw(a)!=ARCHIVE_OK||filter(a,id)!=ARCHIVE_OK||archive_write_open_fd(a,out)!=ARCHIVE_OK)goto done;
  struct archive_entry *e=archive_entry_new();archive_entry_set_pathname(e,"data");archive_entry_set_filetype(e,AE_IFREG);archive_entry_set_size(e,st.st_size);int r=archive_write_header(a,e);archive_entry_free(e);if(r!=ARCHIVE_OK)goto done;
  for(;;){ssize_t n=read(in,src,sizeof(src));if(n<0)goto done;if(!n)break;readtotal+=n;if(readtotal>LIMIT||archive_write_data(a,src,n)!=n)goto done;}if(archive_write_close(a)!=ARCHIVE_OK)goto done;ok=1;
 }
 done:
 if(!ok&&error&&size)snprintf(error,size,"%s",a&&archive_error_string(a)?archive_error_string(a):"压缩流无效、截断、超出限制或目标已存在");
 if(a){if(decode)archive_read_free(a);else archive_write_free(a);}ZSTD_freeCCtx(zc);ZSTD_freeDCtx(zd);if(lc)LZ4F_freeCompressionContext(lc);if(ld)LZ4F_freeDecompressionContext(ld);if(in>=0)close(in);if(out>=0){close(out);if(!ok)unlink(output);}return ok?0:-1;
}
int fm_stream_compress(const char *id,const char *input,const char *output,char *error,size_t size){return run(id,input,output,0,error,size);}
int fm_stream_decompress(const char *id,const char *input,const char *output,char *error,size_t size){return run(id,input,output,1,error,size);}
