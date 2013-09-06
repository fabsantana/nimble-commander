//
//  PanelController.m
//  Directories
//
//  Created by Michael G. Kazakov on 22.02.13.
//  Copyright (c) 2013 Michael G. Kazakov. All rights reserved.
//

#import "PanelController.h"
#import "FSEventsDirUpdate.h"
#import "Common.h"
#import "MainWindowController.h"
#import "QuickPreview.h"
#import "MainWindowFilePanelState.h"
#import "filesysinfo.h"
#import "FileMask.h"
#import "PanelFastSearchPopupViewController.h"

#import "VFS.h"
#import <string>

static const uint64_t g_FastSeachDelayTresh = 5000000000; // 5 sec

@implementation PanelController
{
    PanelData *m_Data;
    PanelView *m_View;
    std::vector<std::shared_ptr<VFSHost>> m_HostsStack; // by default [0] is NativeHost
    
    __unsafe_unretained MainWindowController *m_WindowController;
    unsigned long m_UpdatesObservationTicket;
    
    // Fast searching section
    NSString *m_FastSearchString;
    uint64_t m_FastSearchLastType;
    unsigned m_FastSearchOffset;
    PanelFastSearchPopupViewController *m_FastSearchPopupView;
    
    // background directory size calculation support
    bool     m_IsStopDirectorySizeCounting; // flags current any other those tasks in queue that they need to stop
    bool     m_IsDirectorySizeCounting; // is background task currently working?
    dispatch_queue_t m_DirectorySizeCountingQ;
    
    // background directory changing (loading) support
    bool     m_IsStopDirectoryLoading; // flags current any other those tasks in queue that they need to stop
    bool     m_IsDirectoryLoading; // is background task currently working?
    dispatch_queue_t m_DirectoryLoadingQ;
    bool     m_IsStopDirectoryReLoading; // flags current any other those tasks in queue that they need to stop
    bool     m_IsDirectoryReLoading; // is background task currently working?
    dispatch_queue_t m_DirectoryReLoadingQ;
    
    // spinning indicator support
    bool                m_IsAnythingWorksInBackground;
    NSProgressIndicator *m_SpinningIndicator;
    
    NSButton            *m_EjectButton;
    
    // delayed entry selection support
    struct
    {
        bool        isvalid;
        char        filename[MAXPATHLEN];
        uint64_t    request_end; // time after which request is meaningless and should be removed
    } m_DelayedSelection;
}

- (id)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil
{
    self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];
    if (self) {
        // Initialization code here.
        m_UpdatesObservationTicket = 0;
        m_FastSearchLastType = 0;
        m_FastSearchOffset = 0;
        m_IsStopDirectorySizeCounting = false;
        m_IsStopDirectoryLoading = false;
        m_IsStopDirectoryReLoading = false;
        m_IsDirectorySizeCounting = false;
        m_IsAnythingWorksInBackground = false;
        m_IsDirectoryLoading = false;
        m_IsDirectoryReLoading = false;
        m_DirectorySizeCountingQ = dispatch_queue_create("com.example.paneldirsizecounting", 0);
        m_DirectoryLoadingQ = dispatch_queue_create("com.example.paneldirloading", 0);
        m_DirectoryReLoadingQ = dispatch_queue_create("com.example.paneldirreloading", 0);
        m_DelayedSelection.isvalid = false;
        
        m_HostsStack.push_back( VFSNativeHost::SharedHost() );
    }

    return self;
}

- (void) dealloc
{
    if(m_DirectorySizeCountingQ)
        dispatch_release(m_DirectorySizeCountingQ);
    if(m_DirectoryLoadingQ)
        dispatch_release(m_DirectoryLoadingQ);
    if(m_DirectoryReLoadingQ)
        dispatch_release(m_DirectoryReLoadingQ);
}

- (void) SetData:(PanelData*)_data
{
    m_Data = _data;
    [self CancelBackgroundOperations];
}

- (void) SetView:(PanelView*)_view
{
    m_View = _view;
    [self setView:_view]; // do we need it?
}

- (void) LoadViewState:(NSDictionary *)_state
{
    PanelSortMode mode = m_Data->GetCustomSortMode();
    
    mode.sep_dirs = [[_state valueForKey:@"SeparateDirectories"] boolValue];
    mode.show_hidden = [[_state valueForKey:@"ViewHiddenFiles"] boolValue];
    mode.case_sens = [[_state valueForKey:@"CaseSensitiveComparison"] boolValue];
    mode.numeric_sort = [[_state valueForKey:@"NumericSort"] boolValue];
    mode.sort = (PanelSortMode::Mode)[[_state valueForKey:@"SortMode"] integerValue];
    [self ChangeSortingModeTo:mode];
                                      
    [m_View ToggleViewType:(PanelViewType)[[_state valueForKey:@"ViewMode"] integerValue]];
    
}

