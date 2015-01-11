//
//  FileCopyOperationJobNativeToNative.cpp
//  Directories
//
//  Created by Michael G. Kazakov on 09.04.13.
//  Copyright (c) 2013 Michael G. Kazakov. All rights reserved.
//

#import "FileCopyOperationJobNativeToNative.h"
#import "filesysinfo.h"
#import "NativeFSManager.h"
#import <sys/types.h>
#import <sys/dirent.h>
#import <sys/stat.h>
#import <dirent.h>
#import <sys/time.h>
#import <sys/xattr.h>
#import <sys/attr.h>
#import <sys/vnode.h>
#import <sys/param.h>
#import <sys/mount.h>
#import <unistd.h>
#import <stdlib.h>
#import "Common.h"
#import "common_paths.h"
#import "RoutedIO.h"

#define BUFFER_SIZE (512*1024) // 512kb
#define MIN_PREALLOC_SIZE (4096) // will try to preallocate files only if they are larger than 4k

// assumes that _fn1 is a valid file/dir name, or will return false immediately
// if _fn2 is not a valid path name will look at _fallback_second.
//  if _fallback_second is true this routine will go upper to the root until the valid path is reached
//  otherwise it will return false
// when two valid paths is achieved it calls FetchFileSystemRootFromPath and compares two roots
// TODO: how do we need to treat symlinks in this procedure?
static bool CheckSameVolume(const char *_fn1, const char*_fn2, bool &_same, bool _fallback_second = true)
{
    // accept only full paths
    if(_fn1[0] != '/' || _fn2[0] != '/' )
        return false;
    
    auto &io = RoutedIO::Default;
    
    struct stat st;
    if(io.stat(_fn1, &st) == -1)
        return false;
 
    char fn2[MAXPATHLEN];
    strcpy(fn2, _fn2);

    while(io.stat(fn2, &st) == -1)
    {
        if(!_fallback_second)
            return false;
        
        assert(fn2[1] != 0);   // that is an absolutely weird case if can't access "/" path.
                               // in this situation it's better to stop working at all

        char *s = strrchr(fn2, '/');
        if(s == fn2)
            s++; // non regular case for topmost entries

        *s = 0;
    }

    auto volume1 = NativeFSManager::Instance().VolumeFromPath(_fn1);
    auto volume2 = NativeFSManager::Instance().VolumeFromPath(fn2);
    if(!volume1 || !volume2) return false;

    _same = volume1.get() == volume2.get();

    return true;
}

static inline bool CanBeExternalEA(const char *_short_filename)
{
    return  _short_filename[0] == '.' &&
    _short_filename[1] == '_' &&
    _short_filename[2] != 0;
}

static inline bool EAHasMainFile(const char *_full_ea_path)
{
    auto &io = RoutedIO::Default;
    
    char tmp[MAXPATHLEN];
    strcpy(tmp, _full_ea_path);
    
    char *last_dst = strrchr(tmp, '/');
    const char *last_src = strrchr(_full_ea_path, '/'); // suboptimal
    
    strcpy(last_dst + 1, last_src + 3);
    
    struct stat st;
    return io.lstat(tmp, &st) == 0;
}

static void AdjustFileTimes(int _target_fd, struct stat *_with_times)
{
    struct attrlist attrs;
    memset(&attrs, 0, sizeof(attrs));
    attrs.bitmapcount = ATTR_BIT_MAP_COUNT;
    
    attrs.commonattr = ATTR_CMN_MODTIME;
    fsetattrlist(_target_fd, &attrs, &_with_times->st_mtimespec, sizeof(struct timespec), 0);
    
    attrs.commonattr = ATTR_CMN_CRTIME;
    fsetattrlist(_target_fd, &attrs, &_with_times->st_birthtimespec, sizeof(struct timespec), 0);
    
    attrs.commonattr = ATTR_CMN_ACCTIME;
    fsetattrlist(_target_fd, &attrs, &_with_times->st_atimespec, sizeof(struct timespec), 0);
    
    attrs.commonattr = ATTR_CMN_CHGTIME;
    fsetattrlist(_target_fd, &attrs, &_with_times->st_ctimespec, sizeof(struct timespec), 0);
}

FileCopyOperationJobNativeToNative::FileCopyOperationJobNativeToNative()
{
    // in xattr operations we'll use our big Buf1 and Buf2 - they should be quite enough
    // in OS X 10.4-10.6 maximum size of xattr value was 4Kb
    // in OS X 10.7(or in 10.8?) it was increased to 128Kb
    assert( BUFFER_SIZE >= 128 * 1024 ); // should be enough to hold any xattr value
}

FileCopyOperationJobNativeToNative::~FileCopyOperationJobNativeToNative()
{
    if(m_Buffer1) { free(m_Buffer1); m_Buffer1 = 0; }
    if(m_Buffer2) { free(m_Buffer2); m_Buffer2 = 0; }
}

void FileCopyOperationJobNativeToNative::Init(chained_strings _files, // passing ownage to Job
                         const char *_root,               // dir in where files are located
                         const char *_dest,                // where to copy
                         FileCopyOperationOptions _opts,
                         FileCopyOperation *_op
                         )
{
    m_Operation = _op;
    m_InitialItems.swap(_files);
    m_Options = _opts;
    strcpy(m_Destination, _dest);
    strcpy(m_SourceDirectory, _root);
}

