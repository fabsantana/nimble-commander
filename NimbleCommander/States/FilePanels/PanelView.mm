#include <NimbleCommander/Bootstrap/AppDelegate.h>
#include <NimbleCommander/Core/ActionsShortcutsManager.h>
#include <Utility/NSEventModifierFlagsHolder.h>
#include "PanelViewLayoutSupport.h"
#include "PanelView.h"
#include "PanelData.h"
#include "PanelController.h"
#include "Brief/PanelBriefView.h"
#include "List/PanelListView.h"
#include "PanelViewHeader.h"
#include "PanelViewFooter.h"
#include "IconsGenerator2.h"
#include "PanelViewDelegate.h"
#include "Actions/Enter.h"
#include "DragReceiver.h"
#include "DragSender.h"
#include "PanelViewFieldEditor.h"

enum class CursorSelectionType : int8_t
{
    No          = 0,
    Selection   = 1,
    Unselection = 2
};

struct PanelViewStateStorage
{
    string focused_item;
};

static size_t HashForPath( const VFSHostPtr &_at_vfs, const string &_path )
{
    string full;
    auto c = _at_vfs;
    while( c ) {
        // we need to incorporate options somehow here. or not?
        string part = string(c->Tag) + string(c->JunctionPath()) + "|";
        full.insert(0, part);
        c = c->Parent();
    }
    full += _path;
    return hash<string>()(full);
}

using namespace nc::panel;

////////////////////////////////////////////////////////////////////////////////

@interface PanelView()

@property (nonatomic, readonly) PanelController *controller;

@end

@implementation PanelView
{
    data::Model                *m_Data;
    
    unordered_map<size_t, PanelViewStateStorage> m_States; // TODO: change no something simplier
    NSString                   *m_HeaderTitle;
    NCPanelViewFieldEditor     *m_RenamingEditor;

    __weak id<PanelViewDelegate> m_Delegate;
    NSView<PanelViewImplementationProtocol> *m_ItemsView;
    PanelViewHeader            *m_HeaderView;
    PanelViewFooter            *m_FooterView;
    
    IconsGenerator2             m_IconsGenerator;
    
    int                         m_CursorPos;
    NSEventModifierFlagsHolder  m_KeyboardModifierFlags;
    CursorSelectionType         m_KeyboardCursorSelectionType;
}

- (id)initWithFrame:(NSRect)frame layout:(const PanelViewLayout&)_layout
{
    self = [super initWithFrame:frame];
    if (self) {
        m_Data = nullptr;
        m_CursorPos = -1;
        m_HeaderTitle = @"";

        m_ItemsView = [self spawnItemViewWithLayout:_layout];
        [self addSubview:m_ItemsView];
        
        m_HeaderView = [[PanelViewHeader alloc] initWithFrame:frame];
        m_HeaderView.translatesAutoresizingMaskIntoConstraints = false;
        __weak PanelView *weak_self = self;
        m_HeaderView.sortModeChangeCallback = [weak_self](data::SortMode _sm){
            if( PanelView *strong_self = weak_self )
                [strong_self.controller changeSortingModeTo:_sm];
        };
        [self addSubview:m_HeaderView];
        
        m_FooterView = [[PanelViewFooter alloc] initWithFrame:NSRect()];
        m_FooterView.translatesAutoresizingMaskIntoConstraints = false;
        [self addSubview:m_FooterView];
        
        NSDictionary *views = NSDictionaryOfVariableBindings(m_ItemsView, m_HeaderView, m_FooterView);
//        [self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|-(==0)-[m_ItemsView]-(==0)-|" options:0 metrics:nil views:views]];
        [self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|-(==0)-[m_HeaderView(==20)]-(==0)-[m_ItemsView]-(==0)-[m_FooterView(==20)]-(==0)-|" options:0 metrics:nil views:views]];
        [self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"|-(0)-[m_HeaderView]-(0)-|" options:0 metrics:nil views:views]];
        [self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"|-(0)-[m_ItemsView]-(0)-|" options:0 metrics:nil views:views]];
        [self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"|-(0)-[m_FooterView]-(0)-|" options:0 metrics:nil views:views]];
    }
    
    return self;
}

- (id)initWithFrame:(NSRect)frame
{
    assert( !"don't call [PanelView initWithFrame:(NSRect)frame]" );
    return nil;
}

- (NSView<PanelViewImplementationProtocol>*) spawnItemViewWithLayout:(const PanelViewLayout&)_layout
{
    if( auto ll = any_cast<PanelListViewColumnsLayout>(&_layout.layout) ) {
        auto v = [self spawnListView];
        v.columnsLayout = *ll;
        return v;
    }
    else if( auto bl = any_cast<PanelBriefViewColumnsLayout>(&_layout.layout) ) {
        auto v = [self spawnBriefView];
        v.columnsLayout = *bl;
        return v;
    }
    return nil;
}