- (NSDictionary *) SaveViewState
{
    PanelSortMode mode = m_Data->GetCustomSortMode();
    
    return [NSDictionary dictionaryWithObjectsAndKeys:
        [NSNumber numberWithBool:(mode.sep_dirs != false)], @"SeparateDirectories",
        [NSNumber numberWithBool:(mode.show_hidden != false)], @"ViewHiddenFiles",
        [NSNumber numberWithBool:(mode.case_sens != false)], @"CaseSensitiveComparison",
        [NSNumber numberWithBool:(mode.numeric_sort != false)], @"NumericSort",
        [NSNumber numberWithInt:(int)[m_View GetCurrentViewType]], @"ViewMode",
        [NSNumber numberWithInt:(int)mode.sort], @"SortMode",
        nil];
}

- (void) RequestActivation
{
    NSView *parent = [m_View superview];
    assert([parent isKindOfClass: [MainWindowFilePanelState class]]);
    [(MainWindowFilePanelState*)parent ActivatePanelByController:self];
}

- (void) HandleShiftReturnButton
{
    char path[MAXPATHLEN];
    int pos = [m_View GetCursorPosition];
    if(pos >= 0)
    {
        int rawpos = m_Data->SortPosToRawPos(pos);
        const auto &ent = m_Data->EntryAtRawPosition(rawpos);

        m_Data->GetDirectoryPathWithTrailingSlash(path);
        if(!ent.IsDotDot())
            strcat(path, ent.Name());
        
        BOOL success = [[NSWorkspace sharedWorkspace]
                        openFile:[NSString stringWithUTF8String:path]];
        if (!success) NSBeep();
    }
}

- (void) ChangeSortingModeTo:(PanelSortMode)_mode
{
    int curpos = [m_View GetCursorPosition];
    if(curpos >= 0)
    {
        int rawpos = m_Data->SortedDirectoryEntries()[curpos];
        m_Data->SetCustomSortMode(_mode);
        int newcurpos = m_Data->FindSortedEntryIndex(rawpos);
        if(newcurpos >= 0)
        {
            [m_View SetCursorPosition:newcurpos];
        }
        else
        {
            // there's no such element in this representation
            if(curpos < m_Data->SortedDirectoryEntries().size())
                [m_View SetCursorPosition:curpos];
            else
                [m_View SetCursorPosition:(int)m_Data->SortedDirectoryEntries().size()-1];
        }
    }
    else
    {
        m_Data->SetCustomSortMode(_mode);
    }
    [m_View setNeedsDisplay:true];
}

- (void) MakeSortWith:(PanelSortMode::Mode)_direct Rev:(PanelSortMode::Mode)_rev
{
    PanelSortMode mode = m_Data->GetCustomSortMode(); // we don't want to change anything in sort params except the mode itself
    if(mode.sort != _direct)  mode.sort = _direct;
    else                      mode.sort = _rev;
    [self ChangeSortingModeTo:mode];
}

- (void) ToggleViewHiddenFiles
{
    PanelSortMode mode = m_Data->GetCustomSortMode();
    mode.show_hidden = !mode.show_hidden;
    [self ChangeSortingModeTo:mode];    
}

- (void) ToggleSeparateFoldersFromFiles
{
    PanelSortMode mode = m_Data->GetCustomSortMode();
    mode.sep_dirs = !mode.sep_dirs;
    [self ChangeSortingModeTo:mode];
}

- (void) ToggleCaseSensitiveComparison
{
    PanelSortMode mode = m_Data->GetCustomSortMode();
    mode.case_sens = !mode.case_sens;
    [self ChangeSortingModeTo:mode];
}

- (void) ToggleNumericComparison
{
    PanelSortMode mode = m_Data->GetCustomSortMode();
    mode.numeric_sort = !mode.numeric_sort;
    [self ChangeSortingModeTo:mode];
}

- (void) ToggleSortingBySize{
    [self MakeSortWith:PanelSortMode::SortBySize Rev:PanelSortMode::SortBySizeRev];
}

- (void) ToggleSortingByName{
    [self MakeSortWith:PanelSortMode::SortByName Rev:PanelSortMode::SortByNameRev];
}

- (void) ToggleSortingByMTime{
    [self MakeSortWith:PanelSortMode::SortByMTime Rev:PanelSortMode::SortByMTimeRev];
}

- (void) ToggleSortingByBTime{
    [self MakeSortWith:PanelSortMode::SortByBTime Rev:PanelSortMode::SortByBTimeRev];
}

- (void) ToggleSortingByExt{
    [self MakeSortWith:PanelSortMode::SortByExt Rev:PanelSortMode::SortByExtRev];
}

- (void) ToggleShortViewMode{
    [m_View ToggleViewType:PanelViewType::ViewShort];
}

- (void) ToggleMediumViewMode{
    [m_View ToggleViewType:PanelViewType::ViewMedium];
}

- (void) ToggleFullViewMode{
    [m_View ToggleViewType:PanelViewType::ViewFull];
}

- (void) ToggleWideViewMode{
    [m_View ToggleViewType:PanelViewType::ViewWide];
}

- (void) FireDirectoryChanged: (const char*) _dir ticket:(unsigned long)_ticket
{
    // check if this tickes is ours
    if(_ticket == m_UpdatesObservationTicket) // integers comparison - just a blazing fast check
    {
        // update directory now!
        [self RefreshDirectory];
    }
}

