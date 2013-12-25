//
//  FileDeletionOperationJob.cpp
//  Directories
//
//  Created by Michael G. Kazakov on 05.04.13.
//  Copyright (c) 2013 Michael G. Kazakov. All rights reserved.
//

#import "FileDeletionOperationJob.h"
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
#import "OperationDialogAlert.h"
#import "rdrand.h"
#import "Common.h"

static void Randomize(unsigned char *_data, unsigned _size)
{
    // try to use Intel's rdrand instruction directly, don't waste CPU time on manual rand calculation
    // Ivy Bridge(2012) and later
    int r = rdrand_get_bytes(_size, _data);
    if( r != RDRAND_SUCCESS)
    {
        // fallback mode - call traditional sluggish rand()
        for(unsigned i = 0; i < _size; ++i)
            _data[i] = rand()%256;
    }
}

FileDeletionOperationJob::FileDeletionOperationJob():
    m_Type(FileDeletionOperationType::Invalid),
    m_ItemsCount(0),
    m_SkipAll(false)
{
    
}

FileDeletionOperationJob::~FileDeletionOperationJob()
{
}

void FileDeletionOperationJob::Init(chained_strings _files, FileDeletionOperationType _type,
                                    const char* _root, FileDeletionOperation *_op)
{
    m_RequestedFiles.swap(_files);  
    m_Type = _type;
    strcpy(m_RootPath, _root);
    m_Operation = _op;
}

void FileDeletionOperationJob::Do()
{
    DoScan();

    if(CheckPauseOrStop()) { SetStopped(); return; }
    
    m_ItemsCount = m_ItemsToDelete.size();
    
    char entryfilename[MAXPATHLEN], *entryfilename_var;
    strcpy(entryfilename, m_RootPath);
    entryfilename_var = &entryfilename[0] + strlen(entryfilename);
    
    m_Stats.StartTimeTracking();
    m_Stats.SetMaxValue(m_ItemsCount);
    
    for(auto &i: m_ItemsToDelete)
    {
        if(CheckPauseOrStop()) { SetStopped(); return; }
        
        m_Stats.SetCurrentItem(i.str());
        
        i.str_with_pref(entryfilename_var);
        
        DoFile(entryfilename, i.str()[i.len-1] == '/');
    
        m_Stats.AddValue(1);
    }
    
    m_Stats.SetCurrentItem(0);
    
    if(CheckPauseOrStop()) { SetStopped(); return; }
    SetCompleted();
}

void FileDeletionOperationJob::DoScan()
{
    for(auto &i: m_RequestedFiles)
    {
        if (CheckPauseOrStop()) return;
        char fn[MAXPATHLEN];
        strcpy(fn, m_RootPath);
        strcat(fn, i.str()); // TODO: optimize me
        
        struct stat st;
        if(lstat(fn, &st) == 0)
        {
            if((st.st_mode&S_IFMT) == S_IFREG || (st.st_mode&S_IFMT) == S_IFLNK)
            {
                // trivial case
                m_ItemsToDelete.push_back(i.str(), i.len, nullptr);
            }
            else if((st.st_mode&S_IFMT) == S_IFDIR)
            {
                char tmp[MAXPATHLEN]; // i.str() + '/'
                memcpy(tmp, i.str(), i.len);
                tmp[i.len] = '/';
                tmp[i.len+1] = 0;
                
                // add new dir in our tree structure
                m_Directories.push_back(tmp, nullptr);
                
                auto dirnode = &m_Directories.back();
                
                // for moving to trash we need just to delete the topmost directories to preserve structure
                if(m_Type != FileDeletionOperationType::MoveToTrash)
                {
                    // add all items in directory
                    DoScanDir(fn, dirnode);
                }

                // add directory itself at the end, since we need it to be deleted last of all
                m_ItemsToDelete.push_back(tmp, i.len+1, nullptr);
            }
        }
    }
}

