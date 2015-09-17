//
//  PanelController.m
//  Directories
//
//  Created by Michael G. Kazakov on 22.02.13.
//  Copyright (c) 2013 Michael G. Kazakov. All rights reserved.
//

#import <Habanero/algo.h>
#import "PanelController.h"
#import "Common.h"
#import "MainWindowController.h"
#import "QuickPreview.h"
#import "MainWindowFilePanelState.h"
#import "PanelAux.h"
#import "SharingService.h"
#import "BriefSystemOverview.h"
#import "ActionsShortcutsManager.h"
#import "FileCopyOperation.h"
#import "SandboxManager.h"

static auto g_DefaultsQuickSearchKeyModifier   = @"FilePanelsQuickSearchKeyModifier";
static auto g_DefaultsQuickSearchSoftFiltering = @"FilePanelsQuickSearchSoftFiltering";
static auto g_DefaultsQuickSearchWhereToFind   = @"FilePanelsQuickSearchWhereToFind";
static auto g_DefaultsQuickSearchTypingView    = @"FilePanelsQuickSearchTypingView";
static auto g_DefaultsGeneralShowDotDotEntry       = @"FilePanelsGeneralShowDotDotEntry";
static auto g_DefaultsGeneralShowLocalizedFilenames= @"FilePanelsGeneralShowLocalizedFilenames";
static auto g_DefaultsGeneralIgnoreDirsOnMaskSel   = @"FilePanelsGeneralIgnoreDirectoriesOnSelectionWithMask";
static auto g_DefaultsGeneraluseTildeAsHomeShortcut =  @"FilePanelsGeneralUseTildeAsHomeShotcut";
static auto g_DefaultsGeneralRouteKeyboardInputIntoTerminal =  @"FilePanelsGeneralRouteKeyboardInputIntoTerminal";
static auto g_DefaultsKeys = @[g_DefaultsQuickSearchKeyModifier, g_DefaultsQuickSearchSoftFiltering,
                               g_DefaultsQuickSearchWhereToFind, g_DefaultsQuickSearchTypingView,
                               g_DefaultsGeneralShowDotDotEntry, g_DefaultsGeneralIgnoreDirsOnMaskSel,
                               g_DefaultsGeneralShowLocalizedFilenames];

panel::GenericCursorPersistance::GenericCursorPersistance(PanelView* _view, const PanelData &_data):
    m_View(_view),
    m_Data(_data)
{
    auto cur_pos = _view.curpos;
    if(cur_pos >= 0 && m_View.item ) {
        m_OldCursorName = m_View.item.Name();
        m_OldEntrySortKeys = _data.EntrySortKeysAtSortPosition(cur_pos);
    }
}

void panel::GenericCursorPersistance::Restore() const
{
    int newcursorrawpos = m_Data.RawIndexForName(m_OldCursorName.c_str());
    if( newcursorrawpos >= 0 ) {
        int newcursorsortpos = m_Data.SortedIndexForRawIndex(newcursorrawpos);
        if(newcursorsortpos >= 0)
            m_View.curpos = newcursorsortpos;
        else
            m_View.curpos = m_Data.SortedDirectoryEntries().empty() ? -1 : 0;
    }
    else {
        int lower_bound = m_Data.SortLowerBoundForEntrySortKeys(m_OldEntrySortKeys);
        if( lower_bound >= 0) {
            m_View.curpos = lower_bound;
        }
        else {
            m_View.curpos = m_Data.SortedDirectoryEntries().empty() ? -1 : int(m_Data.SortedDirectoryEntries().size()) - 1;
        }
    }
}

@implementation PanelController
@synthesize view = m_View;
@synthesize data = m_Data;
@synthesize lastNativeDirectoryPath = m_LastNativeDirectory;

