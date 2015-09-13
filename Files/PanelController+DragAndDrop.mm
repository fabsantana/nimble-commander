//
//  PanelController+DragAndDrop.m
//  Files
//
//  Created by Michael G. Kazakov on 27.01.14.
//  Copyright (c) 2014 Michael G. Kazakov. All rights reserved.
//

#import <Habanero/FontExtras.h>
#import "PanelController+DragAndDrop.h"
#import "MainWindowFilePanelState.h"
#import "FileCopyOperation.h"
#import "FileLinkOperation.h"
#import "OperationsController.h"
#import "path_manip.h"
#import "Common.h"

static NSString *g_PrivateDragUTI = @__FILES_IDENTIFIER__".filepanelsdraganddrop";
static NSString *g_PasteboardFileURLPromiseUTI = (NSString *)kPasteboardTypeFileURLPromise;
static NSString *g_PasteboardFileURLUTI = (NSString *)kUTTypeFileURL;
static NSString *g_PasteboardFilenamesUTI = (NSString*)CFBridgingRelease(UTTypeCreatePreferredIdentifierForTag(kUTTagClassNSPboardType, (__bridge CFStringRef)NSFilenamesPboardType, kUTTypeData));

@interface PanelDraggingItem : NSPasteboardItem
@property(nonatomic) string filename;
@property(nonatomic) string path;
@property(nonatomic) shared_ptr<VFSHost> vfs;
@property(nonatomic) bool isDir;
- (bool) IsValid;
- (void) Clear;
@end

static bool DraggingIntoFoldersAllowed()
{
    return [NSUserDefaults.standardUserDefaults boolForKey:@"FilePanelsGeneralAllowDraggingIntoFolders"];
}

static NSArray* BuildImageComponentsForItem(PanelDraggingItem* _item)
{
    if(_item == nil ||
       !_item.IsValid)
        return nil;
    
    NSDraggingImageComponent *imageComponent;
    NSMutableArray *components = [NSMutableArray arrayWithCapacity:2];
    
    static NSFont *font = [NSFont systemFontOfSize:13];
    static FontGeometryInfo font_info{ (__bridge CTFontRef) font };
    
    NSImage *icon_image;
    if(_item.vfs->IsNativeFS())
        icon_image = [NSWorkspace.sharedWorkspace iconForFile:[NSString stringWithUTF8String:_item.path.c_str()]];
    else
        icon_image = [NSWorkspace.sharedWorkspace iconForFileType:NSFileTypeForHFSTypeCode(kGenericDocumentIcon)];
    
    [icon_image setSize:NSMakeSize(font_info.LineHeight(), font_info.LineHeight())];
    imageComponent = [NSDraggingImageComponent draggingImageComponentWithKey:NSDraggingImageComponentIconKey];
    imageComponent.frame = NSMakeRect(0, 0, font_info.LineHeight(), font_info.LineHeight());
    imageComponent.contents = icon_image;
    [components addObject:imageComponent];
    
    
    double label_width = 250;
    
    NSImage *label_image = [[NSImage alloc] initWithSize:CGSizeMake(label_width, font_info.LineHeight())];
    [label_image lockFocus];
    
    
    NSShadow *label_shadow = [NSShadow new];
    label_shadow.shadowBlurRadius = 1;
    label_shadow.shadowColor = [NSColor colorWithDeviceRed:0.83 green:0.93 blue:1 alpha:1];
    label_shadow.shadowOffset = NSMakeSize(0, -1);
    
    NSMutableParagraphStyle *item_text_pstyle = [NSMutableParagraphStyle new];
    item_text_pstyle.alignment = NSLeftTextAlignment;
    item_text_pstyle.lineBreakMode = NSLineBreakByTruncatingMiddle;
    
    NSDictionary *attributes = @{ NSFontAttributeName: font,
                                  NSForegroundColorAttributeName: NSColor.blackColor,
                                  NSParagraphStyleAttributeName: item_text_pstyle,
                                  NSShadowAttributeName: label_shadow };
    
    NSString *itemName = [NSString stringWithUTF8String:_item.filename.c_str()];
    
    [itemName drawWithRect:NSMakeRect(0, font_info.Descent(), label_width, font_info.LineHeight())
                   options:0
                attributes:attributes];
    
    [label_image unlockFocus];
    imageComponent = [NSDraggingImageComponent draggingImageComponentWithKey:NSDraggingImageComponentLabelKey];
    imageComponent.frame = NSMakeRect(font_info.LineHeight() + 7, 0, label_width, font_info.LineHeight());
    imageComponent.contents = label_image;
    [components addObject:imageComponent];
    
    return components;
}




