//
//  FileDeletionOperationJob.h
//  Directories
//
//  Created by Michael G. Kazakov on 05.04.13.
//  Copyright (c) 2013 Michael G. Kazakov. All rights reserved.
//

#pragma once

#import "OperationJob.h"
#include "FileDeletionOperation.h"

class FileDeletionOperationJob : public OperationJob
{
public:
    FileDeletionOperationJob();
    ~FileDeletionOperationJob();

    void Init(FlexChainedStringsChunk *_files, FileDeletionOperationType _type, const char* _root);
    
    enum State
    {
        StateInvalid,
        StateScanning,
        StateDeleting
    };
    
    State StateDetail(unsigned &_it_no, unsigned &_it_tot) const;
    
protected:
    virtual void Do();
    void DoScan();
    void DoScanDir(const char *_full_path, const FlexChainedStringsChunk::node *_prefix);
    void DoFile(const char *_full_path, bool _is_dir);
    
    FlexChainedStringsChunk *m_RequestedFiles;
    FlexChainedStringsChunk *m_Directories; // this container will store directories structure in direct order
    FlexChainedStringsChunk *m_DirectoriesLast;
    FlexChainedStringsChunk *m_ItemsToDelete; // this container will store files and directories to direct, they will use m_Directories to link path
    FlexChainedStringsChunk *m_ItemsToDeleteLast;
    FileDeletionOperationType m_Type;
    char m_RootPath[MAXPATHLEN];
    unsigned m_ItemsCount;
    unsigned m_CurrentItemNumber;
    State m_State;
};