- (id) init
{
    self = [super init];
    if(self) {
        m_QuickSearchLastType = 0ns;
        m_QuickSearchOffset = 0;
        m_VFSFetchingFlags = 0;
        m_IsAnythingWorksInBackground = false;
        m_DirectorySizeCountingQ = make_shared<SerialQueueT>(__FILES_IDENTIFIER__".paneldirsizecounting");
        m_DirectoryLoadingQ = make_shared<SerialQueueT>(__FILES_IDENTIFIER__".paneldirloading");
        m_DirectoryReLoadingQ = make_shared<SerialQueueT>(__FILES_IDENTIFIER__".paneldirreloading");
        m_DragDrop.last_valid_items = -1;
        
        __weak PanelController* weakself = self;
        auto on_change = ^{
            dispatch_to_main_queue([=]{
                [(PanelController*)weakself UpdateSpinningIndicator];
            });
        };
        m_DirectorySizeCountingQ->OnChange(on_change);
        m_DirectoryReLoadingQ->OnChange(on_change);
        m_DirectoryLoadingQ->OnChange(on_change);
        
        // loading defaults via simulating it's change
        [self observeValueForKeyPath:g_DefaultsQuickSearchKeyModifier ofObject:NSUserDefaults.standardUserDefaults change:nil context:nullptr];
        [self observeValueForKeyPath:g_DefaultsQuickSearchWhereToFind ofObject:NSUserDefaults.standardUserDefaults change:nil context:nullptr];
        [self observeValueForKeyPath:g_DefaultsQuickSearchSoftFiltering ofObject:NSUserDefaults.standardUserDefaults change:nil context:nullptr];
        [self observeValueForKeyPath:g_DefaultsQuickSearchTypingView ofObject:NSUserDefaults.standardUserDefaults change:nil context:nullptr];
        [self observeValueForKeyPath:g_DefaultsGeneralShowDotDotEntry ofObject:NSUserDefaults.standardUserDefaults change:nil context:nullptr];
        [self observeValueForKeyPath:g_DefaultsGeneralShowLocalizedFilenames ofObject:NSUserDefaults.standardUserDefaults change:nil context:nullptr];
        [NSUserDefaults.standardUserDefaults addObserver:self forKeyPaths:g_DefaultsKeys];
        
        m_View = [[PanelView alloc] initWithFrame:NSMakeRect(0, 0, 100, 100)];
        m_View.delegate = self;
        m_View.data = &m_Data;
        [self RegisterDragAndDropListeners];
    }

    return self;
}

- (void) dealloc
{
    [NSUserDefaults.standardUserDefaults removeObserver:self forKeyPaths:g_DefaultsKeys];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    
    if(object == defaults)
    {
        if([keyPath isEqualToString:g_DefaultsQuickSearchKeyModifier]) {
            m_QuickSearchMode = PanelQuickSearchMode::KeyModifFromInt((int)[defaults integerForKey:g_DefaultsQuickSearchKeyModifier]);
            [self QuickSearchClearFiltering];
        }
        else if([keyPath isEqualToString:g_DefaultsQuickSearchWhereToFind]) {
            m_QuickSearchWhere = PanelDataTextFiltering::WhereFromInt((int)[defaults integerForKey:g_DefaultsQuickSearchWhereToFind]);
            [self QuickSearchClearFiltering];
        }
        else if([keyPath isEqualToString:g_DefaultsQuickSearchSoftFiltering]) {
            m_QuickSearchIsSoftFiltering = [NSUserDefaults.standardUserDefaults boolForKey:g_DefaultsQuickSearchSoftFiltering];
            [self QuickSearchClearFiltering];
        }
        else if([keyPath isEqualToString:g_DefaultsQuickSearchTypingView]) {
            m_QuickSearchTypingView = [NSUserDefaults.standardUserDefaults boolForKey:g_DefaultsQuickSearchTypingView];
            [self QuickSearchClearFiltering];
        }
        else if([keyPath isEqualToString:g_DefaultsGeneralShowDotDotEntry]) {
            if([defaults boolForKey:g_DefaultsGeneralShowDotDotEntry] == false)
                m_VFSFetchingFlags |= VFSFlags::F_NoDotDot;
            else
                m_VFSFetchingFlags &= ~VFSFlags::F_NoDotDot;
            [self RefreshDirectory];
        }
        else if([keyPath isEqualToString:g_DefaultsGeneralShowLocalizedFilenames]) {
            if([defaults boolForKey:g_DefaultsGeneralShowLocalizedFilenames] == true)
                m_VFSFetchingFlags |= VFSFlags::F_LoadDisplayNames;
            else
                m_VFSFetchingFlags &= ~VFSFlags::F_LoadDisplayNames;
            [self RefreshDirectory];
        }
    }
}

- (void) setState:(MainWindowFilePanelState *)state
{
    m_FilePanelState = state;
}

- (MainWindowFilePanelState*)state
{
    return m_FilePanelState;
}

- (NSWindow*) window
{
    return self.state.window;
}