- (void) ResetUpdatesObservation:(const char *) _new_path
{
    FSEventsDirUpdate::Inst()->RemoveWatchPathWithTicket(m_UpdatesObservationTicket);
    m_UpdatesObservationTicket = FSEventsDirUpdate::Inst()->AddWatchPath(_new_path);
}

//- (void) GoToDirectory:(const char*) _dir
//{
//    [self GoToRelativeToHostSync:_dir];
/*    return;
    
    assert(_dir && strlen(_dir));
    char *path = strdup(_dir);

    auto onsucc = ^(PanelData::DirectoryChangeContext* _context){
        m_IsStopDirectorySizeCounting = true;
        m_IsStopDirectoryLoading = true;
        m_IsStopDirectoryReLoading = true;        
        dispatch_async(dispatch_get_main_queue(), ^{
            m_Data->GoToDirectoryWithContext(_context);
            [m_View DirectoryChanged:PanelViewDirectoryChangeType::GoIntoOtherDir newcursor:0];
            [self OnPathChanged];
        });
    };
    
    auto onfail = ^(NSString* _path, NSError *_error) {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText: [NSString stringWithFormat:@"Failed to go into directory %@", _path]];
        [alert setInformativeText:[NSString stringWithFormat:@"Error: %@", [_error localizedFailureReason]]];
        dispatch_async(dispatch_get_main_queue(), ^{ [alert runModal]; });
    };
    
    if(m_IsStopDirectoryLoading)
        dispatch_async(m_DirectoryLoadingQ, ^{ m_IsStopDirectoryLoading = false; } );
    dispatch_async(m_DirectoryLoadingQ, ^{
        dispatch_async(dispatch_get_main_queue(), ^{[self NotifyDirectoryLoading:true];});
        PanelData::LoadFSDirectoryAsync(path, onsucc, onfail, ^bool(){return m_IsStopDirectoryLoading;} );
        dispatch_async(dispatch_get_main_queue(), ^{[self NotifyDirectoryLoading:false];});
    });*/
//GoToDirectory}

/*- (bool) GoToDirectorySync:(const char*) _dir
{
//    if(!m_Data->GoToDirectory(_dir))
//        return false;
    if([self GoToRelativeToHostSync:_dir] < 0)
        return false;

    // clean running operations if any
    m_IsStopDirectorySizeCounting = true;
    m_IsStopDirectoryLoading = true;
    m_IsStopDirectoryReLoading = true;
    [m_View DirectoryChanged:PanelViewDirectoryChangeType::GoIntoOtherDir newcursor:0];
    [self OnPathChanged];
    return true;
}*/

/*- (void) GoToRelativeToHostAsync:(const char*) _path
{
    // we need to ask our current host - is _path a dir?
    // if yes - try to get into it
    // if no - find if some file can act as c junction point on _path
    assert(!m_HostsStack.empty());
    bool isdir = m_HostsStack.back()->IsDirectory(_path, 0, 0);
    if(isdir)
    {
        __block std::shared_ptr<std::string> path = std::make_shared<std::string>(_path);
        if(m_IsStopDirectoryLoading)
            dispatch_async(m_DirectoryLoadingQ, ^{ m_IsStopDirectoryLoading = false; } );
        dispatch_async(m_DirectoryLoadingQ, ^{
            dispatch_async(dispatch_get_main_queue(), ^{[self NotifyDirectoryLoading:true];});
        
            std::shared_ptr<VFSListing> listing;
            
            int ret = m_HostsStack.back()->FetchDirectoryListing(path->c_str(), &listing, 0);
            if(ret < 0)
            {
                // error processing here
                m_IsStopDirectorySizeCounting = true;
                m_IsStopDirectoryLoading = true;
                m_IsStopDirectoryReLoading = true;
                dispatch_async(dispatch_get_main_queue(), ^{
//                    m_Data->GoToDirectoryWithContext(_context);
                    m_Data->GoToDirectoryWithListing(listing);
                    int newcursor_raw = m_Data->FindEntryIndex( [nscurdirname UTF8String] ), newcursor_sort = 0;
                    if(newcursor_raw >= 0) newcursor_sort = m_Data->FindSortedEntryIndex(newcursor_raw);
                    if(newcursor_sort < 0) newcursor_sort = 0;
                    [m_View DirectoryChanged:PanelViewDirectoryChangeType::GoIntoParentDir newcursor:newcursor_sort];
                    [self OnPathChanged];
                });
            }
            else
            {
                
                
            }
                
            
            
//            PanelData::LoadFSDirectoryAsync(blockpath, onsucc, onfail, ^bool(){return m_IsStopDirectoryLoading;});
            
            dispatch_async(dispatch_get_main_queue(), ^{[self NotifyDirectoryLoading:false];});
        });
        
        
        
        
    }
    else
    {
        // junction stuff here
        
        
    }
}*/