void FileCopyOperationJobNativeToNative::Do()
{
    m_IsSingleEntryCopy = m_InitialItems.size() == 1;
    
    // this will analyze what user wants from us
    ScanDestination();
    if(CheckPauseOrStop()) { SetStopped(); return; }

    auto dest_volume = NativeFSManager::Instance().VolumeFromPathFast(m_Destination);
    auto source_volume = NativeFSManager::Instance().VolumeFromPathFast(m_SourceDirectory);
    assert(dest_volume && source_volume);
    m_SourceHasExternalEAs = source_volume->interfaces.extended_attr == false;
    m_DestinationHasExternalEAs = dest_volume->interfaces.extended_attr == false;
    
    if(m_WorkMode == CopyToFixedPath || m_WorkMode == CopyToPathPreffix || m_WorkMode == MoveToFixedPath || m_WorkMode == MoveToPathPreffix )
    {
        ScanItems();
        if(CheckPauseOrStop()) { SetStopped(); return; }
        
        if (m_SourceTotalBytes) m_Stats.SetMaxValue(m_SourceTotalBytes);
    }
    else
    {
        assert(m_WorkMode == RenameToFixedPath || m_WorkMode == RenameToPathPreffix);
        // renaming is trivial, don't scan source deeply - we need just a top level
        m_ScannedItems.swap(m_InitialItems);
        m_Stats.SetMaxValue(m_ScannedItems.size());
    }

    if(m_WorkMode == CopyToFixedPath || m_WorkMode == CopyToPathPreffix || m_WorkMode == MoveToFixedPath || m_WorkMode == MoveToPathPreffix  )
    {
        // allocate buffers and queues only when we'll need them
        m_Buffer1 = malloc(BUFFER_SIZE);
        m_Buffer2 = malloc(BUFFER_SIZE);
    }

    ProcessItems();
    if(CheckPauseOrStop()) { SetStopped(); return; }
    
    SetCompleted();
    m_Operation = nil;
}

bool FileCopyOperationJobNativeToNative::IsSingleFileCopy() const
{
    return m_IsSingleFileCopy;    
}

FileCopyOperationJobNativeToNative::StatValueType FileCopyOperationJobNativeToNative::GetStatValueType() const
{
    if(m_WorkMode == CopyToFixedPath || m_WorkMode == CopyToPathPreffix || m_WorkMode == MoveToFixedPath || m_WorkMode == MoveToPathPreffix)
    {
        return StatValueBytes;
    }
    else if (m_WorkMode == RenameToFixedPath || m_WorkMode == RenameToPathPreffix)
    {
        return StatValueFiles;
    }
        
    return StatValueUnknown;
}

void FileCopyOperationJobNativeToNative::ScanDestination()
{
    auto &io = RoutedIO::Default;
    struct stat stat_buffer;
    char destpath[MAXPATHLEN];
    
    // check if destination begins with "../" or "~/" - then substitute it with appropriate paths
    if(strncmp(m_Destination, "..", strlen("..")) == 0)
    {
        char path[MAXPATHLEN];
        bool b = GetDirectoryContainingItemFromPath(m_SourceDirectory, path);
        assert(b);
        
        if(strncmp(m_Destination, "../", strlen("../")) == 0)
            strcat(path, m_Destination + strlen("../"));
        else
            strcat(path, m_Destination + strlen(".."));
        strcpy(m_Destination, path);
    }
    else if(strncmp(m_Destination, "~", strlen("~")) == 0)
    {
        char path[MAXPATHLEN];
        strcpy(path, CommonPaths::Get(CommonPaths::Home).c_str());
        if(strncmp(m_Destination, "~/", strlen("~/")) == 0)
            strcat(path, m_Destination + strlen("~/"));
        else
            strcat(path, m_Destination + strlen("~"));
        strcpy(m_Destination, path);
    }
    
    if(m_Destination[0] == '/' &&
       io.stat(m_Destination, &stat_buffer) == 0)
    {
        CheckSameVolume(m_SourceDirectory, m_Destination, m_SameVolume);        
        bool isfile = (stat_buffer.st_mode&S_IFMT) == S_IFREG;
        bool isdir  = (stat_buffer.st_mode&S_IFMT) == S_IFDIR;
        
        if(isfile)
        {
            if(m_Options.docopy)
            {
                m_WorkMode = CopyToFixedPath;
            }
            else
            {
                if(m_SameVolume) m_WorkMode = RenameToFixedPath;
                else             m_WorkMode = MoveToFixedPath;
            }
        }
        else if(isdir)
        {   
            if(m_Destination[strlen(m_Destination)-1] != '/')
                strcat(m_Destination, "/"); // add slash at the end

            if(m_Options.docopy)
            {
                m_WorkMode = CopyToPathPreffix;
            }
            else
            {
                if(m_SameVolume) m_WorkMode = RenameToPathPreffix;
                else             m_WorkMode = MoveToPathPreffix;
            }
        }
        else
            assert(0); //TODO: implement handling of this weird cases (like copying to a device)
    }
    else
    { // ok, it's not a valid entry, now we have to analyze what user wants from us
        // and try to combine the right m_Destination
        if(strchr(m_Destination, '/') == 0)
        {
            // there's no directories mentions in destination path, let's treat destination as an regular absent file
            // let's think that this destination file should be located in source directory
            // TODO: add CheckSameVolume
            strcpy(destpath, m_SourceDirectory);
            strcat(destpath, m_Destination);
            strcpy(m_Destination, destpath);
            
            m_SameVolume = true;
            if(m_Options.docopy) m_WorkMode = CopyToFixedPath;
            else            m_WorkMode = RenameToFixedPath;
        }
        else
        {
            if(IsPathWithTrailingSlash(m_Destination))
            {
                // user want to copy/rename/move file(s) to some directory, like "Abra/Carabra/" or "/bin/abra/"
                if(m_Destination[0] != '/')
                { // relative to source directory
                    strcpy(destpath, m_SourceDirectory);
                    strcat(destpath, m_Destination);
                    strcpy(m_Destination, destpath);

                    // check if the volume is the same
                    // TODO: there can be some CRAZY situations when user wants to do someting with directory that
                    // contains a mounting point with another filesystem. but for now let's think that is not valid.
                    // for the future - algo should have a flag about nested filesystems and process them carefully later
                    CheckSameVolume(m_SourceDirectory, m_Destination, m_SameVolume);
                }
                else
                { // absolute path                
                    CheckSameVolume(m_SourceDirectory, m_Destination, m_SameVolume);// TODO: look up
                }

                if(m_Options.docopy)
                {
                    m_WorkMode = CopyToPathPreffix;
                }
                else
                {
                    if(m_SameVolume)  m_WorkMode = RenameToPathPreffix;
                    else              m_WorkMode = MoveToPathPreffix;
                }
            
                // now we need to check every directory here and create them they are not exist
                BuildDestinationDirectory(m_Destination);
                if(CheckPauseOrStop()) return;
            }
            else
            { // user want to copy/rename/move file(s) to some filename, like "Abra/Carabra" or "/bin/abra"
                if(m_Destination[0] != '/')
                { // relative to source directory
                    strcpy(destpath, m_SourceDirectory);
                    strcat(destpath, m_Destination);
                    strcpy(m_Destination, destpath);
                }
                else
                { // absolute path
                }
                CheckSameVolume(m_SourceDirectory, m_Destination, m_SameVolume);// TODO: look up

                if(m_Options.docopy)
                {
                    m_WorkMode = CopyToFixedPath;
                }
                else
                {
                    if(m_SameVolume) m_WorkMode = RenameToFixedPath;
                    else             m_WorkMode = MoveToFixedPath;
                }
                
                // now we need to check every directory here and create them they are not exist
                BuildDestinationDirectory(m_Destination);
                if(CheckPauseOrStop()) return;
            }
        }
    }
}

