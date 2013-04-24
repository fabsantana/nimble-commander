//
//  FileCopyOperation.h
//  Directories
//
//  Created by Michael G. Kazakov on 09.04.13.
//  Copyright (c) 2013 Michael G. Kazakov. All rights reserved.
//

#import "Operation.h"
#import "FlexChainedStringsChunk.h"
#import "OperationDialogAlert.h"
#import "FileAlreadyExistSheetController.h"

namespace FileCopyOperationDR
{
enum
{
    Overwrite = OperationDialogResult::Custom,
    Append
};
}

struct FileCopyOperationOptions
{
    bool docopy; // it it false then operation will do renaming/moving
    
    FileCopyOperationOptions():docopy(true){};
};

@interface FileCopyOperation : Operation

- (id)initWithFiles:(FlexChainedStringsChunk*)_files // passing with ownership, operation will free it on finish
               root:(const char*)_root
               dest:(const char*)_dest
            options:(FileCopyOperationOptions*)_opts;

- (OperationDialogAlert *)OnDestCantCreateDir:(int)_error ForDir:(const char *)_path;
- (OperationDialogAlert *)OnCopyCantCreateDir:(int)_error ForDir:(const char *)_path;
- (OperationDialogAlert *)OnCopyCantAccessSrcFile:(int)_error ForFile:(const char *)_path;
- (OperationDialogAlert *)OnCopyCantOpenDestFile:(int)_error ForFile:(const char *)_path;
- (OperationDialogAlert *)OnCopyReadError:(int)_error ForFile:(const char *)_path;
- (OperationDialogAlert *)OnCopyWriteError:(int)_error ForFile:(const char *)_path;
- (FileAlreadyExistSheetController *)OnFileExist: (const char*)_path
                                         newsize: (unsigned long)_newsize
                                         newtime: (time_t) _newtime
                                         exisize: (unsigned long)_exisize
                                         exitime: (time_t) _exitime
                                        remember: (bool*)  _remb;
- (OperationDialogAlert *)OnRenameDestinationExists:(const char *)_dest
                                             Source:(const char *)_src;

@end
