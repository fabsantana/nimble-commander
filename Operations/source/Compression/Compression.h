#pragma once

#include "../Operation.h"
#include <VFS/VFS.h>



/*
+TODO:
- adjusting stats on skips
*/


namespace nc::ops
{

class CompressionJob;

class Compression : public Operation
{
public:
    Compression(vector<VFSListingItem> _src_files,
                string _dst_root,
                VFSHostPtr _dst_vfs);
    virtual ~Compression();

    string ArchivePath() const;

protected:
    virtual Job *GetJob() noexcept override;

private:
    NSString *BuildTitlePrefix() const;
    string BuildInitialTitle() const;
    string BuildTitleWithArchiveFilename() const;
    void OnTargetPathDefined();
    void OnTargetWriteError(int _err, const string &_path, VFSHost &_vfs);
    void OnSourceReadError(int _err, const string &_path, VFSHost &_vfs);
    int OnSourceScanError(int _err, const string &_path, VFSHost &_vfs);
    void OnSourceScanErrorUI(int _err, const string &_path, VFSHostPtr _vfs,
                             shared_ptr<AsyncDialogResponse> _ctx);

    int OnSourceAccessError(int _err, const string &_path, VFSHost &_vfs);

    unique_ptr<CompressionJob> m_Job;
    bool m_SkipAll = false;
    int m_InitialSourceItemsAmount = 0;
    string m_InitialSingleItemFilename = "";
};

}