void FileCopyOperationJobNativeToNative::BuildDestinationDirectory(const char* _path)
{
    // TODO: not very efficient implementation, it does many redundant stat calls
    // this algorithm iterates from left to right, but it's better to iterate right-left and then left-right
    // but this work is doing only once per MassCopyOp, so user may not even notice this issue
    
    auto &io = RoutedIO::Default;
    
    struct stat stat_buffer;
    char destpath[MAXPATHLEN];
    strcpy(destpath, _path);
    char* leftmost = strchr(destpath+1, '/');
    assert(leftmost != 0);
    do
    {
        *leftmost = 0;
        if(io.stat(destpath, &stat_buffer) == -1)
        {
            // absent part - need to create it
domkdir:    if(io.mkdir(destpath, S_IXUSR|S_IXGRP|S_IXOTH|S_IRUSR|S_IRGRP|S_IROTH|S_IWUSR) == -1)
            {
                int result = [[m_Operation OnCantCreateDir:ErrnoToNSError() ForDir:destpath] WaitForResult];
                if (result == OperationDialogResult::Retry) goto domkdir;
                if (result == OperationDialogResult::Stop) { RequestStop(); return; }
            }
        }
        *leftmost = '/';
        
        leftmost = strchr(leftmost+1, '/');
    } while(leftmost != 0);
}

void FileCopyOperationJobNativeToNative::ScanItems()
{
    if(m_InitialItems.size() > 1)
        m_IsSingleFileCopy = false;
    
    // iterate in original filenames
    for(const auto&i: m_InitialItems)
    {
        ScanItem(i.c_str(), i.c_str(), 0);

        if(CheckPauseOrStop()) return;
    }
}

void FileCopyOperationJobNativeToNative::ScanItem(const char *_full_path, const char *_short_path, const chained_strings::node *_prefix)
{
    // TODO: optimize it ALL!
    // TODO: this path composing can be optimized
    // DANGER: this big buffer can cause stack overflow since ScanItem function is used recursively. FIXME!!!
    // 512Kb for threads in OSX. CHECK ME!

    auto &io = RoutedIO::Default;
    char fullpath[MAXPATHLEN];
    strcpy(fullpath, m_SourceDirectory);
    strcat(fullpath, _full_path);

    struct stat stat_buffer;
retry_stat:
    int stat_ret = m_Options.preserve_symlinks ?
        io.lstat(fullpath, &stat_buffer):
         io.stat(fullpath, &stat_buffer);
    if(stat_ret == 0)
    {
        bool issymlink  = (stat_buffer.st_mode&S_IFMT) == S_IFLNK;
        bool isreg      = (stat_buffer.st_mode&S_IFMT) == S_IFREG;
        bool isdir      = (stat_buffer.st_mode&S_IFMT) == S_IFDIR;

        if(isreg || issymlink)
        {
            bool skip = false;
            if(!issymlink &&
               m_SourceHasExternalEAs &&
               CanBeExternalEA(_short_path) &&
               EAHasMainFile(fullpath) )
                skip = true;
            
            if(!skip)
            {
                m_ItemFlags.push_back(issymlink ? (uint8_t)ItemFlags::is_symlink : (uint8_t)ItemFlags::no_flags);
                m_ScannedItems.push_back(_short_path, _prefix);
                m_SourceNumberOfFiles++;
                m_SourceTotalBytes += stat_buffer.st_size;
            }
        }
        else if(isdir)
        {
            m_IsSingleFileCopy = false;
            char dirpath[MAXPATHLEN];
            sprintf(dirpath, "%s/", _short_path);
            m_ItemFlags.push_back((uint8_t)ItemFlags::is_dir);
            m_ScannedItems.push_back(dirpath, _prefix);
            auto dirnode = &m_ScannedItems.back();
            m_SourceNumberOfDirectories++;
            
        retry_opendir:
            auto &io = RoutedIO::InterfaceForAccess(fullpath, R_OK);
            DIR *dirp = io.opendir(fullpath);
            if( dirp != 0)
            {
                dirent *entp;
                while((entp = io.readdir(dirp)) != NULL)
                {
                    if(strcmp(entp->d_name, ".") == 0 ||
                       strcmp(entp->d_name, "..") == 0) continue; // TODO: optimize me
                    
                    sprintf(dirpath, "%s/%s", _full_path, entp->d_name);
                    
                    ScanItem(dirpath, entp->d_name, dirnode);
                    if (CheckPauseOrStop())
                    {
                        io.closedir(dirp);
                        return;
                    }
                }
                
                io.closedir(dirp);
            }
            else if (!m_SkipAll)
            {
                int result = [[m_Operation OnCopyCantAccessSrcFile:ErrnoToNSError() ForFile:fullpath]
                              WaitForResult];
                if (result == OperationDialogResult::Retry) goto retry_opendir;
                else if (result == OperationDialogResult::SkipAll) m_SkipAll = true;
                else if (result == OperationDialogResult::Stop)
                {
                    RequestStop();
                    return;
                }
            }
        }
    }
    else if (!m_SkipAll)
    {
        int result = [[m_Operation OnCopyCantAccessSrcFile:ErrnoToNSError() ForFile:fullpath]
                      WaitForResult];
        if (result == OperationDialogResult::Retry) goto retry_stat;
        else if (result == OperationDialogResult::SkipAll) m_SkipAll = true;
        else if (result == OperationDialogResult::Stop)
        {
            RequestStop();
            return;
        }
    }
}