- (MainWindowController *)mainWindowController
{
    return (MainWindowController*)self.window.delegate;
}

- (bool) isUniform
{
    return m_Data.Listing().IsUniform();
}

- (void) setOptions:(NSDictionary *)options
{
    auto hard_filtering = m_Data.HardFiltering();
    hard_filtering.show_hidden = [[options valueForKey:@"ViewHiddenFiles"] boolValue];
    [self ChangeHardFilteringTo:hard_filtering];
    
    auto sort_mode = m_Data.SortMode();
    sort_mode.sep_dirs = [[options valueForKey:@"SeparateDirectories"] boolValue];
    sort_mode.case_sens = [[options valueForKey:@"CaseSensitiveComparison"] boolValue];
    sort_mode.numeric_sort = [[options valueForKey:@"NumericSort"] boolValue];
    sort_mode.sort = (PanelSortMode::Mode)[[options valueForKey:@"SortMode"] integerValue];
    [self ChangeSortingModeTo:sort_mode];
    
    m_View.type = (PanelViewType)[[options valueForKey:@"ViewMode"] integerValue];
}

- (NSDictionary*) options
{
    auto mode = m_Data.SortMode();
    return [NSDictionary dictionaryWithObjectsAndKeys:
            [NSNumber numberWithBool:(mode.sep_dirs != false)], @"SeparateDirectories",
            [NSNumber numberWithBool:(m_Data.HardFiltering().show_hidden != false)], @"ViewHiddenFiles",
            [NSNumber numberWithBool:(mode.case_sens != false)], @"CaseSensitiveComparison",
            [NSNumber numberWithBool:(mode.numeric_sort != false)], @"NumericSort",
            [NSNumber numberWithInt:(int)m_View.type], @"ViewMode",
            [NSNumber numberWithInt:(int)mode.sort], @"SortMode",
            nil];
}

- (bool) isActive
{
    return m_View.active;
}

- (void) HandleOpenInSystem
{
    // may go async here on non-native VFS
    // non-default behaviour here: "/Abra/.." will produce "/Abra/" insted of default-way "/"    
    if( auto item = m_View.item )
        PanelVFSFileWorkspaceOpener::Open(item.IsDotDot() ? item.Directory() : item.Path(),
                                          item.Host());
}

- (void) ChangeSortingModeTo:(PanelSortMode)_mode
{
    panel::GenericCursorPersistance pers(m_View, m_Data);
    
    m_Data.SetSortMode(_mode);

    pers.Restore();
    
    [m_View setNeedsDisplay];
}

- (void) ChangeHardFilteringTo:(PanelDataHardFiltering)_filter
{
    panel::GenericCursorPersistance pers(m_View, m_Data);
    
    m_Data.SetHardFiltering(_filter);
    
    pers.Restore();
    
    [m_View setNeedsDisplay];
}

- (void) MakeSortWith:(PanelSortMode::Mode)_direct Rev:(PanelSortMode::Mode)_rev
{
    PanelSortMode mode = m_Data.SortMode(); // we don't want to change anything in sort params except the mode itself
    mode.sort = mode.sort != _direct ? _direct : _rev;
    [self ChangeSortingModeTo:mode];
    [self.state savePanelOptionsFor:self];
}

- (bool) HandleGoToUpperDirectory
{
    if( self.isUniform  ) {
        path cur = path(m_Data.DirectoryPathWithTrailingSlash());
        if( cur.empty() )
            return false;
        if( cur == "/" ) {
            if( self.vfs->Parent() != nullptr ) {
                path junct = self.vfs->JunctionPath();
                assert(!junct.empty());
                string dir = junct.parent_path().native();
                string sel_fn = junct.filename().native();
                
                if(self.vfs->Parent()->IsNativeFS() && ![self ensureCanGoToNativeFolderSync:dir])
                    return true; // silently reap this command, since user refuses to grant an access
                return [self GoToDir:dir vfs:self.vfs->Parent() select_entry:sel_fn loadPreviousState:true async:true] == 0;
            }
        }
        else {
            string dir = cur.parent_path().remove_filename().native();
            string sel_fn = cur.parent_path().filename().native();
            
            if( self.vfs->IsNativeFS() && ![self ensureCanGoToNativeFolderSync:dir] )
                return true; // silently reap this command, since user refuses to grant an access
            return [self GoToDir:dir vfs:self.vfs select_entry:sel_fn loadPreviousState:true async:true] == 0;
        }
    }
    else if( m_UpperDirectory )
        return [self GoToDir:m_UpperDirectory.Path() vfs:m_UpperDirectory.Host() select_entry:"" loadPreviousState:true async:true] == 0;
    return false;
}