- (void) GoToRelativeToHostAsync:(const char*) _path
{
    std::string path = std::string(_path);
    
    if(m_IsStopDirectoryLoading)
        dispatch_async(m_DirectoryLoadingQ, ^{ m_IsStopDirectoryLoading = false; } );
    dispatch_async(m_DirectoryLoadingQ, ^{
        dispatch_async(dispatch_get_main_queue(), ^{[self NotifyDirectoryLoading:true];});
        
        std::shared_ptr<VFSListing> listing;
        
        int ret = m_HostsStack.back()->FetchDirectoryListing(path.c_str(), &listing, ^{return m_IsStopDirectoryLoading;});
        if(ret >= 0)
        {
            m_IsStopDirectorySizeCounting = true;
            m_IsStopDirectoryLoading = true;
            m_IsStopDirectoryReLoading = true;
            dispatch_async(dispatch_get_main_queue(), ^{
                m_Data->Load(listing);
                [m_View DirectoryChanged:PanelViewDirectoryChangeType::GoIntoOtherDir newcursor:0];
                [self OnPathChanged];
            });
        }
        else
        {
            // error processing here
            /*                auto onfail = ^(NSString* _path, NSError *_error) {
             NSAlert *alert = [[NSAlert alloc] init];
             [alert setMessageText: [NSString stringWithFormat:@"Failed to enter directory %@", _path]];
             [alert setInformativeText:[NSString stringWithFormat:@"Error: %@", [_error localizedFailureReason]]];
             dispatch_async(dispatch_get_main_queue(), ^{ [alert runModal]; });
             };*/
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{[self NotifyDirectoryLoading:false];});
    });
    
}

- (int) GoToRelativeToHostSync:(const char*) _path
{
    // we need to ask our current host - is _path a dir?
    // if yes - try to get into it
    // if no - find if some file can act as c junction point on _path
    assert(!m_HostsStack.empty());
    bool isdir = m_HostsStack.back()->IsDirectory(_path, 0, 0);
    if(isdir)
    {
//        return m_Data->GoToSync(_path, m_HostsStack.back());
        std::shared_ptr<VFSListing> listing;
        
        int ret = m_HostsStack.back()->FetchDirectoryListing(_path, &listing, 0);
        if(ret < 0)
            return ret;
        
        m_Data->Load(listing);
        
        // clean running operations if any
        m_IsStopDirectorySizeCounting = true;
        m_IsStopDirectoryLoading = true;
        m_IsStopDirectoryReLoading = true;
        [m_View DirectoryChanged:PanelViewDirectoryChangeType::GoIntoOtherDir newcursor:0];
        [self OnPathChanged];
        
        return VFSError::Ok;
    }
    else
    {
        // junction stuff here
        assert(0);
        return 0;
        
    }
}