void FileDeletionOperationJob::DoScanDir(const char *_full_path, const chained_strings::node *_prefix)
{
    char fn[MAXPATHLEN], *fnvar; // fnvar - is a variable part for every file in directory
    strcpy(fn, _full_path);
    strcat(fn, "/");
    fnvar = &fn[0] + strlen(fn);
    
retry_opendir:
    DIR *dirp = opendir(_full_path);
    if( dirp != 0)
    {
        dirent *entp;
        while((entp = readdir(dirp)) != NULL)
        {
            if( (entp->d_namlen == 1 && entp->d_name[0] ==  '.' ) ||
               (entp->d_namlen == 2 && entp->d_name[0] ==  '.' && entp->d_name[1] ==  '.') )
                continue;

            // replace variable part with current item, so fn is RootPath/item_file_name now
            memcpy(fnvar, entp->d_name, entp->d_namlen+1);
            
        retry_lstat:
            struct stat st;
            if(lstat(fn, &st) == 0)
            {
                if((st.st_mode&S_IFMT) == S_IFREG || (st.st_mode&S_IFMT) == S_IFLNK)
                {
                    m_ItemsToDelete.push_back(entp->d_name, entp->d_namlen, _prefix);
                }
                else if((st.st_mode&S_IFMT) == S_IFDIR)
                {
                    char tmp[MAXPATHLEN];
                    memcpy(tmp, entp->d_name, entp->d_namlen);
                    tmp[entp->d_namlen] = '/';
                    tmp[entp->d_namlen+1] = 0;
                    // add new dir in our tree structure
                    m_Directories.push_back(tmp, entp->d_namlen+1, _prefix);
                    auto dirnode = &m_Directories.back();
                    
                    // add all items in directory
                    DoScanDir(fn, dirnode);

                    // add directory itself at the end, since we need it to be deleted last of all
                    m_ItemsToDelete.push_back(tmp, entp->d_namlen+1, _prefix);
                }
            }
            else if (!m_SkipAll)
            {
                int result = [[m_Operation DialogOnStatError:errno ForPath:fn] WaitForResult];
                if (result == OperationDialogResult::Retry)
                    goto retry_lstat;
                else if (result == OperationDialogResult::SkipAll) m_SkipAll = true;
                else if (result == OperationDialogResult::Stop)
                {
                    RequestStop();
                    break;
                }
            }
        }
        closedir(dirp);
    }
    else if (!m_SkipAll) // if (dirp != 0)
    {
        int result = [[m_Operation DialogOnOpendirError:errno ForDir:_full_path] WaitForResult];
        if (result == OperationDialogResult::Retry) goto retry_opendir;
        else if (result == OperationDialogResult::SkipAll) m_SkipAll = true;
        else if (result == OperationDialogResult::Stop) RequestStop();
    }
}

void FileDeletionOperationJob::DoFile(const char *_full_path, bool _is_dir)
{
    if(m_Type == FileDeletionOperationType::Delete)
    {
        DoDelete(_full_path, _is_dir);
    }
    else if(m_Type == FileDeletionOperationType::MoveToTrash)
    {
        DoMoveToTrash(_full_path, _is_dir);
    }
    else if(m_Type == FileDeletionOperationType::SecureDelete)
    {
        DoSecureDelete(_full_path, _is_dir);
    }
}

bool FileDeletionOperationJob::DoDelete(const char *_full_path, bool _is_dir)
{
    int ret = -1;
    // delete. just delete.
    if( !_is_dir )
    {
    retry_unlink:
        ret = unlink(_full_path);
        if( ret != 0 && !m_SkipAll )
        {
            int result = [[m_Operation DialogOnUnlinkError:errno ForPath:_full_path] WaitForResult];
            if (result == OperationDialogResult::Retry) goto retry_unlink;
            else if (result == OperationDialogResult::SkipAll) m_SkipAll = true;
            else if (result == OperationDialogResult::Stop) RequestStop();
        }
    }
    else
    {
    retry_rmdir:
        ret = rmdir(_full_path);
        if( ret != 0 && !m_SkipAll )
        {
            int result = [[m_Operation DialogOnRmdirError:errno ForPath:_full_path] WaitForResult];
            if (result == OperationDialogResult::Retry) goto retry_rmdir;
            else if (result == OperationDialogResult::SkipAll) m_SkipAll = true;
            else if (result == OperationDialogResult::Stop) RequestStop();
        }
    }
    return ret == 0;
}

bool FileDeletionOperationJob::DoMoveToTrash(const char *_full_path, bool _is_dir)
{
    if( [[NSFileManager defaultManager] respondsToSelector: @selector(trashItemAtURL)]  )
    {
        // We're on 10.8 or later
        // This construction is VERY slow. Thanks, Apple!
        NSString *str = [[NSString alloc ]initWithBytesNoCopy:(void*)_full_path
                                                    length:strlen(_full_path)
                                                    encoding:NSUTF8StringEncoding
                                                freeWhenDone:NO];
        NSURL *path = [NSURL fileURLWithPath:str isDirectory:_is_dir];
        NSURL *newpath;
        NSError *error;
        // Available in OS X v10.8 and later
    retry_delete:
        if(![[NSFileManager defaultManager] trashItemAtURL:path resultingItemURL:&newpath error:&error])
        {
            if (!m_SkipAll)
            {
                int result = [[m_Operation DialogOnTrashItemError:error ForPath:_full_path]
                            WaitForResult];
                if (result == OperationDialogResult::Retry) goto retry_delete;
                else if (result == OperationDialogResult::SkipAll) m_SkipAll = true;
                else if (result == OperationDialogResult::Stop) RequestStop();
                else if (result == FileDeletionOperationDR::DeletePermanently)
                {
                    // User can choose to delete item permanently.
                    return DoDelete(_full_path, _is_dir);
                }
            }
            return false;
        }
    }
    else
    {
        // We're on 10.7 or below
        FSRef ref;
        OSStatus status = FSPathMakeRefWithOptions((const UInt8 *)_full_path, kFSPathMakeRefDoNotFollowLeafSymlink, &ref, NULL);
        assert(status == 0);
        
    retry_delete_fs:
        status = FSMoveObjectToTrashSync(&ref, NULL, kFSFileOperationDefaultOptions);
        // do we need to free FSRef somehow???
        if(status != 0)
        {
            if (!m_SkipAll)
            {
                int result = [[m_Operation DialogOnTrashItemError:[NSError errorWithDomain:NSOSStatusErrorDomain
                                                                                      code:status
                                                                                  userInfo:nil]
                                                          ForPath:_full_path]
                              WaitForResult];
                if (result == OperationDialogResult::Retry) goto retry_delete_fs;
                else if (result == OperationDialogResult::SkipAll) m_SkipAll = true;
                else if (result == OperationDialogResult::Stop) RequestStop();
                else if (result == FileDeletionOperationDR::DeletePermanently)
                {
                    // User can choose to delete item permanently.
                    return DoDelete(_full_path, _is_dir);
                }
            }
            return false;
        }
    }

    return true;
}