-(void) dealloc
{
    m_Data = nullptr;
}

- (void) setDelegate:(id<PanelViewDelegate>)delegate
{
    m_Delegate = delegate;
    if( auto r = objc_cast<NSResponder>(delegate) ) {
        NSResponder *current = self.nextResponder;
        super.nextResponder = r;
        r.nextResponder = current;
    }
}

- (id<PanelViewDelegate>) delegate
{
    return m_Delegate;
}

- (PanelListView*) spawnListView
{
   PanelListView *v = [[PanelListView alloc] initWithFrame:self.bounds andIC:m_IconsGenerator];
    v.translatesAutoresizingMaskIntoConstraints = false;
    __weak PanelView *weak_self = self;
    v.sortModeChangeCallback = [=](data::SortMode _sm){
        if( PanelView *strong_self = weak_self )
            [strong_self.controller changeSortingModeTo:_sm];
    };
    return v;
}

- (PanelBriefView*) spawnBriefView
{
    auto v = [[PanelBriefView alloc] initWithFrame:self.bounds andIC:m_IconsGenerator];
    v.translatesAutoresizingMaskIntoConstraints = false;
    return v;
}

- (BOOL) isOpaque
{
    return true;
}

- (BOOL)acceptsFirstResponder
{
    return true;
}

- (BOOL)becomeFirstResponder
{
    [self.controller panelViewDidBecomeFirstResponder];
    [self willChangeValueForKey:@"active"];
    [self didChangeValueForKey:@"active"];
    return true;
}

- (BOOL)resignFirstResponder
{
    __weak PanelView* weak_self = self;
    dispatch_to_main_queue([=]{
        if( PanelView* strong_self = weak_self ) {
            [strong_self willChangeValueForKey:@"active"];
            [strong_self didChangeValueForKey:@"active"];
        }
    });
    return YES;
}

- (void)setNextResponder:(NSResponder *)newNextResponder
{
    if( auto r = objc_cast<NSResponder>(self.delegate) ) {
        r.nextResponder = newNextResponder;
        return;
    }
    
    [super setNextResponder:newNextResponder];
}

- (void)viewWillMoveToWindow:(NSWindow *)_wnd
{
    if( self.window ) {
        [NSNotificationCenter.defaultCenter removeObserver:self
                                                      name:NSWindowDidBecomeKeyNotification
                                                    object:nil];
        [NSNotificationCenter.defaultCenter removeObserver:self
                                                      name:NSWindowDidResignKeyNotification
                                                    object:nil];
        [NSNotificationCenter.defaultCenter removeObserver:self
                                                      name:NSWindowDidBecomeMainNotification
                                                    object:nil];
        [NSNotificationCenter.defaultCenter removeObserver:self
                                                      name:NSWindowDidResignMainNotification
                                                    object:nil];
    }
    
    if( _wnd ) {
        m_IconsGenerator.SetHiDPI( _wnd.backingScaleFactor > 1.0 );
    
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(windowStatusDidChange)
                                                   name:NSWindowDidBecomeKeyNotification
                                                 object:_wnd];
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(windowStatusDidChange)
                                                   name:NSWindowDidResignKeyNotification
                                                 object:_wnd];
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(windowStatusDidChange)
                                                   name:NSWindowDidBecomeMainNotification
                                                 object:_wnd];
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(windowStatusDidChange)
                                                   name:NSWindowDidResignMainNotification
                                                 object:_wnd];
    }
}

- (bool) active
{
    if( auto w = self.window )
        if( w.isKeyWindow || w.isMainWindow )
            if( id fr = w.firstResponder )
                return fr == self || [objc_cast<NSView>(fr) isDescendantOf:self];
    return false;
}

- (data::Model*) data
{
    return m_Data;
}

- (void) setData:(data::Model *)data
{
//    self.needsDisplay = true;
    m_Data = data;
    
//    if( data )

    if( data ) {
        [m_ItemsView setData:data];
        m_ItemsView.sortMode = data->SortMode();
        m_HeaderView.sortMode = data->SortMode();
    }
    
    if( !data ) {
        // we're in destruction phase
        
        // !!! this might be dangerous!
        
        [m_ItemsView removeFromSuperview];
        m_ItemsView = nil;
        
        [m_HeaderView removeFromSuperview];
        m_HeaderView = nil;
        
        [m_FooterView removeFromSuperview];
        m_FooterView = nil;
 
//        self.presentation = nullptr;
    }
}