- (void) HandleReturnButton
{ // going async here
    int sort_pos = [m_View GetCursorPosition];
    if(sort_pos < 0)
        return;
    int raw_pos = m_Data->SortedDirectoryEntries()[sort_pos];
    // Handle directories.
    if (m_Data->DirectoryEntries()[raw_pos].IsDir())
    {
        if(!m_Data->DirectoryEntries()[raw_pos].IsDotDot() ||
           strcmp(m_Data->DirectoryEntries().RelativePath(), "/"))
        {
            char pathbuf[__DARWIN_MAXPATHLEN];
            m_Data->ComposeFullPathForEntry(raw_pos, pathbuf);
            std::string path = std::string(pathbuf);
        
            std::string curdirname("");
            if( m_Data->DirectoryEntries()[raw_pos].IsDotDot())
            { // go to parent directory
                char curdirnamebuf[__DARWIN_MAXPATHLEN];
                m_Data->GetDirectoryPathShort(curdirnamebuf);
                curdirname = curdirnamebuf;
            }
        
            if(m_IsStopDirectoryLoading)
                dispatch_async(m_DirectoryLoadingQ, ^{ m_IsStopDirectoryLoading = false; } );
            dispatch_async(m_DirectoryLoadingQ, ^{
                dispatch_async(dispatch_get_main_queue(), ^{[self NotifyDirectoryLoading:true];});
            
                std::shared_ptr<VFSListing> listing;
                int ret = m_HostsStack.back()->FetchDirectoryListing(path.c_str(), &listing, ^{return m_IsStopDirectoryLoading;});
                if(ret >= 0)
                {
                    m_IsStopDirectorySizeCounting = true;
                    m_IsStopDirectoryLoading = true;
                    m_IsStopDirectoryReLoading = true;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        m_Data->Load(listing);

                        if(curdirname.empty()) { // go into some sub-dir
                            [m_View DirectoryChanged:PanelViewDirectoryChangeType::GoIntoSubDir newcursor:0];
                        }
                        else { // go into dot-dot dir
                            int newcursor_raw = m_Data->FindEntryIndex(curdirname.c_str()), newcursor_sort = 0;
                            if(newcursor_raw >= 0) newcursor_sort = m_Data->FindSortedEntryIndex(newcursor_raw);
                            if(newcursor_sort < 0) newcursor_sort = 0;
                            [m_View DirectoryChanged:PanelViewDirectoryChangeType::GoIntoParentDir newcursor:newcursor_sort];
                        }
                        [self OnPathChanged];
                    });
                }
                else
                {
                    // error processing here
/*                  auto onfail = ^(NSString* _path, NSError *_error) {
                        NSAlert *alert = [[NSAlert alloc] init];
                        [alert setMessageText: [NSString stringWithFormat:@"Failed to enter directory %@", _path]];
                        [alert setInformativeText:[NSString stringWithFormat:@"Error: %@", [_error localizedFailureReason]]];
                        dispatch_async(dispatch_get_main_queue(), ^{ [alert runModal]; });
                    };*/
                }
            //            PanelData::LoadFSDirectoryAsync(blockpath, onsucc, onfail, ^bool(){return m_IsStopDirectoryLoading;});
                dispatch_async(dispatch_get_main_queue(), ^{[self NotifyDirectoryLoading:false];});
            });
            return;
        }
        else
        { // dot-dot entry on some root dir - therefore it's some VFS like archive
            char junct[1024];
            strcpy(junct, m_HostsStack.back()->JunctionPath());
            assert(strlen(junct) > 0);
            if( junct[strlen(junct)-1] == '/' ) junct[strlen(junct)-1] = 0;
            char junct_entry[1024];
            char directory_path[1024];
            strcpy(junct_entry, strrchr(junct, '/')+1);
//            if(strrchr(junct, '/') != junct)
                *(strrchr(junct, '/')+1) = 0;
            strcpy(directory_path, junct);
            
            std::string dir(directory_path), entry(junct_entry);

            m_HostsStack.pop_back();
            
            if(m_IsStopDirectoryLoading)
                dispatch_async(m_DirectoryLoadingQ, ^{ m_IsStopDirectoryLoading = false; } );
            dispatch_async(m_DirectoryLoadingQ, ^{
                dispatch_async(dispatch_get_main_queue(), ^{[self NotifyDirectoryLoading:true];});
                
                std::shared_ptr<VFSListing> listing;
                int ret = m_HostsStack.back()->FetchDirectoryListing(dir.c_str(), &listing, ^{return m_IsStopDirectoryLoading;});
                if(ret >= 0)
                {
                    m_IsStopDirectorySizeCounting = true;
                    m_IsStopDirectoryLoading = true;
                    m_IsStopDirectoryReLoading = true;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        m_Data->Load(listing);
                        int newcursor_raw = m_Data->FindEntryIndex(entry.c_str()), newcursor_sort = 0;
                        if(newcursor_raw >= 0) newcursor_sort = m_Data->FindSortedEntryIndex(newcursor_raw);
                        if(newcursor_sort < 0) newcursor_sort = 0;
                        [m_View DirectoryChanged:PanelViewDirectoryChangeType::GoIntoParentDir newcursor:newcursor_sort];
                        [self OnPathChanged];
                    });
                }
                else
                {
                    // error processing here
                }
                dispatch_async(dispatch_get_main_queue(), ^{[self NotifyDirectoryLoading:false];});
            });
            
            return;
        }
    }
    else
    { // VFS stuff here
        char pathbuf[__DARWIN_MAXPATHLEN];
        m_Data->ComposeFullPathForEntry(raw_pos, pathbuf);
        std::shared_ptr<VFSArchiveHost> arhost = std::make_shared<VFSArchiveHost>(pathbuf, m_HostsStack.back());
        if(arhost->Open() >= 0)
        {
            m_HostsStack.push_back(arhost);
            [self GoToRelativeToHostAsync:"/"];
            return;
        }
    }
    
    // If previous code didn't handle current item,
    // open item with the default associated application.
    [self HandleShiftReturnButton];
}

- (void) RefreshDirectory
{ // going async here
    char dirpathbuf[MAXPATHLEN];
    m_Data->GetDirectoryPathWithTrailingSlash(dirpathbuf);
    std::string dirpath(dirpathbuf);
    
    int oldcursorpos = [m_View GetCursorPosition];
    std::string oldcursorname = (oldcursorpos >= 0 ? [m_View CurrentItem]->Name() : "");
    
    if(m_IsStopDirectoryReLoading)
        dispatch_async(m_DirectoryReLoadingQ, ^{ m_IsStopDirectoryReLoading = false; } );
    dispatch_async(m_DirectoryReLoadingQ, ^{
        dispatch_async(dispatch_get_main_queue(), ^{[self NotifyDirectoryReLoading:true];});

        
        std::shared_ptr<VFSListing> listing;
        int ret = m_HostsStack.back()->FetchDirectoryListing(dirpath.c_str(), &listing, ^{return m_IsStopDirectoryReLoading;});
        if(ret >= 0)
        {
            m_IsStopDirectoryReLoading = true;
            dispatch_async(dispatch_get_main_queue(), ^{
                m_Data->ReLoad(listing);
                assert(m_Data->DirectoryEntries().Count() > 0); // algo logic doesn't support this case now
            
                int newcursorrawpos = m_Data->FindEntryIndex(oldcursorname.c_str());
                if( newcursorrawpos >= 0 )
                {
                    int sortpos = m_Data->FindSortedEntryIndex(newcursorrawpos);
                    [m_View SetCursorPosition:sortpos >= 0 ? sortpos : 0];
                }
                else
                {
                    if( oldcursorpos < m_Data->SortedDirectoryEntries().size() )
                        [m_View SetCursorPosition:oldcursorpos];
                    else
                        [m_View SetCursorPosition:int(m_Data->SortedDirectoryEntries().size() - 1)]; // assuming that any directory will have at leat ".."
                }
            
                [self CheckAgainstRequestedSelection];
                [m_View setNeedsDisplay:true];
            });
        }
        else
        {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self RecoverFromInvalidDirectory];
            });
        }

        dispatch_async(dispatch_get_main_queue(), ^{[self NotifyDirectoryReLoading:false];});
    });
}