- (bool) HandleGoIntoDirOrArchive
{
    const auto entry = m_View.item;
    if( !entry )
        return false;
    
    // Handle directories.
    if(entry.IsDir()) {
        if(entry.IsDotDot())
            return [self HandleGoToUpperDirectory];
        
        if(entry.Host()->IsNativeFS() && ![self ensureCanGoToNativeFolderSync:entry.Path()])
            return true; // silently reap this command, since user refuses to grant an access
        
        return [self GoToDir:entry.Path() vfs:entry.Host() select_entry:"" async:true] == 0;
    }
    // archive stuff here
    else if(configuration::has_archives_browsing) {
        auto arhost = VFSArchiveProxy::OpenFileAsArchive(self.currentFocusedEntryPath,
                                                         self.vfs);
        if(arhost)
            return [self GoToDir:"/" vfs:arhost select_entry:"" async:true] == 0;
    }
    
    return false;
}

- (void) HandleGoIntoDirOrOpenInSystem
{
    if( self.state && [self.state handleReturnKeyWithOverlappedTerminal] )
        return;
    
    if([self HandleGoIntoDirOrArchive])
        return;
    
    auto entry = m_View.item;
    if( !entry )
        return;
    
    // need more sophisticated executable handling here
    if(configuration::has_terminal &&
       !entry.IsDotDot() &&
       entry.Host()->IsNativeFS() &&
       panel::IsEligbleToTryToExecuteInConsole(entry)) {
        [self.state requestTerminalExecution:entry.Name() at:entry.Directory()];
        return;
    }
    
    // If previous code didn't handle current item,
    // open item with the default associated application.
    [self HandleOpenInSystem];
}

- (void) RefreshDirectory
{
    if(m_View == nil) return; // guard agains calls from init process
    
    // going async here
    if(!m_DirectoryLoadingQ->Empty())
        return; //reducing overhead
    
    string dirpath = m_Data.DirectoryPathWithTrailingSlash();
    auto vfs = self.vfs;
    
    m_DirectoryReLoadingQ->Run([=](const SerialQueue &_q){
        shared_ptr<VFSFlexibleListing> listing;
        int ret = vfs->FetchFlexibleListing(dirpath.c_str(), listing, m_VFSFetchingFlags, [&]{ return _q->IsStopped(); });
        if(ret >= 0) {
            dispatch_to_main_queue( [=]{
                panel::GenericCursorPersistance pers(m_View, m_Data);
                
                m_Data.ReLoad(listing);
                [m_View dataUpdated];
                
                if(![self CheckAgainstRequestedSelection])
                    pers.Restore();

                [self OnCursorChanged];
                [self QuickSearchUpdate];
                [m_View setNeedsDisplay];
            });
        }
        else {
            dispatch_to_main_queue( [=]{
                [self RecoverFromInvalidDirectory];
            });
        }
    });
}

