#include "include/ArchiveBridge.h"
#include "../../ThirdParty/libarchive/archive.h"
#include "../../ThirdParty/libarchive/archive_entry.h"
#include <sys/stat.h>
#include <sys/types.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define FM_MAX_ENTRIES 100000
#define FM_MAX_BYTES ((uint64_t)20 * 1024 * 1024 * 1024)
static void failure(char *out, size_t size, const char *text) {
    if (out && size) snprintf(out, size, "%s", text ? text : "归档操作失败");
}
static int configure(struct archive *a, const char *format) {
    int r = ARCHIVE_FATAL;
    if (!strcmp(format,"zip")) return archive_write_set_format_zip(a);
    if (!strcmp(format,"7z")) return archive_write_set_format_7zip(a);
    if (!strcmp(format,"xar")) return archive_write_set_format_xar(a);
    if (!strncmp(format,"tar",3)) r = archive_write_set_format_pax_restricted(a);
    else if (!strncmp(format,"cpio",4)) r = archive_write_set_format_cpio_newc(a);
    if (r != ARCHIVE_OK) return r;
    if (!strcmp(format,"tar") || !strcmp(format,"cpio")) return archive_write_add_filter_none(a);
    const char *suffix = strchr(format,'.');
    if (!suffix) return ARCHIVE_FATAL;
    if (!strcmp(suffix,".gz")) return archive_write_add_filter_gzip(a);
    if (!strcmp(suffix,".bz2")) return archive_write_add_filter_bzip2(a);
    if (!strcmp(suffix,".xz")) return archive_write_add_filter_xz(a);
    if (!strcmp(suffix,".lzma")) return archive_write_add_filter_lzma(a);
    if (!strcmp(suffix,".zst")) return archive_write_add_filter_zstd(a);
    if (!strcmp(suffix,".lz4")) return archive_write_add_filter_lz4(a);
    if (!strcmp(suffix,".Z")) return archive_write_add_filter_compress(a);
    return ARCHIVE_FATAL;
}
static void native_read_filters(struct archive *reader);
static void native_read_formats(struct archive *reader) {
    const int codes[]={ARCHIVE_FORMAT_TAR,ARCHIVE_FORMAT_ZIP,ARCHIVE_FORMAT_7ZIP,
        ARCHIVE_FORMAT_RAR,ARCHIVE_FORMAT_RAR_V5,ARCHIVE_FORMAT_CPIO,ARCHIVE_FORMAT_XAR,
        ARCHIVE_FORMAT_ISO9660,ARCHIVE_FORMAT_CAB,ARCHIVE_FORMAT_LHA,ARCHIVE_FORMAT_AR,
        ARCHIVE_FORMAT_WARC};
    for(size_t i=0;i<sizeof(codes)/sizeof(codes[0]);i++)
        archive_read_support_format_by_code(reader,codes[i]);
}
int fm_archive_available(const char *format) {
    /* Apple's current XAR writer pads short later files with zeros. Keep read
       support, but do not offer creation until native output is reliable. */
    if (!strcmp(format,"xar")) return 0;
    struct archive *a = archive_write_new();
    if (!a) return 0;
    size_t used=0;
    void *buffer=malloc(65536);
    int ok = configure(a,format) == ARCHIVE_OK;
    if (ok) ok = buffer && archive_write_open_memory(a,buffer,65536,&used) == ARCHIVE_OK;
    const char *names[]={"first.txt","second.txt"};
    const char *contents[]={"first payload","x"};
    for (int i=0;ok && i<2;i++) {
        struct archive_entry *entry=archive_entry_new();
        archive_entry_set_pathname(entry,names[i]);
        archive_entry_set_filetype(entry,AE_IFREG);
        archive_entry_set_perm(entry,0644);
        archive_entry_set_size(entry,strlen(contents[i]));
        archive_entry_set_ino64(entry,i+1);
        archive_entry_set_nlink(entry,1);
        ok=archive_write_header(a,entry)==ARCHIVE_OK;
        archive_entry_free(entry);
        if(ok) ok=archive_write_data(a,contents[i],strlen(contents[i]))==(la_ssize_t)strlen(contents[i]);
        if(ok) ok=archive_write_finish_entry(a)==ARCHIVE_OK;
    }
    if (ok) ok = archive_write_close(a) == ARCHIVE_OK;
    archive_write_free(a);
    /* Verify multi-file output too: some system XAR writers pad later files. */
    struct archive *reader=archive_read_new();
    if (!reader) ok=0;
    if(ok) {
        native_read_filters(reader); native_read_formats(reader);
        ok=archive_read_open_memory(reader,buffer,used)==ARCHIVE_OK;
        for(int i=0;ok && i<2;i++) {
            struct archive_entry *entry;
            ok=archive_read_next_header(reader,&entry)==ARCHIVE_OK;
            char data[64];
            if(ok) {
                la_ssize_t n=archive_read_data(reader,data,sizeof(data));
                ok=n==(la_ssize_t)strlen(contents[i]) && !memcmp(data,contents[i],(size_t)n);
            }
        }
    }
    if(reader) archive_read_free(reader);
    free(buffer);
    return ok;
}
static int metadata(const char *name) {
    const char *excluded[] = {"__MACOSX", "__MACOS", ".AppleDouble", ".localized", ".DS_Store", ".Spotlight-V100", ".Trashes", ".fseventsd", ".TemporaryItems", ".VolumeIcon.icns", NULL};
    if (!strncmp(name,"._",2)) return 1;
    for (size_t i=0; excluded[i]; i++) if (!strcmp(name,excluded[i])) return 1;
    return 0;
}
struct write_state { struct archive *a; uint64_t bytes; size_t entries; char *error; size_t error_size; dev_t output_dev; ino_t output_ino; };
static int add_path(struct write_state *s, int parent, const char *disk_name, const char *name, unsigned depth) {
    if (depth > 256) { failure(s->error,s->error_size,"目录层级过深"); return -1; }
    const char *base = strrchr(name,'/'); base = base ? base+1 : name;
    if (metadata(base)) return 0;
    struct stat st;
    if (fstatat(parent,disk_name,&st,AT_SYMLINK_NOFOLLOW)) { failure(s->error,s->error_size,"无法读取源文件信息"); return -1; }
    if(st.st_dev==s->output_dev && st.st_ino==s->output_ino) { failure(s->error,s->error_size,"归档目标不能位于源目录内"); return -1; }
    if (!S_ISREG(st.st_mode) && !S_ISDIR(st.st_mode)) { failure(s->error,s->error_size,"不支持归档符号链接或特殊文件"); return -1; }
    if (++s->entries > FM_MAX_ENTRIES || (S_ISREG(st.st_mode) && ((uint64_t)st.st_size > FM_MAX_BYTES-s->bytes))) { failure(s->error,s->error_size,"归档超出文件数量或大小限制（100000 项 / 20 GiB）"); return -1; }
    struct archive_entry *entry = archive_entry_new();
    archive_entry_set_pathname_utf8(entry,name);
    archive_entry_set_filetype(entry,S_ISDIR(st.st_mode) ? AE_IFDIR : AE_IFREG);
    archive_entry_set_perm(entry,S_ISDIR(st.st_mode) ? 0755 : (st.st_mode & 0777));
    archive_entry_set_size(entry,S_ISREG(st.st_mode) ? st.st_size : 0);
    archive_entry_set_ino64(entry,st.st_ino);
    archive_entry_set_nlink(entry,1);
    archive_entry_set_mtime(entry,st.st_mtime,0);
    int r = archive_write_header(s->a,entry);
    archive_entry_free(entry);
    if (r != ARCHIVE_OK) { failure(s->error,s->error_size,archive_error_string(s->a)); return -1; }
    if (S_ISDIR(st.st_mode)) {
        int opened_dir=openat(parent,disk_name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);
        struct stat pinned;
        if(opened_dir<0 || fstat(opened_dir,&pinned) || pinned.st_ino!=st.st_ino || pinned.st_dev!=st.st_dev) {
            if(opened_dir>=0) close(opened_dir);
            failure(s->error,s->error_size,"源目录在归档过程中发生变化"); return -1;
        }
        DIR *dir = fdopendir(opened_dir);
        if(!dir) close(opened_dir);
        if (!dir) { failure(s->error,s->error_size,"无法读取源目录"); return -1; }
        struct dirent *child; int result = 0;
        while ((child = readdir(dir))) {
            if (!strcmp(child->d_name,".") || !strcmp(child->d_name,"..")) continue;
            char *childname = NULL;
            if (asprintf(&childname,"%s/%s",name,child->d_name)<0) { result=-1; break; }
            result = add_path(s,dirfd(dir),child->d_name,childname,depth+1);
            free(childname);
            if (result) break;
        }
        closedir(dir); return result;
    }
    int fd = openat(parent,disk_name,O_RDONLY|O_NOFOLLOW);
    if (fd<0) { failure(s->error,s->error_size,"无法打开源文件"); return -1; }
    struct stat opened;
    if (fstat(fd,&opened) || !S_ISREG(opened.st_mode) || opened.st_dev!=st.st_dev || opened.st_ino!=st.st_ino || opened.st_size!=st.st_size) { close(fd); failure(s->error,s->error_size,"源文件在归档过程中发生变化"); return -1; }
    char buffer[65536]; off_t total=0; ssize_t n; int result=0;
    while ((n=read(fd,buffer,sizeof(buffer)))>0) {
        total+=n;
        if (total>st.st_size || (uint64_t)n>FM_MAX_BYTES-s->bytes) { result=-1; break; }
        s->bytes+=(uint64_t)n;
        if (archive_write_data(s->a,buffer,(size_t)n)!=n) { result=-1; break; }
    }
    if (n<0 || total!=st.st_size) result=-1;
    close(fd);
    if(archive_write_finish_entry(s->a)!=ARCHIVE_OK) result=-1;
    if (result) failure(s->error,s->error_size,"源文件读取失败、发生变化或归档写入失败");
    return result;
}
int fm_archive_compress(const char *const *paths, size_t count, const char *format, const char *output, char *error, size_t error_size) {
    struct archive *a=archive_write_new();
    int fd=-1, result=-1;
    if (!a || configure(a,format)!=ARCHIVE_OK) { failure(error,error_size,"本机不支持创建此归档格式"); goto done; }
    archive_write_set_bytes_per_block(a,0);
    fd=open(output,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);
    if (fd<0) { failure(error,error_size,"无法独占创建归档临时文件"); goto done; }
    if (archive_write_open_fd(a,fd)!=ARCHIVE_OK) { failure(error,error_size,archive_error_string(a)); goto done; }
    struct stat output_stat;
    if(fstat(fd,&output_stat)) { failure(error,error_size,"无法检查归档临时文件"); goto done; }
    struct write_state state={a,0,0,error,error_size,output_stat.st_dev,output_stat.st_ino};
    for (size_t i=0;i<count;i++) {
        const char *base=strrchr(paths[i],'/'); base=base ? base+1 : paths[i];
        char *parent_path=strdup(paths[i]);
        if(!parent_path) goto done;
        char *slash=strrchr(parent_path,'/');
        if(slash) { if(slash==parent_path) slash[1]=0; else *slash=0; }
        else strcpy(parent_path,".");
        int parent=open(parent_path,O_RDONLY|O_DIRECTORY);
        free(parent_path);
        if(parent<0) { failure(error,error_size,"无法读取源目录"); goto done; }
        int added=!*base || !strcmp(base,".") || !strcmp(base,"..") ? -1 : add_path(&state,parent,base,base,0);
        close(parent);
        if(added) goto done;
    }
    if (archive_write_close(a)!=ARCHIVE_OK) { failure(error,error_size,archive_error_string(a)); goto done; }
    result=0;
done:
    if (a) archive_write_free(a);
    if (fd>=0) close(fd);
    return result;
}
/* Every parent is traversed by directory descriptor with O_NOFOLLOW. */
static int entry_parent(int root, char *path, char **leaf, size_t *created) {
    if (!path || !*path || path[0]=='/' || strchr(path,'\\')) return -1;
    size_t length=strlen(path);
    while (length && path[length-1]=='/') path[--length]=0;
    if (!length) return -1;
    int fd=dup(root); if(fd<0) return -1;
    char *part=path;
    for (;;) {
        char *slash=strchr(part,'/'); if(slash) *slash=0;
        if (!*part || !strcmp(part,"..") || !strcmp(part,".") || strchr(part,':')) { close(fd); return -1; }
        if(!slash) { *leaf=part; return fd; }
        if(!mkdirat(fd,part,0755)) { if(++*created>FM_MAX_ENTRIES) { close(fd); return -1; } }
        else if(errno!=EEXIST) { close(fd); return -1; }
        int next=openat(fd,part,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);
        close(fd); if(next<0) return -1; fd=next; part=slash+1;
    }
}
/* Normalize relative POSIX names, while rejecting every parent traversal. */
static int normalize_path(char *path) {
    if (!*path || path[0]=='/' || strchr(path,'\\')) return -1;
    char *read=path, *write=path; unsigned depth=0;
    while (*read) {
        while (*read=='/') read++;
        if (!*read) break;
        char *end=strchr(read,'/');
        size_t length=end ? (size_t)(end-read) : strlen(read);
        if (length==2 && read[0]=='.' && read[1]=='.') return -1;
        if (!(length==1 && read[0]=='.')) {
            if(++depth>256) return -1;
            if (memchr(read,':',length)) return -1;
            if (write!=path) *write++='/';
            memmove(write,read,length); write+=length;
        }
        read=end ? end+1 : read+length;
    }
    *write=0;
    return 0;
}
static void native_read_filters(struct archive *reader) {
    const int codes[]={ARCHIVE_FILTER_NONE,ARCHIVE_FILTER_GZIP,ARCHIVE_FILTER_BZIP2,
        ARCHIVE_FILTER_COMPRESS,ARCHIVE_FILTER_LZMA,ARCHIVE_FILTER_XZ,ARCHIVE_FILTER_UU,
        ARCHIVE_FILTER_RPM,ARCHIVE_FILTER_LZIP,ARCHIVE_FILTER_LZ4,ARCHIVE_FILTER_ZSTD};
    for (size_t i=0;i<sizeof(codes)/sizeof(codes[0]);i++) {
        struct archive *probe=archive_read_new();
        if (!probe) continue;
        /* WARN means libarchive would invoke an external program. Never install it. */
        if (archive_read_support_filter_by_code(probe,codes[i])==ARCHIVE_OK)
            archive_read_support_filter_by_code(reader,codes[i]);
        archive_read_free(probe);
    }
}
int fm_archive_extract(const char *input, const char *output_directory, char *error, size_t error_size) {
    struct archive *a=archive_read_new();
    int root=-1, result=-1; size_t count=0, created=0; uint64_t total=0;
    if (!a) { failure(error,error_size,"无法初始化归档读取器"); goto done; }
    native_read_filters(a); native_read_formats(a);
    if (archive_read_open_filename(a,input,65536)!=ARCHIVE_OK) { failure(error,error_size,archive_error_string(a)); goto done; }
    root=open(output_directory,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);
    if(root<0) { failure(error,error_size,"无法打开解压暂存目录"); goto done; }
    struct archive_entry *entry; int status;
    while((status=archive_read_next_header(a,&entry))==ARCHIVE_OK) {
        if(++count>FM_MAX_ENTRIES) { failure(error,error_size,"归档项目超过 100000 项限制"); goto done; }
        const char *raw=archive_entry_pathname_utf8(entry);
        if(!raw) raw=archive_entry_pathname(entry);
        int type=archive_entry_filetype(entry);
        if(!raw || archive_entry_symlink(entry) || archive_entry_hardlink(entry) || (type!=AE_IFREG && type!=AE_IFDIR)) { failure(error,error_size,"归档包含链接或特殊文件，已拒绝解压"); goto done; }
        if (archive_entry_size(entry)<0 || (uint64_t)archive_entry_size(entry)>FM_MAX_BYTES-total) { failure(error,error_size,"解压内容超过 20 GiB 限制"); goto done; }
        char *path=strdup(raw), *leaf=NULL;
        if(!path || normalize_path(path)) { free(path); failure(error,error_size,"归档包含不安全路径"); goto done; }
        if(!*path && type==AE_IFDIR) { free(path); continue; }
        int parent=entry_parent(root,path,&leaf,&created);
        if(parent<0) { free(path); failure(error,error_size,"归档包含不安全路径或路径冲突"); goto done; }
        if(type==AE_IFDIR) {
            int ok=mkdirat(parent,leaf,0755);
            if(!ok && ++created>FM_MAX_ENTRIES) {
                close(parent); free(path);
                failure(error,error_size,"解压创建项目超过 100000 项限制"); goto done;
            }
            if(ok && errno==EEXIST) { int check=openat(parent,leaf,O_RDONLY|O_DIRECTORY|O_NOFOLLOW); ok=check<0 ? -1 : 0; if(check>=0) close(check); }
            close(parent); free(path);
            if(ok) { failure(error,error_size,"归档目录路径冲突"); goto done; }
            continue;
        }
        int fd=openat(parent,leaf,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);
        close(parent); free(path);
        if(fd<0) { failure(error,error_size,"归档文件重名或路径冲突"); goto done; }
        if(++created>FM_MAX_ENTRIES) { close(fd); failure(error,error_size,"解压创建项目超过 100000 项限制"); goto done; }
        char buffer[65536]; la_ssize_t n; int bad=0;
        while((n=archive_read_data(a,buffer,sizeof(buffer)))>0) {
            if((uint64_t)n>FM_MAX_BYTES-total) { bad=1; break; }
            total+=(uint64_t)n;
            size_t offset=0;
            while(offset<(size_t)n) { ssize_t written=write(fd,buffer+offset,(size_t)n-offset); if(written<=0) { bad=1; break; } offset+=(size_t)written; }
            if(bad) break;
        }
        /* Restore only ordinary rwx bits; never owner, ACL, xattrs or privilege bits. */
        if(fchmod(fd,archive_entry_perm(entry)&0777)) bad=1;
        close(fd);
        if(bad || n<0) { failure(error,error_size,"解压数据损坏、写入失败或超过 20 GiB 限制"); goto done; }
    }
    if(status!=ARCHIVE_EOF || archive_read_close(a)!=ARCHIVE_OK) { failure(error,error_size,"归档损坏或格式不受支持"); goto done; }
    result=0;
done:
    if(root>=0) close(root);
    if(a) archive_read_free(a);
    return result;
}