- (void)HandleFastSearch: (NSString*) _key
{
    _key = [_key decomposedStringWithCanonicalMapping];
    uint64_t currenttime = GetTimeInNanoseconds();
    if(_key != nil)
    {
        if(m_FastSearchLastType + g_FastSeachDelayTresh < currenttime || m_FastSearchString == nil)
        {
            m_FastSearchString = _key; // flush
            m_FastSearchOffset = 0;
        }
        else
            m_FastSearchString = [m_FastSearchString stringByAppendingString:_key]; // append
    }
    m_FastSearchLastType = currenttime;
    
    if(m_FastSearchString == nil)
        return;

    unsigned ind, range;
    bool found_any = m_Data->FindSuitableEntry( (__bridge CFStringRef) m_FastSearchString, m_FastSearchOffset, &ind, &range);
    if(found_any)
    {
        if(m_FastSearchOffset > range)
            m_FastSearchOffset = range;
            
        int pos = m_Data->FindSortedEntryIndex(ind);
        if(pos >= 0)
            [m_View SetCursorPosition:pos];
    }

    if(!m_FastSearchPopupView)
    {
        m_FastSearchPopupView = [PanelFastSearchPopupViewController new];
        [m_FastSearchPopupView SetHandlers:^{[self HandleFastSearchPrevious];}
                                      Next:^{[self HandleFastSearchNext];}];
        [m_FastSearchPopupView PopUpWithView:m_View];
    }

    [m_FastSearchPopupView UpdateWithString:m_FastSearchString Matches:(found_any?range+1:0)];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, g_FastSeachDelayTresh+1000), dispatch_get_main_queue(),
                   ^{
                       if(m_FastSearchPopupView != nil)
                       {
                           uint64_t currenttime = GetTimeInNanoseconds();
                           if(m_FastSearchLastType + g_FastSeachDelayTresh <= currenttime)
                           {
                               [m_FastSearchPopupView PopOut];
                               m_FastSearchPopupView = nil;
                           }
                       }
                   });
}

- (void)HandleFastSearchPrevious
{
    if(m_FastSearchOffset > 0)
        m_FastSearchOffset--;
    [self HandleFastSearch:nil];
}

- (void)HandleFastSearchNext
{
    m_FastSearchOffset++;
    [self HandleFastSearch:nil];
}

- (void)keyDown:(NSEvent *)event
{
    NSString*  const character = [event charactersIgnoringModifiers];

    NSUInteger const modif       = [event modifierFlags];
    
#define ISMODIFIER(_v) ( (modif&NSDeviceIndependentModifierFlagsMask) == (_v) )

    if(ISMODIFIER(NSAlternateKeyMask) || ISMODIFIER(NSAlternateKeyMask|NSAlphaShiftKeyMask))
        [self HandleFastSearch:character];
    
    [self ClearSelectionRequest]; // on any key press we clear entry selection request if any
    
    if ( [character length] != 1 ) return;
    unichar const unicode        = [character characterAtIndex:0];
    unsigned short const keycode = [event keyCode];

    switch (unicode)
    {
        case NSHomeFunctionKey: [m_View HandleFirstFile]; break;
        case NSEndFunctionKey:  [m_View HandleLastFile]; break;
        case NSPageDownFunctionKey:      [m_View HandleNextPage]; break;
        case NSPageUpFunctionKey:        [m_View HandlePrevPage]; break;            
        case NSLeftArrowFunctionKey:
            if(modif & NSCommandKeyMask) [m_View HandleFirstFile];
            else if(modif &  NSAlternateKeyMask); // now nothing wilh alt+left now
            else                         [m_View HandlePrevColumn];
            break;
        case NSRightArrowFunctionKey:
            if(modif & NSCommandKeyMask) [m_View HandleLastFile];
            else if(modif &  NSAlternateKeyMask); // now nothing wilh alt+right now   
            else                         [m_View HandleNextColumn];
            break;
        case NSUpArrowFunctionKey:
            if(modif & NSCommandKeyMask) [m_View HandlePrevPage];
            else if(modif & NSAlternateKeyMask) [self HandleFastSearchPrevious];
            else                         [m_View HandlePrevFile];
            break;
        case NSDownArrowFunctionKey:
            if(modif & NSCommandKeyMask) [m_View HandleNextPage];
            else if(modif &  NSAlternateKeyMask) [self HandleFastSearchNext];
            else                         [m_View HandleNextFile];
            break;
        case NSCarriageReturnCharacter: // RETURN key
            if(ISMODIFIER(NSShiftKeyMask)) [self HandleShiftReturnButton];
            else                           [self HandleReturnButton];
            break;
    }
    
    switch (keycode)
    {
        case 53: // Esc button
            [self CancelBackgroundOperations];
            break;
    }
}