bool FileDeletionOperationJob::DoSecureDelete(const char *_full_path, bool _is_dir)
{
    if( !_is_dir )
    {
        // fill file content with random data
        unsigned char data[4096];
        const int passes=3;

        struct stat st;
        if( lstat(_full_path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK)
        {
            // just unlink a symlink, do not try to fill it with trash -
            // it produces fancy "Too many levels of symbolic links" error
            unlink_symlink:
            if(unlink(_full_path) != 0)
            {
                if (!m_SkipAll)
                {
                    int result = [[m_Operation DialogOnUnlinkError:errno ForPath:_full_path]
                                  WaitForResult];
                    if (result == OperationDialogResult::Retry) goto unlink_symlink;
                    else if (result == OperationDialogResult::SkipAll) m_SkipAll = true;
                    else if (result == OperationDialogResult::Stop) RequestStop();
                }
                return false;
            }
            return true;
        }
        
    retry_open:
        int fd = open(_full_path, O_WRONLY|O_EXLOCK|O_NOFOLLOW);
        if(fd != -1)
        {
            // TODO: error handlings!!!
            off_t size = lseek(fd, 0, SEEK_END);
            for(int pass=0; pass < passes; ++pass)
            {
                lseek(fd, 0, SEEK_SET);
                off_t written=0;
                while(written < size)
                {
                    Randomize(data, 4096);
                retry_write:
                    ssize_t wn = write(fd, data, size - written > 4096 ? 4096 : size - written);
                    if(wn >= 0)
                    {
                        written += wn;
                    }
                    else
                    {
                        if (!m_SkipAll)
                        {
                            int result = [[m_Operation DialogOnUnlinkError:errno
                                                                   ForPath:_full_path]
                                          WaitForResult];
                            if (result == OperationDialogResult::Retry) goto retry_write;
                            else if (result == OperationDialogResult::SkipAll) m_SkipAll = true;
                            else if (result == OperationDialogResult::Stop)
                                RequestStop();
                        }
                        
                        // Break on skip, continue or abort.
                        break;
                    }
                }
            }
            close(fd);
            
        retry_unlink:
            // now delete it on file system level
            if(unlink(_full_path) != 0)
            {
                if (!m_SkipAll)
                {
                    int result = [[m_Operation DialogOnUnlinkError:errno ForPath:_full_path]
                                  WaitForResult];
                    if (result == OperationDialogResult::Retry) goto retry_unlink;
                    else if (result == OperationDialogResult::SkipAll) m_SkipAll = true;
                    else if (result == OperationDialogResult::Stop) RequestStop();
                }
                return false;
            }
        }
        else
        {
            if (!m_SkipAll)
            {
                int result = [[m_Operation DialogOnUnlinkError:errno ForPath:_full_path]
                              WaitForResult];
                if (result == OperationDialogResult::Retry) goto retry_open;
                else if (result == OperationDialogResult::SkipAll) m_SkipAll = true;
                else if (result == OperationDialogResult::Stop)
                    RequestStop();
            }
            return false;
        }
    }
    else
    {
    retry_rmdir:
        if(rmdir(_full_path) != 0 )
        {
            if (!m_SkipAll)
            {
                int result = [[m_Operation DialogOnRmdirError:errno ForPath:_full_path]
                              WaitForResult];
                if (result == OperationDialogResult::Retry) goto retry_rmdir;
                else if (result == OperationDialogResult::SkipAll) m_SkipAll = true;
                else if (result == OperationDialogResult::Stop) RequestStop();
            }
            return false;
        }
    }
    return true;
}