- (bool) PanelViewProcessKeyDown:(PanelView*)_view event:(NSEvent *)event
{
    [self ClearSelectionRequest]; // on any key press we clear entry selection request if any
 
    const bool route_to_overlapped_terminal = [NSUserDefaults.standardUserDefaults boolForKey:g_DefaultsGeneralRouteKeyboardInputIntoTerminal];
    const bool terminal_can_eat = route_to_overlapped_terminal && [self.state overlappedTerminalWillEatKeyDown:event];
    
    NSString*  const character   = event.charactersIgnoringModifiers;
    if ( character.length > 0 ) {
        NSUInteger const modif       = event.modifierFlags;
        unichar const unicode        = [character characterAtIndex:0];
        unsigned short const keycode = event.keyCode;
        
        if(keycode == 3 ) { // 'F' button
            if( (modif&NSDeviceIndependentModifierFlagsMask) == (NSControlKeyMask|NSAlternateKeyMask|NSCommandKeyMask)) {
                [self testNonUniformListing];
                return true;
            }
        }
        
        if(unicode == NSTabCharacter) { // Tab button
            [self.state HandleTabButton];
            return true;
        }
        if(unicode == 0x20 &&
           !terminal_can_eat) { // Space button
            [self OnFileViewCommand:self];
            return true;
        }
        if(keycode == 53) { // Esc button
            [self CancelBackgroundOperations];
            [self.state CloseOverlay:self];
            m_BriefSystemOverview = nil;
            m_QuickLook = nil;
            [self QuickSearchClearFiltering];
            return true;
        }
        if( unicode == '~' &&
           (modif & (NSControlKeyMask|NSAlternateKeyMask|NSCommandKeyMask)) == 0 &&
           [NSUserDefaults.standardUserDefaults boolForKey:g_DefaultsGeneraluseTildeAsHomeShortcut] &&
           !terminal_can_eat) { // Tilde to go Home
            static auto tag = ActionsShortcutsManager::Instance().TagFromAction("menu.go.home");
            [[NSApp menu] performActionForItemWithTagHierarchical:tag];
            return true;
        }
        if( unicode == '/' &&
           (modif & (NSShiftKeyMask|NSControlKeyMask|NSAlternateKeyMask|NSCommandKeyMask)) == 0 &&
           !terminal_can_eat) {
            static auto tag = ActionsShortcutsManager::Instance().TagFromAction("menu.go.root");
            [[NSApp menu] performActionForItemWithTagHierarchical:tag];
            return true;
        }
        
        // handle some actions manually, to prevent annoying by menu highlighting by hotkey
        auto &shortcuts = ActionsShortcutsManager::Instance();
        if(shortcuts.ShortCutFromAction("menu.file.open")->IsKeyDown(unicode, keycode, modif)) {
            [self HandleGoIntoDirOrOpenInSystem];
            return true;
        }
        if(shortcuts.ShortCutFromAction("menu.file.open_native")->IsKeyDown(unicode, keycode, modif)) {
            [self HandleOpenInSystem];
            return true;
        }
        
        // try to process this keypress with QuickSearch
        if([self QuickSearchProcessKeyDown:event])
            return true;
        
        if(keycode == 51 && // backspace
           (modif & (NSShiftKeyMask|NSControlKeyMask|NSAlternateKeyMask|NSCommandKeyMask)) == 0 &&
           !terminal_can_eat
           ) { // treat not-processed by QuickSearch backspace as a GoToUpperLevel command
            return [self HandleGoToUpperDirectory];
        }
        
        if( terminal_can_eat && [self.state feedOverlappedTerminalWithKeyDown:event] )
            return true;
    }
    
    return false;
}

- (void) CalculateSizesWithNames:(const vector<string>&) _filenames
{
    function<void(const char*, uint64_t)> complet = [=](const char* _sub_dir, uint64_t _size) {
        string sub_dir = _sub_dir;
        dispatch_to_main_queue([=]{
            panel::GenericCursorPersistance pers(m_View, m_Data);
            // may cause re-sorting if current sorting is by size
            if(m_Data.SetCalculatedSizeForDirectory(sub_dir.c_str(), _size))
            {
                [m_View setNeedsDisplay];
                pers.Restore();
            }
        });
    };
    
    string current_dir = self.currentDirectoryPath;
    m_DirectorySizeCountingQ->Run([=](const SerialQueue &_q){
        self.vfs->CalculateDirectoriesSizes(_filenames,
                                            current_dir.c_str(),
                                            [=]{ return _q->IsStopped(); },
                                            complet);
    });
}

- (void) ModifierFlagsChanged:(unsigned long)_flags // to know if shift or something else is pressed
{
    [m_View ModifierFlagsChanged:_flags];

    if(m_QuickSearchIsSoftFiltering)
        [self QuickSearchClearFiltering];
}

- (void) AttachToControls:(NSProgressIndicator*)_indicator share:(NSButton*)_share
{
    m_SpinningIndicator = _indicator;
    m_ShareButton = _share;
    
    m_IsAnythingWorksInBackground = false;
    [m_SpinningIndicator stopAnimation:nil];
    [self UpdateSpinningIndicator];
    
    m_ShareButton.target = self;
    m_ShareButton.action = @selector(OnShareButton:);
}

- (void) CancelBackgroundOperations
{
    m_DirectorySizeCountingQ->Stop();
    m_DirectoryLoadingQ->Stop();
    m_DirectoryReLoadingQ->Stop();    
}

