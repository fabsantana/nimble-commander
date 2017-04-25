//
//  PanelController+Navigation.m
//  Files
//
//  Created by Michael G. Kazakov on 21.12.13.
//  Copyright (c) 2013 Michael G. Kazakov. All rights reserved.
//

#include <Habanero/CommonPaths.h>
#include <VFS/Native.h>
#include "PanelController.h"
#include <NimbleCommander/Core/Alert.h>

static void ShowExceptionAlert( const string &_message = "" )
{
    if( dispatch_is_main_queue() ) {
        auto alert = [[Alert alloc] init];
        alert.messageText = @"Unexpected exception was caught:";
        alert.informativeText = !_message.empty() ?
            [NSString stringWithUTF8StdString:_message] :
            @"Unknown exception";
        [alert runModal];
    }
    else {
        dispatch_to_main_queue([_message]{
            ShowExceptionAlert(_message);
        });
    }
}

@implementation PanelController (Navigation)

- (void) GoToVFSPromise:(const VFSInstanceManager::Promise&)_promise onPath:(const string&)_directory
{
//    m_DirectoryLoadingQ->Run([=](const SerialQueue &_q){
    m_DirectoryLoadingQ.Run([=](){
        VFSHostPtr host;
        try {
            host = VFSInstanceManager::Instance().RetrieveVFS(_promise,
                                                              [&]{ return m_DirectoryLoadingQ.IsStopped(); }
                                                              );
        } catch (VFSErrorException &e) {
            return; // TODO: something
        }
        
        // TODO: need an ability to show errors at least
        dispatch_to_main_queue([=]{
            [self GoToDir:_directory
                      vfs:host
             select_entry:""
        loadPreviousState:true
                    async:true];
        });
    });
}

- (void) goToPersistentLocation:(const PanelDataPersisency::Location &)_location
{
    m_DirectoryLoadingQ.Run([=]{
        VFSHostPtr host;
        if( PanelDataPersisency::CreateVFSFromLocation(_location, host) == VFSError::Ok ) {
            string path = _location.path;
            dispatch_to_main_queue([=]{
                auto context = make_shared<PanelControllerGoToDirContext>();
                context->VFS = host;
                context->PerformAsynchronous = true;
                context->RequestedDirectory = path;
                [self GoToDirWithContext:context];
            });
        }
    });
}

- (int) GoToDir:(const string&)_dir
            vfs:(VFSHostPtr)_vfs
   select_entry:(const string&)_filename
          async:(bool)_asynchronous
{
    return [self GoToDir:_dir
                     vfs:_vfs
            select_entry:_filename
       loadPreviousState:false
                   async:_asynchronous];
}

- (int) GoToDir:(const string&)_dir
            vfs:(VFSHostPtr)_vfs
   select_entry:(const string&)_filename
loadPreviousState:(bool)_load_state
          async:(bool)_asynchronous
{
    auto c = make_shared<PanelControllerGoToDirContext>();
    c->RequestedDirectory = _dir;
    c->VFS = _vfs;
    c->RequestFocusedEntry = _filename;
    c->LoadPreviousViewState = _load_state;
    c->PerformAsynchronous = _asynchronous;
    
    return [self GoToDirWithContext:c];
}

- (int) GoToDirWithContext:(shared_ptr<PanelControllerGoToDirContext>)_context
{
    auto &c = _context;
    if(c->RequestedDirectory.empty() ||
       c->RequestedDirectory.front() != '/' ||
       !c->VFS)
        return VFSError::InvalidCall;
    
    if(c->PerformAsynchronous == false) {
        assert(dispatch_is_main_queue());
        m_DirectoryLoadingQ.Stop();
        m_DirectoryLoadingQ.Wait();
    }
    else {
        if(!m_DirectoryLoadingQ.Empty())
            return 0;
    }
    
    auto workblock = [=]() {
        try {
            if(!c->VFS->IsDirectory(c->RequestedDirectory.c_str(), 0, 0)) {
                c->LoadingResultCode = VFSError::FromErrno(ENOTDIR);
                if( c->LoadingResultCallback )
                    c->LoadingResultCallback( c->LoadingResultCode );
                return;
            }
            
            shared_ptr<VFSListing> listing;
            c->LoadingResultCode = c->VFS->FetchDirectoryListing(
                c->RequestedDirectory.c_str(),
                listing,
                m_VFSFetchingFlags,
                [&] { return m_DirectoryLoadingQ.IsStopped(); });
            if( c->LoadingResultCallback )
                c->LoadingResultCallback( c->LoadingResultCode );
            
            if( c->LoadingResultCode < 0 )
                return;
            // TODO: need an ability to show errors at least
            
            [self CancelBackgroundOperations]; // clean running operations if any
            dispatch_or_run_in_main_queue([=]{
                [m_View SavePathState];
                m_Data.Load(listing, PanelData::PanelType::Directory);
                [m_View dataUpdated];
                [m_View panelChangedWithFocusedFilename:c->RequestFocusedEntry
                                      loadPreviousState:c->LoadPreviousViewState];
                [self OnPathChanged];
            });
        }
        catch(exception &e) {
            ShowExceptionAlert(e.what());
        }
        catch(...){
            ShowExceptionAlert();
        }
    };
    
    if( c->PerformAsynchronous == false ) {
        //m_DirectoryLoadingQ->RunSyncHere(workblock);
        workblock();
        return c->LoadingResultCode;
    }
    else {
        m_DirectoryLoadingQ.Run(workblock);
        return 0;
    }
}

- (void) loadNonUniformListing:(const shared_ptr<VFSListing>&)_listing
{
    [self CancelBackgroundOperations]; // clean running operations if any
    dispatch_or_run_in_main_queue([=]{
        [m_View SavePathState];
        m_Data.Load(_listing, PanelData::PanelType::Temporary);
        [m_View dataUpdated];
        [m_View panelChangedWithFocusedFilename:"" loadPreviousState:false];
        [self OnPathChanged];
    });
}

- (void) RecoverFromInvalidDirectory
{
    path initial_path = self.currentDirectoryPath;
    auto initial_vfs = self.vfs;
//    m_DirectoryLoadingQ->Run([=](const SerialQueue &_que) {
    m_DirectoryLoadingQ.Run([=]{
        // 1st - try to locate a valid dir in current host
        path path = initial_path;
        auto vfs = initial_vfs;
        
        while(true)
        {
            if(vfs->IterateDirectoryListing(path.c_str(), [](const VFSDirEnt &_dirent) {
                    return false;
                }) >= 0) {
                dispatch_to_main_queue([=]{
                    [self GoToDir:path.native()
                              vfs:vfs
                     select_entry:""
                            async:true];
                });
                break;
            }
            
            if(path == "/")
                break;
            
            if(path.filename() == ".") path.remove_filename();
            path = path.parent_path();
        }
        
        // we can't work on this vfs. currently for simplicity - just go home
        dispatch_to_main_queue([=]{
            [self GoToDir:CommonPaths::Home()
                      vfs:VFSNativeHost::SharedHost()
             select_entry:""
                    async:true];
        });
    });
}

@end
