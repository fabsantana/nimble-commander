//
//  VFSHost.h
//  Files
//
//  Created by Michael G. Kazakov on 25.08.13.
//  Copyright (c) 2013 Michael G. Kazakov. All rights reserved.
//

#pragma once
#import <sys/stat.h>
#import "VFSError.h"
#import "chained_strings.h"

class VFSListing;
class VFSFile;

struct VFSStatFS
{
    uint64_t total_bytes = 0;
    uint64_t free_bytes  = 0;
    uint64_t avail_bytes = 0; // may be less than actuat free_bytes
    string   volume_name;
    
    inline bool operator==(const VFSStatFS& _r) const
    {
        return total_bytes == _r.total_bytes &&
                free_bytes == _r.free_bytes  &&
               avail_bytes == _r.avail_bytes &&
               volume_name == _r.volume_name;
    }
    
    inline bool operator!=(const VFSStatFS& _r) const
    {
        return total_bytes != _r.total_bytes ||
                free_bytes != _r.free_bytes  ||
               avail_bytes != _r.avail_bytes ||
               volume_name != _r.volume_name;
    }
};

struct VFSDirEnt
{
    enum {
        Unknown     =  0, /* = DT_UNKNOWN */
        FIFO        =  1, /* = DT_FIFO    */
        Char        =  2, /* = DT_CHR     */
        Dir         =  4, /* = DT_DIR     */
        Block       =  6, /* = DT_BLK     */
        Reg         =  8, /* = DT_REG     */
        Link        = 10, /* = DT_LNK     */
        Socket      = 12, /* = DT_SOCK    */
        Whiteout    = 14  /* = DT_WHT     */
    };
    
    uint16_t    type;
    uint16_t    name_len;
    char        name[1024];
};

struct VFSStat
{
    uint64_t    size;   /* File size, in bytes */
    uint64_t    blocks; /* blocks allocated for file */
    uint64_t    inode;  /* File serial number */
    int32_t     dev;    /* ID of device containing file */
    int32_t     rdev;   /* Device ID (if special file) */
    uint32_t    uid;    /* User ID of the file */
    uint32_t    gid;    /* Group ID of the file */
    int32_t     blksize;/* Optimal blocksize for I/O */
    uint32_t	flags;  /* User defined flags for file */
    union {
    uint16_t    mode;   /* Mode of file */
    struct {
        unsigned xoth : 1;
        unsigned woth : 1;
        unsigned roth : 1;
        unsigned xgrp : 1;
        unsigned wgrp : 1;
        unsigned rgrp : 1;
        unsigned xusr : 1;
        unsigned wusr : 1;
        unsigned rusr : 1;
        unsigned vtx  : 1;
        unsigned gid  : 1;
        unsigned uid  : 1;
        unsigned fifo : 1;
        unsigned chr  : 1;
        unsigned dir  : 1;
        unsigned reg  : 1;
    } __attribute__((packed)) mode_bits; /* Mode decomposed as flags*/
    };
    uint16_t    nlink;  /* Number of hard links */
	timespec    atime;  /* Time of last access */
	timespec    mtime;	/* Time of last data modification */
	timespec    ctime;	/* Time of last status change */
	timespec    btime;	/* Time of file creation(birth) */
    struct meaningT {
        unsigned size:   1;
        unsigned blocks: 1;
        unsigned inode:  1;
        unsigned dev:    1;
        unsigned rdev:   1;
        unsigned uid:    1;
        unsigned gid:    1;
        unsigned blksize:1;
        unsigned flags:  1;
        unsigned mode:   1;
        unsigned nlink:  1;
        unsigned atime:  1;
        unsigned mtime:  1;
        unsigned ctime:  1;
        unsigned btime:  1;
    } meaning;
    static void FromSysStat(const struct stat &_from, VFSStat &_to);
    static void ToSysStat(const VFSStat &_from, struct stat &_to);
    inline static meaningT AllMeaning() { const uint64_t t = ~0; return *(meaningT*)&t; }
};

struct VFSHostOptions
{
    virtual ~VFSHostOptions();
    virtual bool Equal(const VFSHostOptions &_r) const;
};

class VFSHost : public enable_shared_from_this<VFSHost>
{
public:
    VFSHost(const char *_junction_path,         // junction path and parent can be nil
            shared_ptr<VFSHost> _parent);
    virtual ~VFSHost();
    
    enum {
        F_Default           = 0x0000,
        F_NoFollow          = 0x0001, // do not follow symlinks when resolving item name
        F_NoDotDot          = 0x0002, // for listing. don't fetch dot-dot entry in directory listing
        F_LoadDisplayNames  = 0x0004  // for listing. ask system to provide localized display names
    };
    
    
    virtual bool IsWriteable() const;
    virtual bool IsWriteableAtPath(const char *_dir) const;
    
    /**
     * Each virtual file system must return a unique statically allocated identifier string.
     */
    virtual const char *FSTag() const;
    
    virtual bool IsNativeFS() const { return false; }
    
    /**
     * Returns a path of a filesystem root.
     * It may be a filepath for archive or network address for remote filesystem
     * or even zero thing for special virtual filesystems.
     */
    const char *JunctionPath() const;
    shared_ptr<VFSHost> Parent() const;
    
    
    
    virtual int StatFS(const char *_path, // path may be a file path, or directory path
                       VFSStatFS &_stat,
                       bool (^_cancel_checker)());
    