@implementation PanelDraggingItem
{
    string m_Filename;
    string m_Path;
    shared_ptr<VFSHost> m_VFS;
    bool m_IsDir;
}

@synthesize filename = m_Filename;
@synthesize path = m_Path;
@synthesize vfs = m_VFS;
@synthesize isDir = m_IsDir;

- (bool) IsValid
{
    return bool(m_VFS);
}

- (void) Clear
{
    m_VFS.reset();
    string().swap(m_Filename);
    string().swap(m_Path);
}

@end



@interface PanelControllerDragSourceBroker : NSObject<NSDraggingSource, NSPasteboardItemDataProvider>
@property(weak)         PanelController    *controller;
@property(nonatomic)    shared_ptr<VFSHost> vfs;
@property(nonatomic)    string              root_path; // path with trailing slash
@property(nonatomic)    unsigned            count;
@property(nonatomic)    vector<PanelDraggingItem*>& items;
@end

@implementation PanelControllerDragSourceBroker
{
    NSURL                       *m_URLPromiseTarget;
    shared_ptr<VFSHost>         m_VFS;
    vector<PanelDraggingItem*>  m_Items;
    unsigned                    m_Count;
    bool                        m_FilenamesPasteboardDone;
    bool                        m_FilenamesPasteboardEnabled;
}

@synthesize vfs = m_VFS;
@synthesize count = m_Count;
@synthesize items = m_Items;

- (id)init
{
    self = [super init];
    if(self) {
        m_FilenamesPasteboardDone = false;
        m_FilenamesPasteboardEnabled = true;
    }
    return self;
}

- (NSDragOperation)draggingSession:(NSDraggingSession *)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context
{
    switch(context) {
        case NSDraggingContextOutsideApplication:
            return NSDragOperationCopy;
            break;
            
        case NSDraggingContextWithinApplication:
            // need some complex logic here later
            
            if(m_Count > 1 || !m_VFS->IsNativeFS())
                return NSDragOperationCopy|NSDragOperationMove;
                
            return NSDragOperationCopy|NSDragOperationLink|NSDragOperationMove;
            
        default:
            return NSDragOperationNone;
    }
}


- (void)pasteboard:(NSPasteboard *)sender item:(PanelDraggingItem *)item provideDataForType:(NSString *)type
{
    // OldStyleDone means that we already pushed the whole files list at once
    // in this case any other items should be simply ignored
    if(m_FilenamesPasteboardDone)
        return;
    
    if(m_FilenamesPasteboardEnabled && [type isEqualToString:g_PasteboardFilenamesUTI])
    { // old style is turned on by some special conditions
        NSMutableArray *ar = [NSMutableArray new];
        for(auto &i: m_Items)
            [ar addObject:[NSURL fileURLWithPath:[NSString stringWithUTF8String:i.path.c_str()]]];
        [sender writeObjects:ar];
        m_FilenamesPasteboardDone = true;
    }
    else if ([type isEqualToString:g_PasteboardFileURLPromiseUTI])
    {
        if(m_URLPromiseTarget == nil)
        {
            PasteboardRef pboardRef = NULL;
            PasteboardCreate((__bridge CFStringRef)sender.name, &pboardRef);
            if (pboardRef != NULL) {
                PasteboardSynchronize(pboardRef);
                CFURLRef urlRef = NULL;
                PasteboardCopyPasteLocation(pboardRef, &urlRef);
                if(urlRef)
                    m_URLPromiseTarget = (NSURL*) CFBridgingRelease(urlRef);
                
                CFRelease(pboardRef);
            }
        }

        if(m_URLPromiseTarget == nil)
            return;
        
        path dest = path(m_URLPromiseTarget.path.fileSystemRepresentation) / item.filename;
        VFSEasyCopyNode(item.path.c_str(), item.vfs,
                        dest.c_str(), VFSNativeHost::SharedHost());

        [item setString:[NSString stringWithUTF8String:dest.c_str()]
                forType:type];
        m_FilenamesPasteboardEnabled = false;
    }
    else if([type isEqualToString:g_PasteboardFileURLUTI])
    {
        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:item.path.c_str()]];
        [url writeToPasteboard:sender];
        m_FilenamesPasteboardEnabled = false;
    }
}

