#include "RecentlyClosedMenuDelegate.h"
#include "../ListingPromise.h"
#include "LocationFormatter.h"
#include "../PanelController.h"
#include "../PanelHistory.h"
#include "../MainWindowFilePanelState.h"
#include <NimbleCommander/Core/AnyHolder.h>

using namespace nc::panel;

@implementation NCPanelsRecentlyClosedMenuDelegate
{
    NSMenu *m_Menu;
    NSMenuItem *m_RestoreLast;
    shared_ptr<nc::panel::ClosedPanelsHistory> m_Storage;
    function<MainWindowFilePanelState*()> m_Locator;
    
}

- (instancetype) initWithMenu:(NSMenu*)_menu
                      storage:(shared_ptr<nc::panel::ClosedPanelsHistory>)_storage
                panelsLocator:(function<MainWindowFilePanelState*()>)_locator
{
    assert( _menu );
    assert( _storage );
    assert( _locator );
    if( self = [super init] ) {
        m_Menu = _menu;
        m_Menu.delegate = self;
        
        m_Storage = move(_storage);
        m_Locator = move(_locator);
        m_RestoreLast = [_menu itemAtIndex:0];
        m_RestoreLast.target = self;
        m_RestoreLast.action = @selector(restoreLastClosed:);
    }
    return self;
}

- (BOOL)menuHasKeyEquivalent:(NSMenu*)menu
                    forEvent:(NSEvent*)event
                      target:(__nullable id* _Nullable)target
                      action:(__nullable SEL* _Nullable)action
{
    if( m_RestoreLast.keyEquivalentModifierMask == event.modifierFlags &&
        [m_RestoreLast.keyEquivalent isEqualToString:event.charactersIgnoringModifiers] ) {
        *target = m_RestoreLast.target;
        *action = m_RestoreLast.action;
    }
    return false;
}

static NSString *ShrinkTitleForRecentlyClosedMenu(NSString *_title)
{
    static const auto text_font = [NSFont menuFontOfSize:13];
    static const auto text_attributes = @{NSFontAttributeName:text_font};
    static const auto max_width = 450;
    return StringByTruncatingToWidth(_title, max_width, kTruncateAtMiddle, text_attributes);
}

- (NSMenuItem*)buildMenuItem:(const ListingPromise &)_listing_promise
{
    const auto options = (loc_fmt::Formatter::RenderOptions)
        (loc_fmt::Formatter::RenderMenuTitle | loc_fmt::Formatter::RenderMenuTooltip);
    const auto rep = loc_fmt::ListingPromiseFormatter{}.Render(options, _listing_promise);
    
    NSMenuItem *item = [[NSMenuItem alloc] init];
    item.title = ShrinkTitleForRecentlyClosedMenu(rep.menu_title);
    item.toolTip = rep.menu_tooltip;
    return item;
}

static vector<ListingPromise> Filter(vector<ListingPromise> _input,
                                     MainWindowFilePanelState *_state)
{
    if( !_state )
        return _input;
    
    auto remove_if_present = [&]( PanelController *_pc ) {
        if( auto current = _pc.history.MostRecent() )
            if( auto it = find( begin(_input), end(_input), *current ); it != end(_input) )
                _input.erase(it);
    };
    
    for( auto &pc: _state.leftControllers ) remove_if_present(pc);
    for( auto &pc: _state.rightControllers ) remove_if_present(pc);
    
    return _input;
}

static RestoreClosedTabRequest::Side CurrentSide(MainWindowFilePanelState *_state)
{
    if( !_state )
        return RestoreClosedTabRequest::Side::Left;
    
    if( _state.activePanelController == _state.rightPanelController )
        return RestoreClosedTabRequest::Side::Right;
    else
        return RestoreClosedTabRequest::Side::Left;
}

- (void)purgeMenu
{
    while( m_Menu.numberOfItems > 2 )
        [m_Menu removeItemAtIndex:m_Menu.numberOfItems - 1];
}

- (void)menuNeedsUpdate:(NSMenu*)menu
{
    auto current_state = m_Locator();
    auto side = CurrentSide(current_state);
    
    auto records = Filter(m_Storage->FrontElements(m_Storage->Size()), current_state);
    
    [self purgeMenu];
    
    for( auto &listing_promise: records ) {
        auto item = [self buildMenuItem:listing_promise];
        if( current_state ) {
            item.target = current_state;
            item.action = @selector(respawnRecentlyClosedCallout:);
            item.representedObject = [[AnyHolder alloc] initWithAny:any{
                RestoreClosedTabRequest(side, listing_promise)
            }];
        }
        
        [menu addItem:item];
    }
}

- (void)menuDidClose:(NSMenu *)menu
{
    [self purgeMenu];
}

- (void)restoreLastClosed:(id)_sender
{
    auto current_state = m_Locator();
    if( !current_state ) {
        NSBeep();
        return;
    }
    
    auto records = Filter(m_Storage->FrontElements(m_Storage->Size()), current_state);
    if( records.empty() ) {
        NSBeep();
        return;
    }
    
    auto payload = [[AnyHolder alloc] initWithAny:any{
        RestoreClosedTabRequest(CurrentSide(current_state), records.front())
    }];
    objc_cast<NSMenuItem>(_sender).representedObject = payload;
    [current_state respawnRecentlyClosedCallout:_sender];
    objc_cast<NSMenuItem>(_sender).representedObject = nil;
}

- (BOOL) validateMenuItem:(NSMenuItem *)_item
{
    if( _item == m_RestoreLast ) {
        auto current_state = m_Locator();
        if( !current_state )
            return false;
        auto records = Filter(m_Storage->FrontElements(m_Storage->Size()), current_state);
        return !records.empty();
    }
    
    return true;
}

@end