- (void) HandlePrevFile
{
    dispatch_assert_main_queue();
    
    int origpos = m_CursorPos;
    
//    m_Presentation->MoveCursorToPrevItem();
//    if(m_State->Data->SortedDirectoryEntries().empty()) return;
//
    if( m_CursorPos < 0 )
        return;
    
    [self performKeyboardSelection:origpos last_included:origpos];

    if( m_CursorPos == 0 )
        return;
    
    
    m_CursorPos--;
//    EnsureCursorIsVisible();
    
    
//    if(m_CursorSelectionType != CursorSelectionType::No)
    
    
    [self OnCursorPositionChanged];
}

- (void) HandleNextFile
{
    dispatch_assert_main_queue();
    
    int origpos = m_CursorPos;
//    m_Presentation->MoveCursorToNextItem();
    
//    if(m_State->Data->SortedDirectoryEntries().empty()) return;
//
    [self performKeyboardSelection:origpos last_included:origpos];
    if( m_CursorPos + 1 >= m_Data->SortedDirectoryEntries().size() )
        return;

    m_CursorPos++;
    
    
    [self OnCursorPositionChanged];
}

- (void) HandlePrevPage
{
    dispatch_assert_main_queue();
    
    const auto orig_pos = m_CursorPos;

    
    const auto total_items = (int)m_Data->SortedDirectoryEntries().size();
    if( !total_items )
        return;
    
    const auto items_per_screen = m_ItemsView.maxNumberOfVisibleItems;
    const auto new_pos = max( orig_pos - items_per_screen, 0 );
    
    if( new_pos == orig_pos )
        return;
    
    m_CursorPos = new_pos;
    
    [self performKeyboardSelection:orig_pos last_included:m_CursorPos];
    [self OnCursorPositionChanged];
    
}

- (void) HandleNextPage
{
    dispatch_assert_main_queue();
    
    const auto total_items = (int)m_Data->SortedDirectoryEntries().size();
    if( !total_items )
        return;
    const auto orig_pos = m_CursorPos;
    const auto items_per_screen = m_ItemsView.maxNumberOfVisibleItems;
    const auto new_pos = min( orig_pos + items_per_screen, total_items - 1 );
    
    if( new_pos == orig_pos )
        return;
    
    m_CursorPos = new_pos;
    
    [self performKeyboardSelection:orig_pos last_included:m_CursorPos];
    [self OnCursorPositionChanged];
}

- (void) HandlePrevColumn
{
    dispatch_assert_main_queue();
    
    const auto orig_pos = m_CursorPos;
    
    if( m_Data->SortedDirectoryEntries().empty() ) return;
    const auto items_per_column = m_ItemsView.itemsInColumn;
    const auto new_pos = max( orig_pos - items_per_column, 0 );
    
    if( new_pos == orig_pos )
        return;

    m_CursorPos = new_pos;
    
    [self performKeyboardSelection:orig_pos last_included:m_CursorPos];
    [self OnCursorPositionChanged];
}

- (void) HandleNextColumn
{
    dispatch_assert_main_queue();
    
    const auto orig_pos = m_CursorPos;
//    m_Presentation->MoveCursorToNextColumn();
    
    if( m_Data->SortedDirectoryEntries().empty() ) return;
    const auto total_items = (int)m_Data->SortedDirectoryEntries().size();
    const auto items_per_column = m_ItemsView.itemsInColumn;
    const auto new_pos = min( orig_pos + items_per_column, total_items - 1 );
    
    if( new_pos == orig_pos )
        return;
    
    m_CursorPos = new_pos;

    [self performKeyboardSelection:orig_pos last_included:m_CursorPos];
    [self OnCursorPositionChanged];
}

- (void) HandleFirstFile;
{
    dispatch_assert_main_queue();
    
    const auto origpos = m_CursorPos;
    
    if( m_Data->SortedDirectoryEntries().empty() ||
        m_CursorPos == 0 )
        return;
    
    m_CursorPos = 0;
    
//    m_Presentation->MoveCursorToFirstItem();

    [self performKeyboardSelection:origpos last_included:m_CursorPos];
    [self OnCursorPositionChanged];
}

- (void) HandleLastFile;
{
    dispatch_assert_main_queue();
    
    const auto origpos = m_CursorPos;
    
    if( m_Data->SortedDirectoryEntries().empty() ||
        m_CursorPos == m_Data->SortedDirectoryEntries().size() - 1 )
        return;
    
    m_CursorPos = (int)m_Data->SortedDirectoryEntries().size() - 1;
    
//    m_Presentation->MoveCursorToLastItem();

    [self performKeyboardSelection:origpos last_included: m_CursorPos];
    [self OnCursorPositionChanged];
}

