#pragma once

@class PanelView;

@protocol PanelViewDelegate<NSObject>
@optional
- (void) PanelViewCursorChanged:(PanelView*)_view;
- (NSMenu*) panelView:(PanelView*)_view requestsContextMenuForItemNo:(int)_sort_pos;
- (BOOL) PanelViewPerformDragOperation:(PanelView*)_view sender:(id <NSDraggingInfo>)sender;
- (bool) PanelViewProcessKeyDown:(PanelView*)_view event:(NSEvent *)_event;
- (void) PanelViewRenamingFieldEditorFinished:(PanelView*)_view text:(const string&)_filename;

@end
