//
//  PanelController.h
//  Directories
//
//  Created by Michael G. Kazakov on 22.02.13.
//  Copyright (c) 2013 Michael G. Kazakov. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "PanelData.h"
#import "PanelView.h"
#import "PanelHistory.h"
#import "DispatchQueue.h"

@class QuickLookView;
@class BriefSystemOverview;
@class MainWindowFilePanelState;
@class MainWindowController;

struct PanelQuickSearchMode
{
    enum KeyModif { // persistancy-bound values, don't change it
        WithAlt         = 0,
        WithCtrlAlt     = 1,
        WithShiftAlt    = 2,
        WithoutModif    = 3,
        Disabled        = 4
    };
    
    static KeyModif KeyModifFromInt(int _k)
    {
        if(_k >= 0 && _k <= Disabled)
            return (KeyModif)_k;
        return WithAlt;
    }
    
};

namespace panel
{
    class GenericCursorPersistance
    {
    public:
        GenericCursorPersistance(PanelView* _view, const PanelData &_data);
        void Restore() const;
        
    private:
        PanelView                  *m_View;
        const PanelData            &m_Data;
        string                      m_OldCursorName;
        PanelData::EntrySortKeys    m_OldEntrySortKeys;
    };
}

@interface PanelController : NSResponder<PanelViewDelegate>
{
    // Main controller's possessions
    PanelData                   m_Data;   // owns
    PanelView                   *m_View;  // create and owns
    
    // Handmade upper directory for non-uniform listings like search results
    VFSPath                     m_UpperDirectory;
    
    // VFS changes observation
    VFSHostDirObservationTicket  m_UpdatesObservationTicket;
    
    // VFS listing fetch flags
    int                         m_VFSFetchingFlags;
    
    // Quick searching section
    bool                                m_QuickSearchIsSoftFiltering;
    bool                                m_QuickSearchTypingView;
    PanelQuickSearchMode::KeyModif      m_QuickSearchMode;
    PanelDataTextFiltering::WhereEnum   m_QuickSearchWhere;
    nanoseconds                         m_QuickSearchLastType;
    unsigned                            m_QuickSearchOffset;
    
    // background operations' queues
    SerialQueue m_DirectorySizeCountingQ;
    SerialQueue m_DirectoryLoadingQ;
    SerialQueue m_DirectoryReLoadingQ;
    
    // navigation support
    PanelHistory m_History;
    
    // spinning indicator support
    bool                m_IsAnythingWorksInBackground;
    NSProgressIndicator *m_SpinningIndicator;
    
    // QuickLook support
    __weak QuickLookView *m_QuickLook;
    
    // BriefSystemOverview support
    __weak BriefSystemOverview* m_BriefSystemOverview;
    
    // drag & drop support, caching
    struct {
        int                 last_valid_items;
    } m_DragDrop;
    
    NSButton            *m_ShareButton;
    
    string              m_LastNativeDirectory;
    
    // delayed entry selection support
    struct
    {
        /**
         * Requested item name to select. Empty filename means that request is invalid.
         */
        string      filename;
        
        /**
         * Time after which request is meaningless and should be removed
         */
        nanoseconds    request_end;

        /**
         * Called when changed a cursor position
         */
        function<void()> done;
    } m_DelayedSelection;
    
    NSPopover            *m_SelectionWithMaskPopover;
    
    __weak MainWindowFilePanelState* m_FilePanelState;
}

@property (nonatomic) MainWindowFilePanelState* state;
@property (nonatomic, readonly) MainWindowController* mainWindowController;
@property (nonatomic, readonly) PanelView* view;
@property (nonatomic, readonly) PanelData& data;
@property (nonatomic, readonly) bool isActive;
@property (nonatomic, readonly) bool isUniform; // return true if panel's listing has common vfs host and directory for it's items
@property (nonatomic, readonly) NSWindow* window;
@property (nonatomic) NSDictionary* options;
@property (nonatomic, readonly) const string& lastNativeDirectoryPath;

- (void) AttachToControls:(NSProgressIndicator*)_indicator
                    share:(NSButton*)_share;
- (void) RefreshDirectory; // user pressed cmd+r by default
- (void) ModifierFlagsChanged:(unsigned long)_flags; // to know if shift or something else is pressed

@end

// internal stuff, move it somewehere else
@interface PanelController ()
- (void) CancelBackgroundOperations;
- (void) OnPathChanged;
- (void) OnCursorChanged;
- (void) HandleOpenInSystem;
- (bool) HandleGoToUpperDirectory;
- (bool) HandleGoIntoDirOrArchive;
- (void) HandleGoIntoDirOrOpenInSystem;
- (void) SelectEntriesByMask:(NSString*)_mask select:(bool)_select;
- (void) SelectAllEntries:(bool) _select;
- (void) invertSelection;
- (void) UpdateBriefSystemOverview;
- (void) CalculateSizesWithNames:(const vector<string>&) _filenames;
- (void) ChangeSortingModeTo:(PanelSortMode)_mode;
- (void) ChangeHardFilteringTo:(PanelDataHardFiltering)_filter;
- (void) MakeSortWith:(PanelSortMode::Mode)_direct Rev:(PanelSortMode::Mode)_rev;
+ (bool) ensureCanGoToNativeFolderSync:(const string&)_path;
- (bool) ensureCanGoToNativeFolderSync:(const string&)_path; // checks only stuff related to sandbox model, not posix perms/acls.
@end

#import "PanelController+DataAccess.h"
#import "PanelController+DelayedSelection.h"
#import "PanelController+Navigation.h"
#import "PanelController+QuickSearch.h"
#import "PanelController+DragAndDrop.h"
#import "PanelController+Menu.h"
#import "PanelController+NavigationMenu.h"