- (void) onInvertCurrentItemSelectionAndMoveNext
{
    dispatch_assert_main_queue();
    
    const auto origpos = m_CursorPos;
    
    if(auto entry = m_Data->EntryAtSortPosition(origpos))
        [self SelectUnselectInRange:origpos
                      last_included:origpos
                             select:!m_Data->VolatileDataAtSortPosition(origpos).is_selected()];

    if( m_CursorPos + 1 < m_Data->SortedDirectoryEntries().size() ) {
        m_CursorPos++;
        [self OnCursorPositionChanged];
    }
    
}

- (void) onInvertCurrentItemSelection
{
    dispatch_assert_main_queue();
    
    int pos = m_CursorPos;
    if( auto entry = m_Data->EntryAtSortPosition(pos) )
        [self SelectUnselectInRange:pos
                      last_included:pos
                             select:!m_Data->VolatileDataAtSortPosition(pos).is_selected()];
}

- (void) setCurpos:(int)_pos
{
    dispatch_assert_main_queue();
    
    const auto clipped_pos = (m_Data->SortedDirectoryEntries().size() > 0 &&
                         _pos >= 0 &&
                         _pos < m_Data->SortedDirectoryEntries().size() ) ?
                        _pos : -1;
    
    if (m_CursorPos == clipped_pos)
        return;
    
    m_CursorPos = clipped_pos;
    
    [self OnCursorPositionChanged];
}

- (int) curpos
{
    dispatch_assert_main_queue();
    return m_CursorPos;
}

- (void) OnCursorPositionChanged
{
    dispatch_assert_main_queue();
    [m_ItemsView setCursorPosition:m_CursorPos];
    [m_FooterView updateFocusedItem:self.item VD:self.item_vd];
    
    if(id<PanelViewDelegate> del = self.delegate)
        if([del respondsToSelector:@selector(PanelViewCursorChanged:)])
            [del PanelViewCursorChanged:self];
    
//    m_LastPotentialRenamingLBDown = -1;
    [self commitFieldEditor];
}

- (void)keyDown:(NSEvent *)event
{
    if(id<PanelViewDelegate> del = self.delegate)
        if([del respondsToSelector:@selector(PanelViewProcessKeyDown:event:)])
            if([del PanelViewProcessKeyDown:self event:event])
                return;
    
    NSString* character = [event charactersIgnoringModifiers];
    if ( character.length != 1 ) {
        [super keyDown:event];
        return;
    }
    
    const auto modifiers    = event.modifierFlags;
    const auto unicode      = [character characterAtIndex:0];
    const auto keycode      = event.keyCode;
    
    [self checkKeyboardModifierFlags:modifiers];
    
    static ActionsShortcutsManager::ShortCut hk_up, hk_down, hk_left, hk_right, hk_first, hk_last,
    hk_pgdown, hk_pgup, hk_inv_and_move, hk_inv, hk_scrdown, hk_scrup, hk_scrhome, hk_scrend;
    static ActionsShortcutsManager::ShortCutsUpdater hotkeys_updater(
       {&hk_up, &hk_down, &hk_left, &hk_right, &hk_first, &hk_last, &hk_pgdown, &hk_pgup,
           &hk_inv_and_move, &hk_inv, &hk_scrdown, &hk_scrup, &hk_scrhome, &hk_scrend},
       {"panel.move_up", "panel.move_down", "panel.move_left", "panel.move_right", "panel.move_first",
           "panel.move_last", "panel.move_next_page", "panel.move_prev_page",
           "panel.move_next_and_invert_selection", "panel.invert_item_selection",
           "panel.scroll_next_page", "panel.scroll_prev_page", "panel.scroll_first", "panel.scroll_last"
       }
      );

    if( hk_up.IsKeyDown(unicode, keycode, modifiers & ~NSShiftKeyMask) )
        [self HandlePrevFile];
    else if( hk_down.IsKeyDown(unicode, keycode, modifiers & ~NSShiftKeyMask) )
        [self HandleNextFile];
    else if( hk_left.IsKeyDown(unicode, keycode, modifiers & ~NSShiftKeyMask) )
        [self HandlePrevColumn];
    else if( hk_right.IsKeyDown(unicode, keycode, modifiers & ~NSShiftKeyMask) )
        [self HandleNextColumn];
    else if( hk_first.IsKeyDown(unicode, keycode, modifiers & ~NSShiftKeyMask) )
        [self HandleFirstFile];
    else if( hk_last.IsKeyDown(unicode, keycode, modifiers & ~NSShiftKeyMask) )
        [self HandleLastFile];
    else if( hk_pgdown.IsKeyDown(unicode, keycode, modifiers & ~NSShiftKeyMask) )
        [self HandleNextPage];
    else if( hk_scrdown.IsKeyDown(unicode, keycode, modifiers) )
        [m_ItemsView onPageDown:event];
    else if( hk_pgup.IsKeyDown(unicode, keycode, modifiers & ~NSShiftKeyMask) )
        [self HandlePrevPage];
    else if( hk_scrup.IsKeyDown(unicode, keycode, modifiers) )
        [m_ItemsView onPageUp:event];
    else if( hk_scrhome.IsKeyDown(unicode, keycode, modifiers) )
        [m_ItemsView onScrollToBeginning:event];
    else if( hk_scrend.IsKeyDown(unicode, keycode, modifiers) )
        [m_ItemsView onScrollToEnd:event];
    else if( hk_inv_and_move.IsKeyDown(unicode, keycode, modifiers) )
        [self onInvertCurrentItemSelectionAndMoveNext];
    else if( hk_inv.IsKeyDown(unicode, keycode, modifiers) )
        [self onInvertCurrentItemSelection];
    else
        [super keyDown:event];
}