    /**
     * Default implementation calls Stat() and then returns (st.st_mode & S_IFMT) == S_IFDIR.
     * On any errors returns false.
     */
    virtual bool IsDirectory(const char *_path,
                             int _flags,
                             bool (^_cancel_checker)());

    virtual int FetchDirectoryListing(const char *_path,
                                      shared_ptr<VFSListing> *_target,
                                      int _flags,
                                      bool (^_cancel_checker)());
    
    /**
     * IterateDirectoryListing will skip "." and ".." entries if they are present.
     * Do not rely on it to build a directory listing, it's for contents iteration.
     */
    virtual int IterateDirectoryListing(
                                    const char *_path,
                                    function<bool(const VFSDirEnt &_dirent)> _handler // return true for allowing iteration, false to stop it
                                    );
    
    virtual int CreateFile(const char* _path,
                           shared_ptr<VFSFile> &_target,
                           bool (^_cancel_checker)() = nullptr);
    
    virtual int CreateDirectory(const char* _path,
                                int _mode,
                                bool (^_cancel_checker)()
                                );
    
    virtual int CalculateDirectoriesSizes(
                                        chained_strings _dirs,
                                        const char* _root_path,
                                        bool (^_cancel_checker)(),
                                        void (^_completion_handler)(const char* _dir_sh_name, uint64_t _size));
    
    virtual int Stat(const char *_path,
                     VFSStat &_st,
                     int _flags,
                     bool (^_cancel_checker)());
    
    /**
     * Actually calls Stat and returns true if return was Ok.
     */ 
    virtual bool Exists(const char *_path,
                        bool (^_cancel_checker)() = nil
                        );
    
    /**
     * Return zero upon succes, negative value on error.
     */
    virtual int ReadSymlink(const char *_symlink_path,
                            char *_buffer,
                            size_t _buffer_size,
                            bool (^_cancel_checker)());

    /**
     * Return zero upon succes, negative value on error.
     */
    virtual int CreateSymlink(const char *_symlink_path,
                              const char *_symlink_value,
                              bool (^_cancel_checker)());
    
    /**
     * Unlinkes(deletes) a file. Dont follow last symlink, in case of.
     * Don't delete a directories, similar to POSIX.
     */
    virtual int Unlink(const char *_path, bool (^_cancel_checker)());

    /**
     * Deletes and empty directory. Will fail on non-empty ones.
     */
    virtual int RemoveDirectory(const char *_path, bool (^_cancel_checker)());
    
    /**
     * Change the name of a file.
     */
    virtual int Rename(const char *_old_path, const char *_new_path, bool (^_cancel_checker)());
    
    /**
     * Adjust file node times. Any of timespec time pointers can be NULL, so they will be ignored.
     * NoFollow flag can be specified to alter symlink node itself.
     */
    virtual int SetTimes(const char *_path,
                         int _flags,
                         struct timespec *_birth_time,
                         struct timespec *_mod_time,
                         struct timespec *_chg_time,
                         struct timespec *_acc_time,
                         bool (^_cancel_checker)()
                         );
    
    /**
     * DO NOT USE IT. Currently for experimental purposes only.
     * Returns a vector with all xattrs at _path, labeled with it's names.
     * On any error return negative value.
     */
    virtual int GetXAttrs(const char *_path, vector< pair<string, vector<uint8_t>>> &_xattrs);
    
    /**
     * Returns readable host's address.
     * For example, for native fs it will be "".
     * For PSFS it will be like "psfs:"
     * For FTP it will be like "ftp://127.0.0.1"
     * For archive fs it will be path at parent fs like "/Users/migun/Downloads/1.zip"
     * Default implementation returns JunctionPath()
     */
    virtual string VerboseJunctionPath() const;
    
    /**
     * Returns options used to open current host, which later can be used to reconstruct this host.
     * This object should be immutable due to performance reasons.
     * Best of all it should return a shared object which is already used in host.
     * Can return nullptr, which is ok.
     */
    virtual shared_ptr<VFSHostOptions> Options() const;
    
    // return value 0 means error or unsupported for this VFS
    virtual unsigned long DirChangeObserve(const char *_path, void (^_handler)());
    virtual void StopDirChangeObserving(unsigned long _ticket);
    
    virtual bool ShouldProduceThumbnails() const;
    
    virtual bool FindLastValidItem(const char *_orig_path,
                                   char *_valid_path,
                                   int _flags,
                                   bool (^_cancel_checker)());

    static const shared_ptr<VFSHost> &DummyHost();
    
    inline shared_ptr<VFSHost> SharedPtr() { return shared_from_this(); }
    inline shared_ptr<const VFSHost> SharedPtr() const { return shared_from_this(); }
#define VFS_DECLARE_SHARED_PTR(_cl)\
    shared_ptr<const _cl> SharedPtr() const {return static_pointer_cast<const _cl>(VFSHost::SharedPtr());}\
    shared_ptr<_cl> SharedPtr() {return static_pointer_cast<_cl>(VFSHost::SharedPtr());}

private:
    string m_JunctionPath;         // path in Parent VFS, relative to it's root
    shared_ptr<VFSHost> m_Parent;
    
    // forbid copying
    VFSHost(const VFSHost& _r) = delete;
    void operator=(const VFSHost& _r) = delete;
};

typedef shared_ptr<VFSHost> VFSHostPtr;
typedef shared_ptr<VFSHostOptions> VFSHostOptionsPtr;