void FileCopyOperationJobNativeToNative::ProcessItems()
{
    m_Stats.StartTimeTracking();
    
    int n = 0;
    for(const auto&i: m_ScannedItems)
    {
        m_CurrentlyProcessingItem = &i;
        
        ProcessItem(m_CurrentlyProcessingItem, n++);

        if(CheckPauseOrStop()) return;
    }

    m_Stats.SetCurrentItem(nullptr);
    
    if(!m_FilesToDelete.empty())
        ProcessFilesRemoval();
    if(!m_DirsToDelete.empty())
        ProcessFoldersRemoval();
}

void FileCopyOperationJobNativeToNative::ProcessItem(const chained_strings::node *_node, int _number)
{
    assert(_node->size() != 0);
    
    // compose file name - reverse lookup
    char itemname[MAXPATHLEN];
    _node->str_with_pref(itemname);
    if(m_WorkMode == CopyToFixedPath)           ProcessCopyToFixedPath(itemname, _number);
    else if(m_WorkMode == CopyToPathPreffix)    ProcessCopyToPathPreffix(itemname, _number);
    else if(m_WorkMode == RenameToFixedPath)    ProcessRenameToFixedPath(itemname, _number);
    else if(m_WorkMode == RenameToPathPreffix)  ProcessRenameToPathPreffix(itemname, _number);
    else if(m_WorkMode == MoveToPathPreffix)    ProcessMoveToPathPreffix(itemname, _number);
    else if(m_WorkMode == MoveToFixedPath)      ProcessMoveToFixedPath(itemname, _number);
    else assert(0); // sanity guard
}

void FileCopyOperationJobNativeToNative::ProcessFilesRemoval()
{
    auto &io = RoutedIO::Default;
    for(auto i: m_FilesToDelete)
    {
        assert(i->c_str()[i->size()-1] != '/'); // sanity check
        
        char itemname[MAXPATHLEN], path[MAXPATHLEN];
        i->str_with_pref(itemname);
        strcpy(path, m_SourceDirectory);
        strcat(path, itemname);
        io.unlink(path); // any error handling here?
    }
}

void FileCopyOperationJobNativeToNative::ProcessFoldersRemoval()
{
    auto &io = RoutedIO::Default;
    for(auto i = m_DirsToDelete.rbegin(); i != m_DirsToDelete.rend(); ++i)
    {
        const auto item = *i;
        assert(item->c_str()[item->size()-1] == '/'); // sanity check
        
        char itemname[MAXPATHLEN], path[MAXPATHLEN];
        item->str_with_pref(itemname);
        strcpy(path, m_SourceDirectory);
        strcat(path, itemname);
        io.rmdir(path); // any error handling here?
    }
}

void FileCopyOperationJobNativeToNative::ProcessCopyToPathPreffix(const char *_path, int _number)
{
    char sourcepath[MAXPATHLEN], destinationpath[MAXPATHLEN];    
    if(m_ItemFlags[_number] & (uint8_t)ItemFlags::is_dir)
    {
        assert(IsPathWithTrailingSlash(m_Destination));
        assert(IsPathWithTrailingSlash(_path));
        
        strcpy(destinationpath, m_Destination);
        strcat(destinationpath, _path);
        
        strcpy(sourcepath, m_SourceDirectory);
        strcat(sourcepath, _path);
        
        if(strcmp(sourcepath, destinationpath) == 0) return; // do not try to copy directory into itself        
        CopyDirectoryTo(sourcepath, destinationpath);
    }
    else
    {
        assert(_path[strlen(_path)-1] != '/'); // sanity check
        
        // compose real src name
        strcpy(sourcepath, m_SourceDirectory);
        strcat(sourcepath, _path);
        
        // compose dest name
        assert(IsPathWithTrailingSlash(m_Destination)); // just a sanity check.
        strcpy(destinationpath, m_Destination);
        strcat(destinationpath, _path);
        
        if(strcmp(sourcepath, destinationpath) == 0) return; // do not try to copy file into itself
        
        if(m_Options.preserve_symlinks && (m_ItemFlags[_number] & (uint8_t)ItemFlags::is_symlink))
            CreateSymlinkTo(sourcepath, destinationpath);
        else
            CopyFileTo(sourcepath, destinationpath);
    }
}

void FileCopyOperationJobNativeToNative::ProcessCopyToFixedPath(const char *_path, int _number)
{
    char sourcepath[MAXPATHLEN], destinationpath[MAXPATHLEN];
    if(m_ItemFlags[_number] & (uint8_t)ItemFlags::is_dir)
    {
        assert(!IsPathWithTrailingSlash(m_Destination));
        assert(IsPathWithTrailingSlash(_path));
        
        strcpy(destinationpath, m_Destination);
        // here we need to find if user wanted just to copy a single top-level directory
        // if so - don't touch destination name. otherwise - add an original path there
        if(m_IsSingleEntryCopy)
        {
            // for top level we need to just leave path without changes - skip top level's entry name
            // for nested entries we need to cut first part of a path
            if(*(strchr(_path, '/')+1) != 0)
                strcat(destinationpath, strchr(_path, '/'));
        }
        else
        {
            strcat(destinationpath, "/");
            strcat(destinationpath, _path);
        }
        
        strcpy(sourcepath, m_SourceDirectory);
        strcat(sourcepath, _path);
        
        CopyDirectoryTo(sourcepath, destinationpath);
    }
    else
    {   
        assert(_path[strlen(_path)-1] != '/'); // sanity check
        
        // compose real src name
        strcpy(sourcepath, m_SourceDirectory);
        strcat(sourcepath, _path);
        
        // compose dest name
        strcpy(destinationpath, m_Destination);
        // here we need to find if user wanted just to copy a single top-level directory
        // if so - don't touch destination name. otherwise - add an original path there
        if(m_IsSingleEntryCopy)
        {
            // for top level we need to just leave path without changes - skip top level's entry name
            // for nested entries we need to cut first part of a path
            if(strchr(_path, '/') != 0)
                strcat(destinationpath, strchr(_path, '/'));
        }
        
        if(strcmp(sourcepath, destinationpath) == 0) return; // do not try to copy file into itself
        
        if(m_Options.preserve_symlinks && (m_ItemFlags[_number] & (uint8_t)ItemFlags::is_symlink))
            CreateSymlinkTo(sourcepath, destinationpath);
        else
            CopyFileTo(sourcepath, destinationpath);
    }
}