- (void) checkKeyboardModifierFlags:(unsigned long)_current_flags
{
    if( _current_flags == m_KeyboardModifierFlags )
        return; // we're ok

    // flags have changed, need to update selection logic
    m_KeyboardModifierFlags = _current_flags;
    
    if( !m_KeyboardModifierFlags.is_shift() ) {
        // clear selection type when user releases SHIFT button
        m_KeyboardCursorSelectionType = CursorSelectionType::No;
    }
    else if( m_KeyboardCursorSelectionType == CursorSelectionType::No ) {
        // lets decide if we need to select or unselect files when user will use navigation arrows
        if( auto item = self.item ) {
            if( !item.IsDotDot() ) { // regular case
                m_KeyboardCursorSelectionType = self.item_vd.is_selected() ? CursorSelectionType::Unselection : CursorSelectionType::Selection;
            }
            else {
                // need to look at a first file (next to dotdot) for current representation if any.
                if( auto next_item = m_Data->EntryAtSortPosition(1) )
                    m_KeyboardCursorSelectionType = m_Data->VolatileDataAtSortPosition(1).is_selected() ? CursorSelectionType::Unselection : CursorSelectionType::Selection;
                else // singular case - selection doesn't matter - nothing to select
                    m_KeyboardCursorSelectionType = CursorSelectionType::Selection;
            }
        }
    }
}

- (void)flagsChanged:(NSEvent *)event
{
    [self checkKeyboardModifierFlags:event.modifierFlags];
    [super flagsChanged:event];
}

- (NSMenu *)panelItem:(int)_sorted_index menuForForEvent:(NSEvent*)_event
{
    if( _sorted_index >= 0 )
        return [self.delegate panelView:self requestsContextMenuForItemNo:_sorted_index];    
    return nil;
}

- (VFSListingItem)item
{
    return m_Data->EntryAtSortPosition(m_CursorPos);
}

- (const data::ItemVolatileData&)item_vd
{
    assert( dispatch_is_main_queue() );
    static const data::ItemVolatileData stub{};
    int indx = m_Data->RawIndexForSortIndex( m_CursorPos );
    if( indx < 0 )
        return stub;
    return m_Data->VolatileDataAtRawPosition(indx);
}

- (void) SelectUnselectInRange:(int)_start last_included:(int)_end select:(BOOL)_select
{
    assert( dispatch_is_main_queue() );
    if(_start < 0 || _start >= m_Data->SortedDirectoryEntries().size() ||
         _end < 0 || _end >= m_Data->SortedDirectoryEntries().size() ) {
        NSLog(@"SelectUnselectInRange - invalid range");
        return;
    }
    
    if(_start > _end)
        swap(_start, _end);
    
    // we never want to select a first (dotdot) entry
    if( auto i = m_Data->EntryAtSortPosition(_start) )
        if( i.IsDotDot() )
            ++_start; // we don't want to select or unselect a dotdot entry - they are higher than that stuff
    
    for(int i = _start; i <= _end; ++i)
        m_Data->CustomFlagsSelectSorted(i, _select);
    
//    [m_ItemsView syncVolatileData];
    [self volatileDataChanged];
}

- (void)performKeyboardSelection:(int)_start last_included:(int)_end
{
    assert( dispatch_is_main_queue() );
    if( m_KeyboardCursorSelectionType == CursorSelectionType::No )
        return;
    [self SelectUnselectInRange:_start
                  last_included:_end
                         select:m_KeyboardCursorSelectionType == CursorSelectionType::Selection];
}

