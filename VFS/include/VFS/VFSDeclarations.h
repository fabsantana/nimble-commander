// Copyright (C) 2014-2017 Michael Kazakov. Subject to GNU General Public License version 3.
#pragma once

#include <string>

namespace VFSFlags
{
    constexpr unsigned long None                = 0x00000000;
    
    //  VFSFile opening-time flags
    constexpr unsigned long OF_IXOth            = 0x00000001; // = S_IXOTH
    constexpr unsigned long OF_IWOth            = 0x00000002; // = S_IWOTH
    constexpr unsigned long OF_IROth            = 0x00000004; // = S_IROTH
    constexpr unsigned long OF_IXGrp            = 0x00000008; // = S_IXGRP
    constexpr unsigned long OF_IWGrp            = 0x00000010; // = S_IWGRP
    constexpr unsigned long OF_IRGrp            = 0x00000020; // = S_IRGRP
    constexpr unsigned long OF_IXUsr            = 0x00000040; // = S_IXUSR
    constexpr unsigned long OF_IWUsr            = 0x00000080; // = S_IWUSR
    constexpr unsigned long OF_IRUsr            = 0x00000100; // = S_IRUSR
    constexpr unsigned long OF_Read             = 0x00010000;
    constexpr unsigned long OF_Write            = 0x00020000;
    constexpr unsigned long OF_Create           = 0x00040000;
    constexpr unsigned long OF_NoExist          = 0x00080000; // POSIX O_EXCL actcually, for clarity
    constexpr unsigned long OF_ShLock           = 0x00100000; // not yet implemented
    constexpr unsigned long OF_ExLock           = 0x00200000; // not yet implemented
    constexpr unsigned long OF_NoCache          = 0x00400000; // turns off caching if supported
    constexpr unsigned long OF_Append           = 0x00800000; // appends file on writing
    constexpr unsigned long OF_Truncate         = 0x01000000; // truncates files upon opening
    constexpr unsigned long OF_Directory        = 0x02000000; // opens directory for xattr reading
        
    // Flags altering host behaviour
    /** do not follow symlinks when resolving item name */
    constexpr unsigned long F_NoFollow          = 0x10000000;
        
    // Flags altering listing building
    /** for listing. don't fetch dot-dot entry in directory listing */
    constexpr unsigned long F_NoDotDot          = 0x20000000;
    
    /** for listing. ask system to provide localized display names */
    constexpr unsigned long F_LoadDisplayNames  = 0x40000000;
    
    /** discard caches when fetching information. */
    constexpr unsigned long F_ForceRefresh      = 0x80000000;
};

struct VFSStatFS
{
    uint64_t total_bytes = 0;
    uint64_t free_bytes  = 0;
    uint64_t avail_bytes = 0; // may be less than actuat free_bytes
    string   volume_name;
    
    bool operator==(const VFSStatFS& _r) const;
    bool operator!=(const VFSStatFS& _r) const;
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
    struct stat SysStat() const noexcept;
    inline static meaningT AllMeaning() { const uint64_t t = ~0ull; return *(meaningT*)&t; }
    inline static meaningT NoMeaning() { const uint64_t t = 0ull; return *(meaningT*)&t; }
};

class VFSErrorException : public exception
{
public:
    VFSErrorException( int _err );
    virtual const char* what() const noexcept override;
    int                 code() const noexcept;
private:
    int     m_Code;
    string  m_Verb;
};

struct VFSUser
{
    uint32_t uid;
    string name;
    string gecos;
};

struct VFSGroup
{
    uint32_t gid;
    string name;
    string gecos;
};

namespace nc::vfs {
    class Listing;
    class ListingItem;
    class WeakListingItem;
    class Host;
}

using VFSListing            = nc::vfs::Listing;
using VFSListingPtr         = shared_ptr<nc::vfs::Listing>;
using VFSListingItem        = nc::vfs::ListingItem;
using VFSWeakListingItem    = nc::vfs::WeakListingItem;
using VFSHost               = nc::vfs::Host;
using VFSHostPtr            = shared_ptr<nc::vfs::Host>;
using VFSHostWeakPtr        = weak_ptr<nc::vfs::Host>;

class VFSFile;
class VFSPath;
class VFSConfiguration;
typedef shared_ptr<VFSFile>         VFSFilePtr;
typedef function<bool()>            VFSCancelChecker;