- (void)draggingSession:(NSDraggingSession *)session endedAtPoint:(NSPoint)screenPoint operation:(NSDragOperation)operation
{
    for(PanelDraggingItem *item in [session.draggingPasteboard readObjectsForClasses:@[PanelDraggingItem.class]
                                                                             options:nil])
        if(item.class == PanelDraggingItem.class) // wtf????
            [item Clear];
    m_VFS.reset();
    m_URLPromiseTarget = nil;
    m_Items.clear();
}

@end



@implementation PanelController (DragAndDrop)

+ (NSString*) dragAndDropPrivateUTI
{
    return g_PrivateDragUTI;
}

- (void) RegisterDragAndDropListeners
{
    [m_View registerForDraggedTypes:@[g_PrivateDragUTI, g_PasteboardFileURLUTI, g_PasteboardFileURLPromiseUTI]];
}

- (void) PanelViewWantsDragAndDrop:(PanelView*)_view event:(NSEvent *)_event
{
    // TODO: non-uniform listings support
    if( !self.isUniform )
        return;
    
    auto focus_item = m_View.item;
    if( !focus_item || focus_item.IsDotDot() )
        return;
    
    auto vfs = self.vfs;
    PanelControllerDragSourceBroker *broker = [PanelControllerDragSourceBroker new];
    broker.controller = self;
    broker.vfs = vfs;
    broker.root_path = m_Data.DirectoryPathWithTrailingSlash();
    
    NSMutableArray *drag_items = [NSMutableArray new];
    
    vector<VFSFlexibleListingItem> vfs_items;
    
    if( m_View.item_vd.is_selected() == false)
        vfs_items.emplace_back(focus_item);
    else
        vfs_items = m_Data.SelectedEntries();
    
    NSPoint dragPosition = [_view convertPoint:_event.locationInWindow fromView:nil];
    dragPosition.x -= 16;
    dragPosition.y -= 16;
    
    NSMutableArray *pasteboard_types = [NSMutableArray new];
    [pasteboard_types addObject:g_PasteboardFileURLPromiseUTI];
    [pasteboard_types addObject:g_PrivateDragUTI];
    if(vfs->IsNativeFS()) {
        [pasteboard_types addObject:g_PasteboardFilenamesUTI];
        [pasteboard_types addObject:g_PasteboardFileURLUTI];
    }
    
    for(auto i: vfs_items) {
        PanelDraggingItem *pbItem = [PanelDraggingItem new];
        [pbItem setDataProvider:broker forTypes:pasteboard_types];
    
        // internal information
        pbItem.filename = i.Name();
        pbItem.isDir = i.IsDir();
        pbItem.path = broker.root_path + i.Name();
        pbItem.vfs = vfs;

        // for File URL Promise
        [pbItem setString:(NSString*)kUTTypeData forType:(NSString *)kPasteboardTypeFilePromiseContent];
        
        // visual appearance of a drag
        NSDraggingItem *dragItem = [[NSDraggingItem alloc] initWithPasteboardWriter:pbItem];
        dragItem.draggingFrame = NSMakeRect(dragPosition.x, dragPosition.y, 32, 32);

        __weak PanelDraggingItem *weak_drag_item = pbItem;
        dragItem.imageComponentsProvider = ^{
            return BuildImageComponentsForItem((PanelDraggingItem *)weak_drag_item);
        };
        
        [drag_items addObject:dragItem];
        dragPosition.y -= 16;
        
        broker.items.push_back(pbItem);
    }
    
    broker.count = (unsigned)drag_items.count;
    if(drag_items.count > 0)
        [_view beginDraggingSessionWithItems:drag_items event:_event source:broker];
}