- (void) setupBriefPresentationWithLayout:(PanelBriefViewColumnsLayout)_layout
{
    const auto init = !objc_cast<PanelBriefView>(m_ItemsView);
    if( init ) {
        auto v = [self spawnBriefView];
        //v.translatesAutoresizingMaskIntoConstraints = false;
        //    [self addSubview:m_ItemsView];
        
        [self replaceSubview:m_ItemsView with:v];
        m_ItemsView = v;
        
        NSDictionary *views = NSDictionaryOfVariableBindings(m_ItemsView, m_HeaderView, m_FooterView);
        [self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:[m_HeaderView]-(==0)-[m_ItemsView]-(==0)-[m_FooterView]" options:0 metrics:nil views:views]];
        [self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"|-(0)-[m_ItemsView]-(0)-|" options:0 metrics:nil views:views]];
        [self layout];
        
        if( m_Data ) {
            m_ItemsView.data = m_Data;
            m_ItemsView.sortMode = m_Data->SortMode();
        }
        
        if( m_CursorPos >= 0 )
            [m_ItemsView setCursorPosition:m_CursorPos];
    }

    if( auto v = objc_cast<PanelBriefView>(m_ItemsView) ) {
        [v setColumnsLayout:_layout];
    }
}

- (void) setupListPresentationWithLayout:(PanelListViewColumnsLayout)_layout
{
    const auto init = !objc_cast<PanelListView>(m_ItemsView);
    
    if( init ) {
        auto v = [self spawnListView];
        //v.translatesAutoresizingMaskIntoConstraints = false;
        
        [self replaceSubview:m_ItemsView with:v];
        m_ItemsView = v;
        
//        NSDictionary *views = NSDictionaryOfVariableBindings(m_ItemsView, m_HeaderView, m_FooterView);
        //        [self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|-(==0)-[m_ItemsView]-(==0)-|" options:0 metrics:nil views:views]];
//        [self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|-(==0)-[m_HeaderView(==20)]-(==0)-[m_ItemsView]-(==0)-[m_FooterView(==20)]-(==0)-|" options:0 metrics:nil views:views]];
        
        
        NSDictionary *views = NSDictionaryOfVariableBindings(m_ItemsView, m_HeaderView, m_FooterView);
        [self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:[m_HeaderView]-(==0)-[m_ItemsView]-(==0)-[m_FooterView]" options:0 metrics:nil views:views]];
        [self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"|-(0)-[m_ItemsView]-(0)-|" options:0 metrics:nil views:views]];
        [self layout];
        
        if( m_Data ) {
            m_ItemsView.data = m_Data;
            m_ItemsView.sortMode = m_Data->SortMode();
        }
        
        if( m_CursorPos >= 0 )
            [m_ItemsView setCursorPosition:m_CursorPos];
    }
    
    if( auto v = objc_cast<PanelListView>(m_ItemsView) ) {
        [v setColumnsLayout:_layout];
    }
}

- (any) presentationLayout
{
    if( auto v = objc_cast<PanelBriefView>(m_ItemsView) )
        return any{[v columnsLayout]};
    if( auto v = objc_cast<PanelListView>(m_ItemsView) )
        return any{[v columnsLayout]};
    return any{PanelViewDisabledLayout{}};
}

- (void) setPresentationLayout:(const PanelViewLayout&)_layout
{
    if( auto ll = any_cast<PanelListViewColumnsLayout>(&_layout.layout) ) {
        [self setupListPresentationWithLayout:*ll];
    }
    else if( auto bl = any_cast<PanelBriefViewColumnsLayout>(&_layout.layout) ) {
        [self setupBriefPresentationWithLayout:*bl];
        
    }
}

- (void) SavePathState
{
    assert( dispatch_is_main_queue() );
    if(!m_Data || !m_Data->Listing().IsUniform())
        return;
    
    auto &listing = m_Data->Listing();
    
    auto item = self.item;
    if( !item )
        return;
    
    auto &storage = m_States[ HashForPath(listing.Host(), listing.Directory()) ];
    
    storage.focused_item = item.Name();
}

- (void) LoadPathState
{
    assert( dispatch_is_main_queue() );
    if( !m_Data || !m_Data->Listing().IsUniform() )
        return;
    
    auto &listing = m_Data->Listing();
    
    auto it = m_States.find(HashForPath(listing.Host(), listing.Directory()));
    if(it == end(m_States))
        return;
    
    auto &storage = it->second;
    int cursor = m_Data->SortedIndexForName(storage.focused_item.c_str());
    if( cursor < 0 )
        return;
    
    [self setCurpos:cursor];
    [self OnCursorPositionChanged];
}