void FileCopyOperationJobNativeToNative::ProcessMoveToFixedPath(const char *_path, int _number)
{
    // m_Destination is a file name
    char sourcepath[MAXPATHLEN];
    if(!(m_ItemFlags[_number] & (uint8_t)ItemFlags::is_dir))
    {
        assert(!IsPathWithTrailingSlash(_path)); // sanity check
        // compose real src name
        strcpy(sourcepath, m_SourceDirectory);
        strcat(sourcepath, _path);
        
        
        bool result = (m_Options.preserve_symlinks && (m_ItemFlags[_number] & (uint8_t)ItemFlags::is_symlink)) ?
            CreateSymlinkTo(sourcepath, m_Destination):
            CopyFileTo(sourcepath, m_Destination);
        
        if( result )
            m_FilesToDelete.push_back(m_CurrentlyProcessingItem);
            // put files in deletion list only if copying was successful        
    }
    else
    {
        assert(IsPathWithTrailingSlash(_path)); // sanity check
        // compose real src name
        strcpy(sourcepath, m_SourceDirectory);
        strcat(sourcepath, _path);

        if(CopyDirectoryTo(sourcepath, m_Destination))
            m_DirsToDelete.push_back(m_CurrentlyProcessingItem);
            // put dirs in deletion list only if copying was successful
    }
}

void FileCopyOperationJobNativeToNative::ProcessMoveToPathPreffix(const char *_path, int _number)
{
    // m_Destination is a directory path
    char sourcepath[MAXPATHLEN], destinationpath[MAXPATHLEN];
    
    if(!(m_ItemFlags[_number] & (uint8_t)ItemFlags::is_dir))
    {
        assert(!IsPathWithTrailingSlash(_path)); // sanity check
        // compose real src name
        strcpy(sourcepath, m_SourceDirectory);
        strcat(sourcepath, _path);
    
        // compose dest name
        assert(IsPathWithTrailingSlash(m_Destination)); // just a sanity check.
        strcpy(destinationpath, m_Destination);
        strcat(destinationpath, _path);
        assert(strcmp(sourcepath, destinationpath) != 0); // this situation should never happen
    
        bool result = (m_Options.preserve_symlinks && (m_ItemFlags[_number] & (uint8_t)ItemFlags::is_symlink)) ?
            CreateSymlinkTo(sourcepath, destinationpath):
            CopyFileTo(sourcepath, destinationpath);

        // put files in deletion list only if copying was successful
        if( result )
            m_FilesToDelete.push_back(m_CurrentlyProcessingItem);
    }
    else
    {
        assert(IsPathWithTrailingSlash(_path)); // sanity check
        // compose real src name
        strcpy(sourcepath, m_SourceDirectory);
        strcat(sourcepath, _path);
        
        // compose dest name
        assert(IsPathWithTrailingSlash(m_Destination)); // just a sanity check.
        strcpy(destinationpath, m_Destination);
        strcat(destinationpath, _path);
        assert(strcmp(sourcepath, destinationpath) != 0); // this situation should never happen
        
        if(CopyDirectoryTo(sourcepath, destinationpath))
            m_DirsToDelete.push_back(m_CurrentlyProcessingItem);
    }
}

void FileCopyOperationJobNativeToNative::ProcessRenameToFixedPath(const char *_path, int _number)
{
    auto &io = RoutedIO::Default;
    m_Stats.SetCurrentItem(_path);
    
    // m_Destination is full target path - we need to rename current file to it
    // assuming that we're working on same valume
    char sourcepath[MAXPATHLEN];
    struct stat stat_buffer;
    
     // sanity checks
    assert(m_Destination[strlen(m_Destination)-1] != '/');
    assert(_path[0] != 0);
    assert(_path[0] != '/');
    
    // compose real src name
    strcpy(sourcepath, m_SourceDirectory);
    strcat(sourcepath, _path);
    
    int ret = io.lstat(m_Destination, &stat_buffer);
    if(ret != -1)
    {
        // Destination file already exists.
        // Check if destination and source paths reference the same file. In this case,
        // silently rename the file.
        struct stat src_stat_buffer;
        ret = io.lstat(sourcepath, &src_stat_buffer);
        if (!(ret == 0 && stat_buffer.st_dev == src_stat_buffer.st_dev
            && stat_buffer.st_ino == src_stat_buffer.st_ino))
        {
            // Ask what to do.
            int result = [[m_Operation OnRenameDestinationExists:m_Destination Source:sourcepath]
                          WaitForResult];
            
            if (result == OperationDialogResult::Stop) { RequestStop(); return; }
        }
    }
    
retry_rename:
    ret = io.rename(sourcepath, m_Destination);
    if (ret != 0)
    {
        int result = [[m_Operation OnCopyWriteError:ErrnoToNSError() ForFile:m_Destination] WaitForResult];
        if (result == OperationDialogResult::Retry) goto retry_rename;
        else if (result == OperationDialogResult::Stop) { RequestStop(); return; }
    }
    
    m_Stats.AddValue(1);
}