- (void) HandleFileView // F3
{
    // dummy for now. we need to analyze the selection and/or cursor position
    
    // Close quick preview, if it is open.
    if ([QuickPreview IsVisible])
    {
        [QuickPreview Hide];
        return;
    }
    
    char dir[MAXPATHLEN];
    m_Data->GetDirectoryPathWithTrailingSlash(dir);
    
    if(m_Data->GetSelectedItemsCount())
    {
        auto files = m_Data->StringsFromSelectedEntries();
        [self StartDirectorySizeCountingFor:files InDir:dir IsDotDot:false];
    }
    else
    {
        auto const *item = [m_View CurrentItem];
        if (!item) return;
        if (item->IsDir())
        {
            bool dotdot = item->IsDotDot();
            [self StartDirectorySizeCountingFor:dotdot ? 0 :FlexChainedStringsChunk::AllocateWithSingleString(item->Name())
                                          InDir:dir
                                       IsDotDot:dotdot];
        }
        else
        {
            [QuickPreview Show];
            [m_View UpdateQuickPreview];
        }
    }
}

- (void) StartDirectorySizeCountingFor:(FlexChainedStringsChunk *)_files InDir:(const char*)_dir IsDotDot:(bool)_isdotdot
{    
    std::string str(_dir);
    dispatch_async(m_DirectorySizeCountingQ, ^{
        m_IsStopDirectorySizeCounting = false;
        dispatch_async(dispatch_get_main_queue(), ^{[self NotifyDirectorySizeCounting:true];});
        // TODO: lock panel data?
        // guess it's better to move the following line into main thread
        // it may be a race condition with possible UB here. BAD!
        auto complet = ^(const char* _dir, uint64_t _size){
            if(m_Data->SetCalculatedSizeForDirectory(_dir, _size)){
                dispatch_async(dispatch_get_main_queue(), ^{
                    [m_View setNeedsDisplay:true];
                });
            }
        };

        if(!_isdotdot)
            m_HostsStack.back()->CalculateDirectoriesSizes(_files, str, ^bool { return m_IsStopDirectorySizeCounting; }, complet);
        else
            m_HostsStack.back()->CalculateDirectoryDotDotSize(str, ^bool { return m_IsStopDirectorySizeCounting; }, complet);
        
        dispatch_async(dispatch_get_main_queue(), ^{[self NotifyDirectorySizeCounting:false];});
    });
}

- (void) ModifierFlagsChanged:(unsigned long)_flags // to know if shift or something else is pressed
{
    [m_View ModifierFlagsChanged:_flags];
    
    if(m_FastSearchString != nil && (_flags & NSAlternateKeyMask) == 0)
    {
        // user was fast searching something, need to flush that string
        m_FastSearchString = nil;
        m_FastSearchOffset = 0;
        if(m_FastSearchPopupView != nil)
        {
            [m_FastSearchPopupView PopOut];
            m_FastSearchPopupView = nil;
        }
    }
}

- (void) AttachToControls:(NSProgressIndicator*)_indicator eject:(NSButton*)_eject;
{
    m_SpinningIndicator = _indicator;
    m_EjectButton = _eject;
    
    m_IsAnythingWorksInBackground = false;
    [m_SpinningIndicator stopAnimation:nil];
    [self UpdateSpinningIndicator];
    [self UpdateEjectButton];
    
    [m_EjectButton setTarget:self];
    [m_EjectButton setAction:@selector(OnEjectButton:)];
}

- (void) SetWindowController:(MainWindowController *)_cntrl
{
    m_WindowController = _cntrl;
}

- (void) NotifyDirectorySizeCounting:(bool) _is_running // true if task will start now, or false if it has just stopped
{
    m_IsDirectorySizeCounting = _is_running;
    [self UpdateSpinningIndicator];
}

- (void) NotifyDirectoryLoading:(bool) _is_running // true if task will start now, or false if it has just stopped
{
    m_IsDirectoryLoading = _is_running;
    [self UpdateSpinningIndicator];
}

- (void) NotifyDirectoryReLoading:(bool) _is_running // true if task will start now, or false if it has just stopped
{
    m_IsDirectoryReLoading = _is_running;
    [self UpdateSpinningIndicator];
}

- (void) CancelBackgroundOperations
{
    m_IsStopDirectorySizeCounting = true;
    m_IsStopDirectoryLoading = true;
    m_IsStopDirectoryReLoading = true;
}

- (void) UpdateSpinningIndicator
{
    bool is_anything_working = m_IsDirectorySizeCounting || m_IsDirectoryLoading || m_IsDirectoryReLoading;
    const auto visual_spinning_delay = 100ull; // in 100 ms of workload should be before user will get spinning indicator
    
    if(is_anything_working == m_IsAnythingWorksInBackground)
        return; // nothing to update;
        
    if(is_anything_working)
    {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, visual_spinning_delay * USEC_PER_SEC),
                       dispatch_get_main_queue(),
                       ^{
                           if(m_IsAnythingWorksInBackground) // need to check if task was already done
                           {
                               [m_SpinningIndicator startAnimation:nil];
                               if([m_SpinningIndicator isHidden])
                                   [m_SpinningIndicator setHidden:false];
                           }
                       });
    }
    else
    {
        [m_SpinningIndicator stopAnimation:nil];
        if(![m_SpinningIndicator isHidden])
            [m_SpinningIndicator setHidden:true];
        
    }
    
    m_IsAnythingWorksInBackground = is_anything_working;
}