- (void)panelChangedWithFocusedFilename:(const string&)_focused_filename loadPreviousState:(bool)_load
{
    assert( dispatch_is_main_queue() );
//    m_State.ItemsDisplayOffset = 0;
    m_CursorPos = -1;
    
    if( _load )
        [self LoadPathState];
    
    const int cur = m_Data->SortedIndexForName(_focused_filename.c_str());
    if( cur >= 0 ) {
        //m_Presentation->SetCursorPos(cur);
        [self setCurpos:cur];
//        [self OnCursorPositionChanged];
    }
    
    if( m_CursorPos < 0 &&
        m_Data->SortedDirectoryEntries().size() > 0) {
//        m_Presentation->SetCursorPos(0);
        [self setCurpos:0];
//        [self OnCursorPositionChanged];
    }
    
    [self discardFieldEditor];
    [self setHeaderTitle:self.headerTitleForPanel];
//    m_Presentation->OnDirectoryChanged();
}

- (void)startFieldEditorRenaming
{
    if( m_RenamingEditor != nil ) {
        // if renaming editor is already here - just iterate a selection.
        // (assuming consequent ctrl+f6 hits here)    
        [m_RenamingEditor markNextFilenamePart];
        return;
    }
    
    const int cursor_pos = m_CursorPos;
    if( ![m_ItemsView isItemVisible:cursor_pos] )
        return;

    const auto item = self.item;
    if( !item || item.IsDotDot() || !item.Host()->IsWritable() )
        return;
  
    m_RenamingEditor = [[NCPanelViewFieldEditor alloc] initWithFilename:item.Filename()];
    __weak PanelView *weak_self = self;
    m_RenamingEditor.onTextEntered = ^(const string &_new_filename){
        if( auto sself = weak_self ) {
            if( !sself->m_RenamingEditor ||
                !sself.item ||
                sself.item.Name() != sself->m_RenamingEditor.originalFilename )
                return;
            [sself.delegate PanelViewRenamingFieldEditorFinished:sself
                                                            text:_new_filename];
        }
    };
    m_RenamingEditor.onEditingFinished = ^{
        if( auto sself = weak_self ) {
            [sself->m_RenamingEditor removeFromSuperview];
            sself->m_RenamingEditor = nil;
            
            if( sself.window.firstResponder == nil || sself.window.firstResponder == sself.window )
                dispatch_to_main_queue([=]{
                    [sself.window makeFirstResponder:sself];
                });
        }
    };

    [m_ItemsView setupFieldEditor:m_RenamingEditor forItemAtIndex:cursor_pos];
    [self.window makeFirstResponder:m_RenamingEditor];
}

- (void)commitFieldEditor
{
    if( m_RenamingEditor ) {
        [self.window makeFirstResponder:self];
        [m_RenamingEditor removeFromSuperview];
        m_RenamingEditor = nil;
    }
}

- (void)discardFieldEditor
{
    if( m_RenamingEditor ) {
        m_RenamingEditor.onTextEntered = nil;
        [self.window makeFirstResponder:self];
        [m_RenamingEditor removeFromSuperview];
        m_RenamingEditor = nil;
    }
}

- (void) dataUpdated
{
    assert( dispatch_is_main_queue() );
    if( m_RenamingEditor )
        if( !self.item || m_RenamingEditor.originalFilename != self.item.Name() )
            [self discardFieldEditor];
    
    [m_ItemsView dataChanged];
    [m_ItemsView setCursorPosition:m_CursorPos];
    
    [self volatileDataChanged];
    [m_FooterView updateListing:m_Data->ListingPtr()];
}

- (void) volatileDataChanged
{
    [m_ItemsView syncVolatileData];
    [m_FooterView updateFocusedItem:self.item VD:self.item_vd];
    [m_FooterView updateStatistics:m_Data->Stats()];
}

- (void) setQuickSearchPrompt:(NSString*)_text withMatchesCount:(int)_count
{
//    [self setHeaderTitle:_text != nil ? _text : self.headerTitleForPanel];
//    [self setNeedsDisplay];
    m_HeaderView.searchPrompt = _text;
    m_HeaderView.searchMatches = _count;
    
}

- (int) sortedItemPosAtPoint:(NSPoint)_window_point hitTestOption:(PanelViewHitTest::Options)_options;
{
    
    assert(dispatch_is_main_queue());
    auto pos = [m_ItemsView sortedItemPosAtPoint:_window_point hitTestOption:_options];
    return pos;
}

- (void) windowStatusDidChange
{
    [self willChangeValueForKey:@"active"];
    [self didChangeValueForKey:@"active"];
}

- (void) setHeaderTitle:(NSString *)headerTitle
{
    dispatch_assert_main_queue();
    if( m_HeaderTitle != headerTitle ) {
        m_HeaderTitle = headerTitle;
//        if( m_Presentation )
//            m_Presentation->OnPanelTitleChanged();
        [m_HeaderView setPath:m_HeaderTitle];        
    }
}