void FileCopyOperationJobNativeToNative::ProcessRenameToPathPreffix(const char *_path, int _number)
{
    auto &io = RoutedIO::Default;
    m_Stats.SetCurrentItem(_path);
    
    // m_Destination is a directory path - we need to appen _path to it
    char sourcepath[MAXPATHLEN], destpath[MAXPATHLEN];
    struct stat stat_buffer;

    assert(_path[0] != 0);
    assert(_path[0] != '/');
        
    // compose real src name
    strcpy(sourcepath, m_SourceDirectory);
    strcat(sourcepath, _path);
    
    strcpy(destpath, m_Destination);
    if(destpath[strlen(destpath)-1] != '/' ) strcat(destpath, "/");
    strcat(destpath, _path);
    
    int ret = io.lstat(destpath, &stat_buffer);
    if(ret != -1)
    {
        // Destination file already exists.
        // Check if destination and source paths reference the same file. In this case,
        // silently rename the file.
        struct stat src_stat_buffer;
        ret = io.lstat(sourcepath, &src_stat_buffer);
        if (!(ret == 0 && stat_buffer.st_dev == src_stat_buffer.st_dev
              && stat_buffer.st_ino == src_stat_buffer.st_ino))
        {
            // Ask what to do.
            int result = [[m_Operation OnRenameDestinationExists:destpath Source:sourcepath]
                          WaitForResult];
            
            if (result == OperationDialogResult::Stop) { RequestStop(); return; }
        }
    }

retry_rename:
    ret = io.rename(sourcepath, destpath);
    if (ret != 0)
    {
        int result = [[m_Operation OnCopyWriteError:[NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil] ForFile:m_Destination] WaitForResult];
        if (result == OperationDialogResult::Retry) goto retry_rename;
        else if (result == OperationDialogResult::Stop) { RequestStop(); return; }
    }
    
    m_Stats.AddValue(1);
}

bool FileCopyOperationJobNativeToNative::CreateSymlinkTo(const char *_source_symlink, const char* _tagret_symlink)
{
    auto &io = RoutedIO::Default;
    
    char linkpath[MAXPATHLEN];
    int result;
    ssize_t sz;
    bool was_succesful = false;
doreadlink:
    sz = io.readlink(_source_symlink, linkpath, MAXPATHLEN);
    if(sz == -1)
    {   // failed to read original symlink
        if(m_SkipAll) goto cleanup;
        int result = [[m_Operation OnCopyCantAccessSrcFile:ErrnoToNSError() ForFile:_source_symlink] WaitForResult];
        if(result == OperationDialogResult::Retry) goto doreadlink;
        if(result == OperationDialogResult::Skip) goto cleanup;
        if(result == OperationDialogResult::SkipAll) {m_SkipAll = true; goto cleanup;}
        if(result == OperationDialogResult::Stop) { RequestStop(); goto cleanup; }
    }
    
    linkpath[sz] = 0;
    
dosymlink:
    result = io.symlink(linkpath, _tagret_symlink);
    if(result != 0)
    {   // failed to create a symlink
        if(m_SkipAll) goto cleanup;
        int result = [[m_Operation OnCopyCantOpenDestFile:ErrnoToNSError() ForFile:_tagret_symlink] WaitForResult];
        if(result == OperationDialogResult::Retry) goto dosymlink;
        if(result == OperationDialogResult::Skip) goto cleanup;
        if(result == OperationDialogResult::SkipAll) {m_SkipAll = true; goto cleanup;}
        if(result == OperationDialogResult::Stop) { RequestStop(); goto cleanup; }
    }
    
    was_succesful = true;

cleanup:
    
    return was_succesful;
}

void FileCopyOperationJobNativeToNative::EraseXattrs(int _fd_in)
{
    assert(m_Buffer1);
    char *xnames = (char*) m_Buffer1;
    ssize_t xnamesizes = flistxattr(_fd_in, xnames, BUFFER_SIZE, 0);
    if(xnamesizes > 0)
    { // iterate and remove
        char *s = xnames, *e = xnames + xnamesizes;
        while(s < e)
        {
            fremovexattr(_fd_in, s, 0);
            s += strlen(s)+1;
        }
    }
}

void FileCopyOperationJobNativeToNative::CopyXattrs(int _fd_from, int _fd_to)
{
    char *xnames;
    ssize_t xnamesizes;

    assert(m_Buffer1 != 0);
    xnames = (char*) m_Buffer1;
    xnamesizes = flistxattr(_fd_from, xnames, BUFFER_SIZE, 0);
    if(xnamesizes > 0)
    { // iterate and copy
        char *s = xnames, *e = xnames + xnamesizes;
        while(s < e)
        {
            ssize_t xattrsize = fgetxattr(_fd_from, s, m_Buffer2, BUFFER_SIZE, 0, 0);
            if(xattrsize >= 0) // xattr can be zero-length, just a tag itself
                fsetxattr(_fd_to, s, m_Buffer2, xattrsize, 0, 0);
            s += strlen(s)+1;
        }
    }
}

bool FileCopyOperationJobNativeToNative::CopyDirectoryTo(const char *_src, const char *_dest)
{
    auto &io = RoutedIO::Default;
    
    // TODO: need to handle errors on attributes somehow. but I don't know how.
    struct stat src_stat, dst_stat;
    bool opres = false;
    int src_fd = -1, dst_fd = -1;

    // check if target already exist
    if( io.lstat(_dest, &dst_stat) != -1 )
    {
        // target exists; check that it's a directory

        if( (dst_stat.st_mode & S_IFMT) != S_IFDIR )
        {
            // TODO: ask user what to do
            goto end;
        }
    }
    else
    {
domkdir:
        if(io.mkdir(_dest, 0777))
        {
            if(m_SkipAll) goto end;
            int result = [[m_Operation OnCantCreateDir:ErrnoToNSError() ForDir:_dest] WaitForResult];
            if(result == OperationDialogResult::Retry) goto domkdir;
            if(result == OperationDialogResult::Skip) goto end;
            if(result == OperationDialogResult::SkipAll) {m_SkipAll = true; goto end;}
            if(result == OperationDialogResult::Stop)  { RequestStop(); goto end; }
        }
    }

    // do attributes stuff
    if((src_fd = io.open(_src, O_RDONLY)) == -1) goto end;
    if((dst_fd = io.open(_dest, O_RDONLY)) == -1) goto end;
    if(fstat(src_fd, &src_stat) != 0) goto end;
    

    if(m_Options.copy_unix_flags)
    {
        // change unix mode
        fchmod(dst_fd, src_stat.st_mode);
        
        // change flags
        fchflags(dst_fd, src_stat.st_flags);
    }

    if(m_Options.copy_unix_owners) // change ownage
        io.chown(_dest, src_stat.st_uid, src_stat.st_gid);

    if(m_Options.copy_xattrs) // copy xattrs
        CopyXattrs(src_fd, dst_fd);
    
    if(m_Options.copy_file_times) // adjust destination times
        AdjustFileTimes(dst_fd, &src_stat);

    opres = true;
end:
    if(src_fd != -1) io.close(src_fd);
    if(dst_fd != -1) io.close(dst_fd);
    return opres;
}