- (int) countAcceptableDraggingItemsExt:(id <NSDraggingInfo>)sender forType:(NSString *)type
{
    __block int urls_amount = 0;
    [sender enumerateDraggingItemsWithOptions:NSDraggingItemEnumerationClearNonenumeratedImages
                                      forView:self.view
                                      classes:@[NSPasteboardItem.class]
                                searchOptions:nil
                                   usingBlock:^(NSDraggingItem *draggingItem, NSInteger idx, BOOL *stop) {
                                       if( [((NSPasteboardItem*)draggingItem.item).types containsObject:type] )
                                           urls_amount++;
                                   }];
    return urls_amount;
}

- (path) composeDestinationForDrag:(id <NSDraggingInfo>)sender
{
    int dragging_over_item_no = [m_View sortedItemPosAtPoint:[m_View convertPoint:sender.draggingLocation fromView:nil]
                                               hitTestOption:PanelViewHitTest::FilenameFact];
    auto dragging_over_item = m_Data.EntryAtSortPosition(dragging_over_item_no);
    bool dragging_over_dir = dragging_over_item && dragging_over_item.IsDir() && DraggingIntoFoldersAllowed();
    path destination_dir = self.currentDirectoryPath;
    destination_dir.remove_filename();
    if(destination_dir.empty())
        destination_dir = "/";
    if(dragging_over_dir) { // alter destination regarding to where drag is currently placed
        if(!dragging_over_item.IsDotDot())
            destination_dir /= dragging_over_item.Name();
        else
            destination_dir = destination_dir.parent_path();
    }
    destination_dir /= "/";
    return destination_dir;
}

- (NSDragOperation)PanelViewDraggingEntered:(PanelView*)_view sender:(id <NSDraggingInfo>)sender
{
    int valid_items = 0;
    int dragging_over_item_no = [m_View sortedItemPosAtPoint:[m_View convertPoint:sender.draggingLocation fromView:nil]
                                            hitTestOption:PanelViewHitTest::FilenameFact];
    auto dragging_over_item = m_Data.EntryAtSortPosition(dragging_over_item_no);
    bool dragging_over_dir = dragging_over_item && dragging_over_item.IsDir() && DraggingIntoFoldersAllowed();
    path destination_dir = [self composeDestinationForDrag:sender];
    
    NSDragOperation result = NSDragOperationNone;
    if(self.vfs->IsWriteable()) {
        if( auto source = objc_cast<PanelControllerDragSourceBroker>(sender.draggingSource) ) {
            // drag is from some other panel
            valid_items = (int)source.items.size();
            if(source.controller == self && !dragging_over_dir) {
                result = NSDragOperationNone; // we can't drag into the same dir on the same panel
            }
            else {
                NSDragOperation mask = sender.draggingSourceOperationMask;
                if( mask == (NSDragOperationMove|NSDragOperationCopy|NSDragOperationLink) ||
                    mask == (NSDragOperationMove|NSDragOperationLink) ||
                    mask == (NSDragOperationMove|NSDragOperationCopy) )
                    result = source.vfs->IsWriteable() ? NSDragOperationMove : NSDragOperationCopy;
                else
                    result = mask;
            }

            // check that we dont drag an item to the same folder in other panel
            if(source.vfs == self.vfs &&
               destination_dir == source.root_path)
                result = NSDragOperationNone;
            
            // check that we dont drag a folder into itself
            if(dragging_over_dir && source.vfs == self.vfs)
                for(PanelDraggingItem *item in [sender.draggingPasteboard readObjectsForClasses:@[PanelDraggingItem.class]
                                                                                        options:nil])
                    if( item.isDir && destination_dir == item.path+"/" ) { // filenames are stored without trailing slashes, so have to add it
                        result = NSDragOperationNone;
                        break;
                    }
        }
        else if([sender.draggingPasteboard.types containsObject:g_PasteboardFileURLUTI]) {
            // drag is from some other application
            valid_items = [self countAcceptableDraggingItemsExt:sender forType:g_PasteboardFileURLUTI];
            NSDragOperation mask = sender.draggingSourceOperationMask;
            if(mask & NSDragOperationCopy)
                result = NSDragOperationCopy;
        }
        else if([sender.draggingPasteboard.types containsObject:g_PasteboardFileURLPromiseUTI] && self.vfs->IsNativeFS() ) {
            // tell we can accept file promises drags
            valid_items = [self countAcceptableDraggingItemsExt:sender forType:g_PasteboardFileURLPromiseUTI];
            NSDragOperation mask = sender.draggingSourceOperationMask;
            if( mask & NSDragOperationMove )
                result = NSDragOperationMove;
            else if( mask & NSDragOperationCopy )
                result = NSDragOperationCopy;
        }
    }
    
    if(valid_items == 0) // regardless of a previous logic - we can't accept an unacceptable drags
        result = NSDragOperationNone;
    else if(result == NSDragOperationNone) // inverse - we can't drag here anything - amount of draggable items is zero
        valid_items = 0;
    
    if(valid_items != m_DragDrop.last_valid_items) {
        m_DragDrop.last_valid_items = valid_items;
        sender.numberOfValidItemsForDrop = valid_items;
    }
    
    if(result != NSDragOperationNone) {
        m_View.draggingOver = true;
        m_View.draggingOverItemAtPosition = dragging_over_dir ? dragging_over_item_no : -1;
    }
    else {
        m_View.draggingOver = false;
        m_View.draggingOverItemAtPosition = -1;
    }
    
    sender.draggingFormation = NSDraggingFormationList;
    
    return result;
}