- (NSString *) headerTitle
{
    return m_HeaderTitle;
}

- (NSString *) headerTitleForPanel
{
    auto title = [&]{
        switch( m_Data->Type() ) {
            case data::Model::PanelType::Directory:
                return [NSString stringWithUTF8StdString:m_Data->VerboseDirectoryFullPath()];
            case data::Model::PanelType::Temporary:
                return @"Temporary Panel"; // TODO: localize
            default:
                return @"";
        }}();
    return title ? title : @"";
}

- (void)panelItem:(int)_sorted_index mouseDown:(NSEvent*)_event
{
    // any cursor movements or selection changes should be performed only in active window
    const bool window_focused = self.window.isKeyWindow;
    if( window_focused ) {
        if( !self.active )
            [self.window makeFirstResponder:self];
        
        if( !m_Data->IsValidSortPosition(_sorted_index) )
            return;

        const int current_cursor_pos = m_CursorPos;
        const auto click_entry_vd = m_Data->VolatileDataAtSortPosition(_sorted_index);
        const auto modifier_flags = _event.modifierFlags & NSDeviceIndependentModifierFlagsMask;
    
        // Select range of items with shift+click.
        // If clicked item is selected, then deselect the range instead.
        if( modifier_flags & NSShiftKeyMask )
            [self SelectUnselectInRange:current_cursor_pos >= 0 ? current_cursor_pos : 0
                          last_included:_sorted_index
                                 select:!click_entry_vd.is_selected()];
        else if( modifier_flags & NSCommandKeyMask ) // Select or deselect a single item with cmd+click.
            [self SelectUnselectInRange:_sorted_index
                          last_included:_sorted_index
                                 select:!click_entry_vd.is_selected()];
        
        [self setCurpos:_sorted_index];        
    }
}

- (void)panelItem:(int)_sorted_index fieldEditor:(NSEvent*)_event
{
    if( _sorted_index >= 0 && _sorted_index == m_CursorPos )
        [self startFieldEditorRenaming];
}

- (void)panelItem:(int)_sorted_index dblClick:(NSEvent*)_event
{
    if( _sorted_index >= 0 && _sorted_index == m_CursorPos )
        actions::Enter{}.Perform(self.controller, self);
}

- (void)panelItem:(int)_sorted_index mouseDragged:(NSEvent*)_event
{
    DragSender sender{self.controller};
    sender.SetIconCallback([self](int _item_index) -> NSImage* {
        if( const auto entry = m_Data->EntryAtSortPosition(_item_index) ) {
            const auto vd = m_Data->VolatileDataAtSortPosition(_item_index);            
            return m_IconsGenerator.AvailbleImageFor(entry, vd).copy;
        }
        return nil;
    });
    
    sender.Start(self, _event, _sorted_index);
}

- (void) dataSortingHasChanged
{
    m_HeaderView.sortMode = m_Data->SortMode();
    m_ItemsView.sortMode = m_Data->SortMode();
}

- (PanelController*)controller
{
    return objc_cast<PanelController>(m_Delegate);
}

- (int) headerBarHeight
{
    return 20;
}

+ (NSArray*) acceptedDragAndDropTypes
{
    return DragReceiver::AcceptedUTIs();
}

- (NSDragOperation)panelItem:(int)_sorted_index operationForDragging:(id <NSDraggingInfo>)_dragging
{
    return DragReceiver{self.controller, _dragging, _sorted_index}.Validate();
}

- (bool)panelItem:(int)_sorted_index performDragOperation:(id<NSDraggingInfo>)_dragging
{
    return DragReceiver{self.controller, _dragging, _sorted_index}.Receive();
}

- (NSPopover*)showPopoverUnderPathBarWithView:(NSViewController*)_view
                                  andDelegate:(id<NSPopoverDelegate>)_delegate
{
    const auto bounds = self.bounds;
    NSPopover *popover = [NSPopover new];
    popover.contentViewController = _view;
    popover.behavior = NSPopoverBehaviorTransient;
    popover.delegate = _delegate;
    [popover showRelativeToRect:NSMakeRect(0,
                                           bounds.size.height - self.headerBarHeight,
                                           bounds.size.width,
                                           bounds.size.height)
                         ofView:self
                  preferredEdge:NSMinYEdge];
    return popover;
}

- (NSProgressIndicator *)busyIndicator
{
    return m_HeaderView.busyIndicator;
}

- (void)notifyAboutPresentationLayoutChange
{
    [self.controller panelViewDidChangePresentationLayout];
}

@end