- (void) UpdateSpinningIndicator
{
    bool is_anything_working = !m_DirectorySizeCountingQ->Empty() || !m_DirectoryLoadingQ->Empty() || !m_DirectoryReLoadingQ->Empty();
    
    if(is_anything_working == m_IsAnythingWorksInBackground)
        return; // nothing to update;
        
    if(is_anything_working)
    {
        dispatch_to_main_queue_after(100ms, [=]{ // in 100 ms of workload should be before user will get spinning indicator
                           if(m_IsAnythingWorksInBackground) // need to check if task was already done
                           {
                               [m_SpinningIndicator startAnimation:nil];
                               if(m_SpinningIndicator.isHidden)
                                   m_SpinningIndicator.hidden = false;
                           }
                       });
    }
    else
    {
        [m_SpinningIndicator stopAnimation:nil];
        if(!m_SpinningIndicator.isHidden)
            m_SpinningIndicator.hidden = true;
        
    }
    
    m_IsAnythingWorksInBackground = is_anything_working;
}

- (void) SelectAllEntries:(bool) _select
{
    m_Data.CustomFlagsSelectAllSorted(_select);
    [m_View setNeedsDisplay];
}

- (void) invertSelection
{
    m_Data.CustomFlagsSelectInvert();
    [m_View setNeedsDisplay];
}

- (void) OnPathChanged
{
    // update directory changes notification ticket
    __weak PanelController *weakself = self;
    m_UpdatesObservationTicket.reset();    
    if( self.isUniform )
        m_UpdatesObservationTicket = self.vfs->DirChangeObserve(self.currentDirectoryPath.c_str(), [=]{
            dispatch_to_main_queue([=]{
                [(PanelController *)weakself RefreshDirectory];
            });
        });
    
    [self ClearSelectionRequest];
    [self QuickSearchClearFiltering];
    [self.state PanelPathChanged:self];
    [self OnCursorChanged];
    [self UpdateBriefSystemOverview];

    if( self.isUniform  ) {
        m_History.Put( VFSPathStack(self.vfs, self.currentDirectoryPath) );
        if( self.vfs->IsNativeFS() )
            m_LastNativeDirectory = self.currentDirectoryPath;
    }
}

- (void) OnCursorChanged
{
    // need to update some UI here  
    // update share button regaring current state
    m_ShareButton.enabled = m_Data.Stats().selected_entries_amount > 0 ||
                            [SharingService SharingEnabledForItem:m_View.item];
    
    // update QuickLook if any
    if( auto i = self.view.item )
        [(QuickLookView *)m_QuickLook PreviewItem:i.Path() vfs:i.Host()];
}

- (void)OnShareButton:(id)sender
{
    if(SharingService.IsCurrentlySharing)
        return;
    
    auto files = self.selectedEntriesOrFocusedEntryFilenames;
    if(files.empty())
        return;
    
    [[SharingService new] ShowItems:files
                              InDir:self.currentDirectoryPath
                              InVFS:self.vfs
                     RelativeToRect:[sender bounds]
                             OfView:sender
                      PreferredEdge:NSMinYEdge];
}

- (void) UpdateBriefSystemOverview
{
    if( auto i = self.view.item )
        [(BriefSystemOverview *)m_BriefSystemOverview UpdateVFSTarget:i.Directory() host:i.Host()];
    else if( self.isUniform )
        [(BriefSystemOverview *)m_BriefSystemOverview UpdateVFSTarget:self.currentDirectoryPath
                                                                 host:self.vfs];
}

- (void) PanelViewCursorChanged:(PanelView*)_view
{
    [self OnCursorChanged];
}

- (NSMenu*) PanelViewRequestsContextMenu:(PanelView*)_view
{
    auto items = self.selectedEntriesOrFocusedEntries;
    if( items.empty() )
        return nil;
    
    return [self.state RequestContextMenuOn:move(items)
                                       path:self.currentDirectoryPath.c_str()
                                        vfs:self.vfs
                                     caller:self];
}

- (void) PanelViewDoubleClick:(PanelView*)_view atElement:(int)_sort_pos
{
    [self HandleGoIntoDirOrOpenInSystem];
}

- (bool) PanelViewWantsRenameFieldEditor:(PanelView*)_view
{
    if( !_view.item ||
       _view.item.IsDotDot() ||
       !self.vfs->IsWriteable())
        return false;
    return true;
}