- (void) UpdateEjectButton
{
    char path[MAXPATHLEN];
    m_Data->GetDirectoryPath(path);
    bool should_be_hidden = !IsVolumeContainingPathEjectable(path);
    
    if([m_EjectButton isHidden] != should_be_hidden)
        [m_EjectButton setHidden:should_be_hidden];
}

- (PanelViewType) GetViewType
{
    return [m_View GetCurrentViewType];
}

- (PanelSortMode) GetUserSortMode
{
    return m_Data->GetCustomSortMode();
}

- (void) RecoverFromInvalidDirectory
{
    // TODO: recovering to upper host needed
    char path[MAXPATHLEN];
    m_Data->GetDirectoryPath(path);
    if(GetFirstAvailableDirectoryFromPath(path))
//        [self GoToDirectory:path];
        [self GoToRelativeToHostAsync:path];
}

///////////////////////////////////////////////////////////////////////////////////////////////
// Delayed selection support

- (void) ScheduleDelayedSelectionChangeFor:(NSString *)_item_name timeoutms:(int)_time_out_in_ms checknow:(bool)_check_now
{
    [self ScheduleDelayedSelectionChangeForC:[_item_name fileSystemRepresentation]
                                   timeoutms:_time_out_in_ms
                                    checknow:_check_now];
}

- (void) ScheduleDelayedSelectionChangeForC:(const char*)_item_name timeoutms:(int)_time_out_in_ms checknow:(bool)_check_now
{
    assert(dispatch_get_current_queue() == dispatch_get_main_queue()); // to preserve against fancy threading stuff
    assert(_item_name);
    // we assume that _item_name will not contain any forward slashes
    
    m_DelayedSelection.isvalid = true;
    m_DelayedSelection.request_end = GetTimeInNanoseconds() + _time_out_in_ms*USEC_PER_SEC;
    strcpy(m_DelayedSelection.filename, _item_name);
    
    if(_check_now)
        [self CheckAgainstRequestedSelection];
}

- (void) CheckAgainstRequestedSelection
{
    assert(dispatch_get_current_queue() == dispatch_get_main_queue()); // to preserve against fancy threading stuff
    if(!m_DelayedSelection.isvalid)
        return;

    uint64_t now = GetTimeInNanoseconds();
    if(now > m_DelayedSelection.request_end)
    {
        m_DelayedSelection.isvalid = false;
        return;
    }
    
    // now try to find it
    int entryindex = m_Data->FindEntryIndex(m_DelayedSelection.filename);
    if( entryindex >= 0 )
    {
        // we found this entry. regardless of appearance of this entry in current directory presentation
        // there's no reason to search for it again
        m_DelayedSelection.isvalid = false;
        
        int sortpos = m_Data->FindSortedEntryIndex(entryindex);
        if( sortpos >= 0 )
            [m_View SetCursorPosition:sortpos];
    }
}

- (void) ClearSelectionRequest
{
    m_DelayedSelection.isvalid = false;
}

- (void) SelectAllEntries:(bool) _select
{
    m_Data->CustomFlagsSelectAllSorted(_select);
    [m_View setNeedsDisplay:true];
}

- (void) OnPathChanged
{
    char path[MAXPATHLEN];
    m_Data->GetDirectoryPathWithTrailingSlash(path);
    [self ResetUpdatesObservation:path];
    [self ClearSelectionRequest];   
    [self SignalParentOfPathChanged];
    [self UpdateEjectButton];
}

- (void) SignalParentOfPathChanged
{
    NSView *parent = [m_View superview];
    assert([parent isKindOfClass: [MainWindowFilePanelState class]]);
    [(MainWindowFilePanelState*)parent PanelPathChanged:self];
}

- (void)OnEjectButton:(id)sender
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        char path[MAXPATHLEN];
        m_Data->GetDirectoryPath(path); // not thread-safe, potentialy may cause problems, but not likely
        EjectVolumeContainingPath(path);
    });
}

- (void) SelectEntriesByMask:(NSString*)_mask select:(bool)_select
{
    const int stripe_size = 100;
    
    FileMask mask(_mask), *maskp = &mask;
    auto &entries = m_Data->DirectoryEntries();
    auto &sorted_entries = m_Data->SortedDirectoryEntries();
    bool ignore_dirs = [[NSUserDefaults standardUserDefaults] boolForKey:@"FilePanelsGeneralIgnoreDirectoriesOnSelectionWithMask"];

    dispatch_apply(sorted_entries.size() / stripe_size + 1, dispatch_get_global_queue(0, 0), ^(size_t n){
        size_t max = sorted_entries.size();
        for(size_t i = n*stripe_size; i < (n+1)*stripe_size && i < max; ++i) {
            const auto &entry = entries[i];
            if(ignore_dirs && entry.IsDir())
                continue;
            if(entry.IsDotDot())
                continue;
            if(maskp->MatchName((__bridge NSString*)entry.CFName()))
                m_Data->CustomFlagsSelect(i, _select);
        }
    });
    
    [m_View setNeedsDisplay:true];
}

@end