bool FileCopyOperationJobNativeToNative::CopyFileTo(const char *_src, const char *_dest)
{
    auto &io = RoutedIO::Default;
    assert(m_WorkMode != RenameToFixedPath && m_WorkMode != RenameToPathPreffix); // sanity check
    
    // TODO: need to ask about destination volume info to exclude meaningless operations for attrs which are not supported
    // TODO: need to adjust buffer sizes and writing calls to preffered volume's I/O size
    struct stat src_stat_buffer, dst_stat_buffer;
    char *readbuf = (char*)m_Buffer1, *writebuf = (char*)m_Buffer2;
    int dstopenflags=0, sourcefd=-1, destinationfd=-1, fcntlret;
    int64_t preallocate_delta = 0;    
    unsigned long startwriteoff = 0, totaldestsize = 0, dest_sz_on_stop = 0;
    bool adjust_dst_time = true, copy_xattrs = true, erase_xattrs = false, remember_choice = false,
    was_successful = false, unlink_on_stop = false;
    mode_t oldumask;
    unsigned long io_leftwrite = 0, io_totalread = 0, io_totalwrote = 0;
    bool io_docancel = false;
    
    m_Stats.SetCurrentItem(_src);
    
    // getting fs_info for every single file is suboptimal. need to optimize it.
    auto fs_info = NativeFSManager::Instance().VolumeFromPath(_src);
    
opensource:
    int src_open_flags = O_RDONLY|O_NONBLOCK;
    if(fs_info && fs_info->interfaces.file_lock)
        src_open_flags |= O_SHLOCK;
    
    if((sourcefd = io.open(_src, src_open_flags)) == -1)
    {  // failed to open source file
        if(m_SkipAll) goto cleanup;
        int result = [[m_Operation OnCopyCantAccessSrcFile:ErrnoToNSError() ForFile:_src] WaitForResult];
        if(result == OperationDialogResult::Retry) goto opensource;
        if(result == OperationDialogResult::Skip) goto cleanup;
        if(result == OperationDialogResult::SkipAll) {m_SkipAll = true; goto cleanup;}
        if(result == OperationDialogResult::Stop) { RequestStop(); goto cleanup; }
    }
    fcntl(sourcefd, F_NOCACHE, 1); // do not waste OS file cache with one-way data
    fcntlret = fcntl(sourcefd, F_GETFL);
    assert(fcntlret >= 0);
    fcntlret = fcntl(sourcefd, F_SETFL, fcntlret & ~O_NONBLOCK);
    assert(fcntlret >= 0); // TODO: consider displaying dialog on such errors istead of assertation
    
statsource: // get information about source file
    if(fstat(sourcefd, &src_stat_buffer) == -1)
    {   // failed to stat source
        if(m_SkipAll) goto cleanup;
        int result = [[m_Operation OnCopyCantAccessSrcFile:ErrnoToNSError() ForFile:_src] WaitForResult];
        if(result == OperationDialogResult::Retry) goto statsource;
        if(result == OperationDialogResult::Skip) goto cleanup;
        if(result == OperationDialogResult::SkipAll) {m_SkipAll = true; goto cleanup;}
        if(result == OperationDialogResult::Stop) { RequestStop(); goto cleanup; }
    }
    
    // stat destination
    totaldestsize = src_stat_buffer.st_size;
    if(io.stat(_dest, &dst_stat_buffer) != -1)
    { // file already exist. what should we do now?
        int result;
        if(m_SkipAll) goto cleanup;
        if(m_OverwriteAll) goto decoverwrite;
        if(m_AppendAll) goto decappend;
        
        result = [[m_Operation OnFileExist:_dest
                                   newsize:src_stat_buffer.st_size
                                   newtime:src_stat_buffer.st_mtimespec.tv_sec
                                   exisize:dst_stat_buffer.st_size
                                   exitime:dst_stat_buffer.st_mtimespec.tv_sec
                                  remember:&remember_choice] WaitForResult];
        if(result == FileCopyOperationDR::Overwrite){ if(remember_choice) m_OverwriteAll = true;  goto decoverwrite; }
        if(result == FileCopyOperationDR::Append)   { if(remember_choice) m_AppendAll = true;     goto decappend;    }
        if(result == OperationDialogResult::Skip)     { if(remember_choice) m_SkipAll = true;       goto cleanup;      }
        if(result == OperationDialogResult::Stop)   { RequestStop(); goto cleanup; }
        
        // decisions about what to do with existing destination
    decoverwrite:
        dstopenflags = O_WRONLY;
        erase_xattrs = true;
        unlink_on_stop = true;
        dest_sz_on_stop = 0;
        preallocate_delta = src_stat_buffer.st_size - dst_stat_buffer.st_size;
        goto decend;
    decappend:
        dstopenflags = O_WRONLY;
        totaldestsize += dst_stat_buffer.st_size;
        startwriteoff = dst_stat_buffer.st_size;
        dest_sz_on_stop = dst_stat_buffer.st_size;
        preallocate_delta = src_stat_buffer.st_size;        
        adjust_dst_time = false;
        copy_xattrs = false;
        unlink_on_stop = false;
        goto decend;
    decend:;
    }
    else
    { // no dest file - just create it
        dstopenflags = O_WRONLY|O_CREAT;
        unlink_on_stop = true;
        dest_sz_on_stop = 0;
        preallocate_delta = src_stat_buffer.st_size;        
    }
    
opendest: // open file descriptor for destination
    oldumask = umask(0);
    if(m_Options.copy_unix_flags) // we want to copy src permissions
        destinationfd = io.open(_dest, dstopenflags, src_stat_buffer.st_mode);
    else // open file with default permissions
        destinationfd = io.open(_dest, dstopenflags, S_IRUSR | S_IWUSR | S_IRGRP);
    umask(oldumask);
    
    if(destinationfd == -1)
    {   // failed to open destination file
        if(m_SkipAll) goto cleanup;
        int result = [[m_Operation OnCopyCantOpenDestFile:ErrnoToNSError() ForFile:_dest] WaitForResult];
        if(result == OperationDialogResult::Retry) goto opendest;
        if(result == OperationDialogResult::Skip) goto cleanup;
        if(result == OperationDialogResult::SkipAll) {m_SkipAll = true; goto cleanup;}
        if(result == OperationDialogResult::Stop) { RequestStop(); goto cleanup; }
    }
    
    fcntl(destinationfd, F_NOCACHE, 1); // caching is meaningless here?
    // preallocate space for data since we dont want to trash our disk
    if(preallocate_delta > MIN_PREALLOC_SIZE)
    {
        fstore_t preallocstore = {F_ALLOCATECONTIG, F_PEOFPOSMODE, 0, preallocate_delta};
        if(fcntl(destinationfd, F_PREALLOCATE, &preallocstore) == -1)
        {
            preallocstore.fst_flags = F_ALLOCATEALL;
            fcntl(destinationfd, F_PREALLOCATE, &preallocstore);
        }
    }
    
dotruncate: // set right size for destination file
    if(ftruncate(destinationfd, totaldestsize) == -1)
    {   // failed to set dest file size
        if(m_SkipAll) goto cleanup;
        int result = [[m_Operation OnCopyWriteError:ErrnoToNSError() ForFile:_dest] WaitForResult];
        if(result == OperationDialogResult::Retry) goto dotruncate;
        if(result == OperationDialogResult::Skip) goto cleanup;
        if(result == OperationDialogResult::SkipAll) {m_SkipAll = true; goto cleanup;}
        if(result == OperationDialogResult::Stop) { RequestStop(); goto cleanup; }
    }
    
dolseek: // find right position in destination file
    if(startwriteoff > 0 && lseek(destinationfd, startwriteoff, SEEK_SET) == -1)
    {   // failed seek in a file. lolwhat?
        if(m_SkipAll) goto cleanup;
        int result = [[m_Operation OnCopyWriteError:ErrnoToNSError() ForFile:_dest] WaitForResult];
        if(result == OperationDialogResult::Retry) goto dolseek;
        if(result == OperationDialogResult::Skip) goto cleanup;
        if(result == OperationDialogResult::SkipAll) {m_SkipAll = true; goto cleanup;}
        if(result == OperationDialogResult::Stop) { RequestStop(); goto cleanup; }
    }
    
    while(true)
    {
        if(CheckPauseOrStop()) goto cleanup;
        
        ssize_t io_nread = 0;
        m_IOGroup.Run([&]{
        doread:
            if(io_totalread < src_stat_buffer.st_size)
            {
                io_nread = read(sourcefd, readbuf, BUFFER_SIZE);
                if(io_nread == -1)
                {
                    if(m_SkipAll) {io_docancel = true; return;}
                    int result = [[m_Operation OnCopyReadError:ErrnoToNSError() ForFile:_dest] WaitForResult];
                    if(result == OperationDialogResult::Retry) goto doread;
                    if(result == OperationDialogResult::Skip) {io_docancel = true; return;}
                    if(result == OperationDialogResult::SkipAll) {io_docancel = true; m_SkipAll = true; return;}
                    if(result == OperationDialogResult::Stop) { io_docancel = true; RequestStop(); return;}
                }
                io_totalread += io_nread;
            }
        });
        
        m_IOGroup.Run([&]{
            unsigned long alreadywrote = 0;
            while(io_leftwrite > 0)
            {
            dowrite:
                ssize_t nwrite = write(destinationfd, writebuf + alreadywrote, io_leftwrite);
                if(nwrite == -1)
                {
                    if(m_SkipAll) {io_docancel = true; return;}
                    int result = [[m_Operation OnCopyWriteError:ErrnoToNSError() ForFile:_dest] WaitForResult];
                    if(result == OperationDialogResult::Retry) goto dowrite;
                    if(result == OperationDialogResult::Skip) {io_docancel = true; return;}
                    if(result == OperationDialogResult::SkipAll) {io_docancel = true; m_SkipAll = true; return;}
                    if(result == OperationDialogResult::Stop) { io_docancel = true; RequestStop(); return;}
                }
                alreadywrote += nwrite;
                io_leftwrite -= nwrite;
            }
            io_totalwrote += alreadywrote;
            m_TotalCopied += alreadywrote;
        });
        
        m_IOGroup.Wait();
        if(io_docancel) goto cleanup;
        if(io_totalwrote == src_stat_buffer.st_size) break;
        
        io_leftwrite = io_nread;
        swap(readbuf, writebuf); // swap our work buffers - read buffer become write buffer and vice versa
        
        // update statistics
        m_Stats.SetValue(m_TotalCopied);
    }
    
    // TODO: do we need to determine if various attributes setting was successful?
    
    // erase destination's xattrs
    if(m_Options.copy_xattrs && erase_xattrs)
        EraseXattrs(destinationfd);
    
    // copy xattrs from src to dest
    if(m_Options.copy_xattrs && copy_xattrs)
        CopyXattrs(sourcefd, destinationfd);
    
    // change ownage
    // TODO: we can't chown without superuser rights.
    // need to optimize this (sometimes) meaningless call
    if(m_Options.copy_unix_owners) {
        if(io.isrouted()) // long path
            io.chown(_dest, src_stat_buffer.st_uid, src_stat_buffer.st_gid);
        else // short path
            fchown(destinationfd, src_stat_buffer.st_uid, src_stat_buffer.st_gid);
    }
    
    // change flags
    if(m_Options.copy_unix_flags) {
        if(io.isrouted()) // long path
            io.chflags(_dest, src_stat_buffer.st_flags);
        else
            fchflags(destinationfd, src_stat_buffer.st_flags);
    }
    
    // adjust destination time as source
    if(m_Options.copy_file_times && adjust_dst_time)
        AdjustFileTimes(destinationfd, &src_stat_buffer);
    
    was_successful = true;

cleanup:
    if(sourcefd != -1) close(sourcefd);
    if(!was_successful && destinationfd != -1)
    {
        // we need to revert what we've done
        ftruncate(destinationfd, dest_sz_on_stop);
        close(destinationfd);
        destinationfd = -1;
        if(unlink_on_stop)
            io.unlink(_dest);
    }
    if(destinationfd != -1) close(destinationfd);
    return was_successful;
}