- (NSDragOperation)PanelViewDraggingUpdated:(PanelView*)_view sender:(id <NSDraggingInfo>)sender
{
    return [self PanelViewDraggingEntered:_view sender:sender];
}

- (void)PanelViewDraggingExited:(PanelView*)_view sender:(id <NSDraggingInfo>)sender
{
    m_DragDrop.last_valid_items = -1;
    m_View.draggingOver = false;
    m_View.draggingOverItemAtPosition = -1;
}

- (BOOL) PanelViewPerformDragOperation:(PanelView*)_view sender:(id <NSDraggingInfo>)sender
{
    // clear UI from dropping information
    m_DragDrop.last_valid_items = -1;
    m_View.draggingOver = false;
    m_View.draggingOverItemAtPosition = -1;
    
    path destination_dir = [self composeDestinationForDrag:sender];
    
    if(id idsource = sender.draggingSource) {
        if( auto source_broker = objc_cast<PanelControllerDragSourceBroker>(idsource) ) {
            // we're dragging something here from another PanelView, lets understand what actually
            PanelController *source_controller = source_broker.controller;
            auto opmask = sender.draggingSourceOperationMask;

            vector<string> files;
            for(PanelDraggingItem *item in [sender.draggingPasteboard readObjectsForClasses:@[PanelDraggingItem.class]
                                                                                    options:nil])
                files.emplace_back(item.filename);

            if(files.empty())
                return false;
            
            if( !self.vfs->IsWriteable() )
                return false;
            

            if( opmask == (NSDragOperationMove|NSDragOperationCopy|NSDragOperationLink) ||
                opmask == (NSDragOperationMove|NSDragOperationLink) ||
                opmask == (NSDragOperationMove|NSDragOperationCopy) )
                opmask = source_broker.vfs->IsWriteable() ? NSDragOperationMove : NSDragOperationCopy;

            if( opmask == NSDragOperationCopy ) {
                FileCopyOperationOptions opts;
                FileCopyOperation *op;
                if(source_broker.vfs->IsNativeFS() && self.vfs->IsNativeFS())
                    op = [[FileCopyOperation alloc] initWithFiles:move(files)
                                                             root:source_broker.root_path.c_str()
                                                             dest:destination_dir.c_str()
                                                          options:opts]; // native->native
                else if(self.vfs->IsNativeFS())
                    op = [[FileCopyOperation alloc] initWithFiles:move(files)
                                                             root:source_broker.root_path.c_str()
                                                          rootvfs:source_broker.vfs
                                                             dest:destination_dir.c_str()
                                                          options:opts]; // vfs->native
                else
                    op = [[FileCopyOperation alloc] initWithFiles:move(files)
                                                             root:source_broker.root_path.c_str()
                                                           srcvfs:source_broker.vfs
                                                             dest:destination_dir.c_str()
                                                           dstvfs:self.vfs
                                                          options:opts]; // vfs->vfs
                [op AddOnFinishHandler:^{
                    dispatch_to_main_queue([=]{
                        [self RefreshDirectory];
                    });
                }];
                [self.state.OperationsController AddOperation:op];
                return true;
            }
            else if( opmask == NSDragOperationMove ) {
                if( !source_broker.vfs->IsWriteable() )
                    return false; // should not happen!
                FileCopyOperationOptions opts;
                opts.docopy = false;
                FileCopyOperation *op;
                if( source_broker.vfs->IsNativeFS() && self.vfs->IsNativeFS() )
                    op = [[FileCopyOperation alloc] initWithFiles:move(files)
                                                             root:source_broker.root_path.c_str()
                                                             dest:destination_dir.c_str()
                                                          options:opts]; // native->native
                // TODO: implement moving vfs->native !!!!!
                else
                    op = [[FileCopyOperation alloc] initWithFiles:move(files)
                                                             root:source_broker.root_path.c_str()
                                                           srcvfs:source_broker.vfs
                                                             dest:destination_dir.c_str()
                                                           dstvfs:self.vfs
                                                          options:opts]; // vfs->vfs
                __weak PanelController *src_cntr = source_controller;
                __weak PanelController *dst_cntr = self;
                [op AddOnFinishHandler:^{
                    dispatch_to_main_queue([=]{
                        if(PanelController *pc = src_cntr) [pc RefreshDirectory];
                        if(PanelController *pc = dst_cntr) [pc RefreshDirectory];
                    });
                }];
                [self.state.OperationsController AddOperation:op];
                return true;
            }
            else if(opmask == NSDragOperationLink &&
               files.size() == 1 &&
               source_broker.vfs->IsNativeFS() ) {
                string source_path = source_broker.root_path + files.front().c_str();
                string dest_path = self.currentDirectoryPath + files.front().c_str();
                [self.state.OperationsController AddOperation:
                    [[FileLinkOperation alloc] initWithNewSymbolinkLink:source_path.c_str()
                                                               linkname:dest_path.c_str()]];
                return true;
            }
        }
    }
    else if([sender.draggingPasteboard.types containsObject:g_PasteboardFileURLUTI]) {
        NSArray *fileURLs = [sender.draggingPasteboard
                             readObjectsForClasses:@[NSURL.class]
                             options:@{NSPasteboardURLReadingFileURLsOnlyKey:@YES}
                             ];
        
        map<string, vector<string>> files; // directory/ -> [filename1, filename2, ...]
  
        for(NSURL *url in fileURLs) {
            path source_path = url.path.fileSystemRepresentation;
            string root = source_path.parent_path().native() + "/";
            string filename = source_path.filename().native();
            files[root].emplace_back(filename);
        }

        for(auto &t: files) {            
            FileCopyOperationOptions opts;
            opts.docopy = true; // TODO: support move from other apps someday?
            FileCopyOperation *op;

            if(!self.vfs->IsNativeFS() && self.vfs->IsWriteable() ) // vfs->vfs path
                op = [[FileCopyOperation alloc] initWithFiles:t.second
                                                         root:t.first.c_str()
                                                       srcvfs:VFSNativeHost::SharedHost()
                                                         dest:destination_dir.c_str()
                                                       dstvfs:self.vfs
                                                      options:opts];
            else // native -> native path
                op = [[FileCopyOperation alloc] initWithFiles:t.second
                                                         root:t.first.c_str()
                                                         dest:destination_dir.c_str()
                                                      options:opts];
            [self.state.OperationsController AddOperation:op];
        }
        
        return true;
    }
    else if([sender.draggingPasteboard.types containsObject:g_PasteboardFileURLPromiseUTI] && self.vfs->IsNativeFS() ) {
        // accept file promises drags
        NSURL *drop_url = [NSURL fileURLWithPath:[NSString stringWithUTF8StdString:destination_dir.native()]];
        [sender namesOfPromisedFilesDroppedAtDestination:drop_url];
        return true;
    }
    
    return false;
}


@end
