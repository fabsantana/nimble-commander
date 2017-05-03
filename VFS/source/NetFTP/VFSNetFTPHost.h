//
//  VFSNetFTPHost.h
//  Files
//
//  Created by Michael G. Kazakov on 17.03.14.
//  Copyright (c) 2014 Michael G. Kazakov. All rights reserved.
//

#pragma once
#include <VFS/VFSHost.h>
#include "VFSNetFTPInternalsForward.h"

// RTFM: http://www.ietf.org/rfc/rfc959.txt

class VFSNetFTPHost final : public VFSHost
{
public:
    VFSNetFTPHost(const string &_serv_url,
                  const string &_user,
                  const string &_passwd,
                  const string &_start_dir,
                  long   _port = 21);
    VFSNetFTPHost(const VFSConfiguration &_config); // should be of type VFSNetFTPHostConfiguration
    ~VFSNetFTPHost();

    static  const char *Tag;
    static VFSMeta Meta();
    virtual VFSConfiguration Configuration() const override;    

    const string &ServerUrl() const noexcept;
    const string &User() const noexcept;
    long Port() const noexcept;
    
    // core VFSHost methods
    virtual int FetchDirectoryListing(const char *_path,
                                     shared_ptr<VFSListing> &_target,
                                     int _flags,
                                     const VFSCancelChecker &_cancel_checker) override;
    
    virtual int IterateDirectoryListing(const char *_path, const function<bool(const VFSDirEnt &_dirent)> &_handler) override;
    
    virtual int Stat(const char *_path,
                     VFSStat &_st,
                     int _flags,
                     const VFSCancelChecker &_cancel_checker) override;
    
    virtual int StatFS(const char *_path,
                       VFSStatFS &_stat,
                       const VFSCancelChecker &_cancel_checker) override;

    virtual int CreateFile(const char* _path,
                           shared_ptr<VFSFile> &_target,
                           const VFSCancelChecker &_cancel_checker) override;
    
    virtual int CreateDirectory(const char* _path,
                                int _mode,
                                const VFSCancelChecker &_cancel_checker) override;
    
    virtual int Unlink(const char *_path, const VFSCancelChecker &_cancel_checker) override;
    virtual int RemoveDirectory(const char *_path, const VFSCancelChecker &_cancel_checker) override;
    virtual int Rename(const char *_old_path, const char *_new_path, const VFSCancelChecker &_cancel_checker) override;
    
    virtual bool ShouldProduceThumbnails() const override;
    virtual bool IsWritable() const override;
    
    virtual bool IsDirChangeObservingAvailable(const char *_path) override;    
    virtual VFSHostDirObservationTicket DirChangeObserve(const char *_path, function<void()> _handler) override;
    virtual void StopDirChangeObserving(unsigned long _ticket) override;    

    // internal stuff below:
    string BuildFullURLString(const char *_path) const;

    void MakeDirectoryStructureDirty(const char *_path);
    
    unique_ptr<VFSNetFTP::CURLInstance> InstanceForIOAtDir(const path &_dir);
    void CommitIOInstanceAtDir(const path &_dir, unique_ptr<VFSNetFTP::CURLInstance> _i);
    
    
    inline VFSNetFTP::Cache &Cache() const { return *m_Cache.get(); };
    
    shared_ptr<const VFSNetFTPHost> SharedPtr() const {return static_pointer_cast<const VFSNetFTPHost>(VFSHost::SharedPtr());}
    shared_ptr<VFSNetFTPHost> SharedPtr() {return static_pointer_cast<VFSNetFTPHost>(VFSHost::SharedPtr());}
    
private:
    int DoInit();
    int DownloadAndCacheListing(VFSNetFTP::CURLInstance *_inst,
                                const char *_path,
                                shared_ptr<VFSNetFTP::Directory> *_cached_dir,
                                VFSCancelChecker _cancel_checker);
    
    int GetListingForFetching(VFSNetFTP::CURLInstance *_inst,
                         const char *_path,
                         shared_ptr<VFSNetFTP::Directory> *_cached_dir,
                         VFSCancelChecker _cancel_checker);
    
    unique_ptr<VFSNetFTP::CURLInstance> SpawnCURL();
    
    int DownloadListing(VFSNetFTP::CURLInstance *_inst,
                        const char *_path,
                        string &_buffer,
                        VFSCancelChecker _cancel_checker);
    
    void InformDirectoryChanged(const string &_dir_wth_sl);
    
    void BasicOptsSetup(VFSNetFTP::CURLInstance *_inst);
    const class VFSNetFTPHostConfiguration &Config() const noexcept;
    
    unique_ptr<VFSNetFTP::Cache>        m_Cache;
    unique_ptr<VFSNetFTP::CURLInstance> m_ListingInstance;
    
    map<path, unique_ptr<VFSNetFTP::CURLInstance>>  m_IOIntances;
    mutex                                           m_IOIntancesLock;
    
    struct UpdateHandler
    {
        unsigned long ticket;
        function<void()> handler;
        string        path; // path with trailing slash
    };

    vector<UpdateHandler>           m_UpdateHandlers;
    mutex                           m_UpdateHandlersLock;
    unsigned long                   m_LastUpdateTicket = 1;
    VFSConfiguration                m_Configuration;
};