- (void) PanelViewRenamingFieldEditorFinished:(PanelView*)_view text:(NSString*)_filename
{
    if(_filename == nil ||
       _filename.length == 0 ||
       _filename.fileSystemRepresentation == nullptr ||
       [_filename isEqualToString:@"."] ||
       [_filename isEqualToString:@".."] ||
       !m_View.item ||
       m_View.item.IsDotDot() ||
       [_filename isEqualToString:m_View.item.NSName()])
        return;
    
    string target_fn = _filename.fileSystemRepresentationSafe;
 
    // checking for invalid symbols
    if( !self.vfs->ValidateFilename(target_fn.c_str()) ) {
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = [NSString stringWithFormat:NSLocalizedString(@"The name “%@” can’t be used.", "Message text when user is entering an invalid filename"),
                         _filename.length <= 256 ? _filename : [[_filename substringToIndex:256] stringByAppendingString:@"..."]
                         ];
        a.informativeText = NSLocalizedString(@"Try using a name with fewer characters, or with no punctuation marks.", "Informative text when user is entering an invalid filename");
        a.alertStyle = NSCriticalAlertStyle;
        [a runModal];
        return;
    }
    
    FileCopyOperationOptions opts;
    opts.docopy = false;
    
    FileCopyOperation *op = [FileCopyOperation alloc];
    if(self.vfs->IsNativeFS())
        op = [op initWithFiles:vector<string>( 1, m_View.item.Name() )
                          root:self.currentDirectoryPath.c_str()
                          dest:target_fn.c_str()
                       options:opts];
    else if( self.vfs->IsWriteable() )
        op = [op initWithFiles:vector<string>( 1, m_View.item.Name() )
                          root:self.currentDirectoryPath.c_str()
                        srcvfs:self.vfs
                          dest:target_fn.c_str()
                        dstvfs:self.vfs
                       options:opts];
    else
        return;
    
    string curr_path = self.currentDirectoryPath;
    auto curr_vfs = self.vfs;
    [op AddOnFinishHandler:^{
        if(self.currentDirectoryPath == curr_path && self.vfs == curr_vfs)
            dispatch_to_main_queue( [=]{
                PanelControllerDelayedSelection req;
                req.filename = target_fn;
                [self ScheduleDelayedSelectionChangeFor:req];
                [self RefreshDirectory];
            } );
    }];
    
    [self.state AddOperation:op];
}

- (void) PanelViewDidBecomeFirstResponder:(PanelView*)_view
{
    [self.state activePanelChangedTo:self];
}

- (void) SelectEntriesByMask:(NSString*)_mask select:(bool)_select
{
    if(_mask == nil)
        return;
    bool ignore_dirs = [NSUserDefaults.standardUserDefaults boolForKey:g_DefaultsGeneralIgnoreDirsOnMaskSel];
    if(m_Data.CustomFlagsSelectAllSortedByMask(_mask, _select, ignore_dirs))
        [m_View setNeedsDisplay:true];
}

+ (bool) ensureCanGoToNativeFolderSync:(const string&)_path
{
    if(configuration::is_sandboxed &&
       !SandboxManager::Instance().CanAccessFolder(_path) &&
       !SandboxManager::Instance().AskAccessForPathSync(_path))
        return false;
    return true;
}

- (bool)ensureCanGoToNativeFolderSync:(const string&)_path
{
    return [PanelController ensureCanGoToNativeFolderSync:_path];
}

- (void) testNonUniformListing
{
    shared_ptr<VFSFlexibleListing> l1, l2;
    VFSNativeHost::SharedHost()->FetchFlexibleListing("/users/migun/", l1, 0, 0);
    VFSNativeHost::SharedHost()->FetchFlexibleListing("/users/migun/downloads/", l2, 0, 0);
  
    vector<shared_ptr<VFSFlexibleListing>> original_listings = {l1, l2};
    vector<vector<unsigned>> indeces;
    
    indeces.emplace_back();
    indeces.back().resize(l1->Count());
    generate(begin(indeces.back()), end(indeces.back()), linear_generator(0, 1));
    
    indeces.emplace_back();
    indeces.back().resize(l2->Count()-1);
    generate(begin(indeces.back()), end(indeces.back()), linear_generator(1, 1));

    auto source = VFSFlexibleListing::Compose(original_listings, indeces);
    
    auto new_listing = VFSFlexibleListing::Build(move(source));
    
    [self loadNonUniformListing:new_listing];
}

@end
