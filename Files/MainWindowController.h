//
//  MainWindowController.h
//  Directories
//
//  Created by Michael G. Kazakov on 09.02.13.
//  Copyright (c) 2013 Michael G. Kazakov. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "FlexChainedStringsChunk.h"
#import "ApplicationSkins.h"
#import "VFS.h"

@class OperationsController;
@class MainWindowFilePanelState;

@interface MainWindowController : NSWindowController <NSWindowDelegate>

// Window state manipulations
- (void) ResignAsWindowState:(id)_state;

- (OperationsController*) OperationsController;

- (void)ApplySkin:(ApplicationSkin)_skin;
- (void)OnApplicationWillTerminate;

- (void)RevealEntries:(FlexChainedStringsChunk*)_entries inPath:(const char*)_path;

- (void)RequestBigFileView: (const char*)_filepath with_fs:(std::shared_ptr<VFSHost>) _host;


- (void)RequestTerminal;

// at current moment any main window must jave have file panel state, but it may change in the future
- (MainWindowFilePanelState*) FilePanelState;

@end
