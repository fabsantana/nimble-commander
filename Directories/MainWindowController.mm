//
//  MainWindowController.m
//  Directories
//
//  Created by Michael G. Kazakov on 09.02.13.
//  Copyright (c) 2013 Michael G. Kazakov. All rights reserved.
//

#include "MainWindowController.h"
#include "PanelController.h"
#include "AppDelegate.h"

#include "CopyAsSheetController.h"
#include "CreateDirectorySheetController.h"
#include "MassCopySheetController.h"
#include "DetailedVolumeInformationSheetController.h"
#include "FileSysEntryAttrSheetController.h"
#include "FlexChainedStringsChunk.h"
#include "JobData.h"
#include "FileOp.h"
#include "FileOpMassCopy.h"
#import "OperationsController.h"
#import "OperationsSummaryViewController.h"

#include "KQueueDirUpdate.h"
#include "FSEventsDirUpdate.h"
#include <pwd.h>


@interface MainWindowController ()

@end

@implementation MainWindowController
{
    ActiveState m_ActiveState;                  // creates and owns
    PanelData *m_LeftPanelData;                 // creates and owns
    PanelData *m_RightPanelData;                // creates and owns
    PanelController *m_LeftPanelController;     // creates and owns
    PanelController *m_RightPanelController;    // creates and owns
    JobData *m_JobData;                         // creates and owns
    NSTimer *m_JobsUpdateTimer;
    
    OperationsController *m_OperationsController;
    OperationsSummaryViewController *m_OpSummaryController;
}

- (id)init {
    self = [super initWithWindowNibName:@"MainWindowController"];
    
    if (self)
    {
        m_OperationsController = [[OperationsController alloc] init];
        m_OpSummaryController = [[OperationsSummaryViewController alloc] initWthController:m_OperationsController];
    }
    
    return self;
}

-(void) dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)windowDidLoad
{
    [super windowDidLoad];
 
    // Implement this method to handle any initialization after your window controller's window has been loaded from its nib file.
    
    [m_OpSummaryController AddViewTo:self.OpSummaryBox];
    
    m_JobData = new JobData;

    struct passwd *pw = getpwuid(getuid());
    assert(pw);
    
    m_LeftPanelData = new PanelData;
    m_LeftPanelController = [PanelController new];
    [[self LeftPanelView] SetPanelData:m_LeftPanelData];    
    [m_LeftPanelController SetView:[self LeftPanelView]];
    [m_LeftPanelController SetData:m_LeftPanelData];
    [m_LeftPanelController GoToDirectory:pw->pw_dir];

    m_RightPanelData = new PanelData;
    m_RightPanelController = [PanelController new];
    [[self RightPanelView] SetPanelData:m_RightPanelData];    
    [m_RightPanelController SetView:[self RightPanelView]];
    [m_RightPanelController SetData:m_RightPanelData];
    [m_RightPanelController GoToDirectory:"/"];
    
    m_ActiveState = StateLeftPanel;
    [[self LeftPanelView] Activate];

    [[self JobView] SetJobData:m_JobData];
    
    [[self window] makeFirstResponder:self];
    
    [[[self window] contentView] addConstraint:
     [NSLayoutConstraint constraintWithItem:[self LeftPanelView]
                                  attribute:NSLayoutAttributeWidth
                                  relatedBy:NSLayoutRelationEqual
                                     toItem:[self RightPanelView]
                                  attribute:NSLayoutAttributeWidth
                                 multiplier:1
                                   constant:0]];
        
//    [[[self window] contentView] addConstraint:
//     [NSLayoutConstraint constraintWithItem:[self JobView]
//                                  attribute:NSLayoutAttributeWidth
//                                  relatedBy:NSLayoutRelationEqual
//                                     toItem:0
//                                  attribute:NSLayoutAttributeWidth
//                                 multiplier:0
//                                   constant:163]];

    m_JobsUpdateTimer = [NSTimer scheduledTimerWithTimeInterval: 0.05
                                                         target: self
                                                       selector:@selector(UpdateByJobsTimer:)
                                                       userInfo: nil
                                                        repeats: YES];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(DidBecomeKeyWindow)
                                                 name:NSWindowDidBecomeKeyNotification
                                               object:[self window]];
        
//    [[self Window] visualizeConstraints:[[[self Window] contentView] constraints]];
}

- (void)DidBecomeKeyWindow
{
    // update key modifiers state for views    
    unsigned long flags = [NSEvent modifierFlags];
    [[self LeftPanelView] ModifierFlagsChanged:flags];
    [[self RightPanelView] ModifierFlagsChanged:flags];
}

- (void)UpdateByJobsTimer:(NSTimer*)theTimer
{
    if(m_JobData) m_JobData->PurgeDoneJobs();
    [[self JobView] UpdateByTimer];
}

- (BOOL)acceptsFirstResponder
{
    return YES;
}

- (bool) IsPanelActive
{
    return m_ActiveState == StateLeftPanel || m_ActiveState == StateRightPanel;
}

- (PanelView*) ActivePanelView
{
    if(m_ActiveState == StateLeftPanel)
    {
        return [self LeftPanelView];
    }
    else if(m_ActiveState == StateRightPanel)
    {
        return [self RightPanelView];
    }
    assert(0);
    return 0;
}

- (PanelData*) ActivePanelData
{
    if(m_ActiveState == StateLeftPanel)
    {
        return m_LeftPanelData;
    }
    else if(m_ActiveState == StateRightPanel)
    {
        return m_RightPanelData;
    }
    assert(0);
    return 0;
}

- (PanelController*) ActivePanelController
{
    if(m_ActiveState == StateLeftPanel)
    {
        return m_LeftPanelController;
    }
    else if(m_ActiveState == StateRightPanel)
    {
        return m_RightPanelController;
    }
    assert(0);
    return 0;
}

- (void) HandleTabButton
{
    if(m_ActiveState == StateLeftPanel)
    {
        m_ActiveState = StateRightPanel;
        [[self RightPanelView] Activate];
        [[self LeftPanelView] Disactivate];
    }
    else
    {
        m_ActiveState = StateLeftPanel;
        [[self LeftPanelView] Activate];
        [[self RightPanelView] Disactivate];
    }
}

- (void) HandleCopyAs // shift+F5
{
    assert([self IsPanelActive]);
    PanelView *curview = [self ActivePanelView];
    PanelData *curdata = [self ActivePanelData];
    
    int curpos = [curview GetCursorPosition];
    int rawpos = curdata->SortPosToRawPos(curpos);
    const DirectoryEntryInformation& entry = curdata->EntryAtRawPosition(rawpos);
    if(entry.isdotdot())
        return; // do no react on attempts to copy a parent dir
    if(!entry.isreg())
        return; // we can't copy dirs or other stuff for now
    NSString *orig_name = (__bridge_transfer NSString*) FileNameFromDirectoryEntryInformation(entry);
    
     CopyAsSheetController *ca = [[CopyAsSheetController alloc] init];
    
    [ca ShowSheet:[self window] initialname:orig_name handler:^(int _ret)
     {
         if(_ret == DialogResult::OK)
         {
             NSString *res = [[ca TextField] stringValue];
             char src[__DARWIN_MAXPATHLEN];
             curdata->ComposeFullPathForEntry(rawpos, src);
             FileCopy *fc = new FileCopy;
             fc->InitOpData(src, [res UTF8String], self);
             fc->Run();
             m_JobData->AddJob(fc);
         }
     }];

}

- (void) HandleCreateDirectory // F7
{
    assert([self IsPanelActive]);
    
    CreateDirectorySheetController *cd = [[CreateDirectorySheetController alloc] init];
    [cd ShowSheet:[self window] handler:^(int _ret)
     {
         if(_ret == DialogResult::Create)
         {
             NSString *name = [[cd TextField] stringValue];
             
             PanelData *curdata = [self ActivePanelData];
             char pdir[__DARWIN_MAXPATHLEN];
             curdata->GetDirectoryPath(pdir);
             
             DirectoryCreate *dc = new DirectoryCreate;
             dc->InitOpData([name UTF8String], pdir, self);
             dc->Run();
             m_JobData->AddJob(dc);
         }
     }];
}

- (void) HandleCopyCommand // F5
{
    assert([self IsPanelActive]);
    const PanelData *source, *destination;
    if(m_ActiveState == StateLeftPanel)
    {
        source = m_LeftPanelData;
        destination = m_RightPanelData;
    }
    else
    {
        source = m_RightPanelData;
        destination = m_LeftPanelData;
    }
    
    // TODO: implement a case for copying without selected items in source panel
    // we assume that there's selection for now
    
    char dirpath[__DARWIN_MAXPATHLEN];
    destination->GetDirectoryPathWithTrailingSlash(dirpath);
    NSString *nsdirpath = [NSString stringWithUTF8String:dirpath];
    MassCopySheetController *mc = [[MassCopySheetController alloc] init];
    [mc ShowSheet:[self window] initpath:nsdirpath handler:^(int _ret)
     {
         if(_ret == DialogResult::Copy)
         {
             NSString *copyto = [[mc TextField] stringValue];
             FileOpMassCopy *masscopy = new FileOpMassCopy;
             masscopy->InitOpDataWithPanel(*source, [copyto UTF8String], self);
             masscopy->Run();
             m_JobData->AddJob(masscopy);
         }
     }];
}

- (void) HandleSynchronizePanels // ALT+CMD+U
{
    assert([self IsPanelActive]);
    char dirpath[__DARWIN_MAXPATHLEN];
    
    if(m_ActiveState == StateLeftPanel)
    {
        m_LeftPanelData->GetDirectoryPathWithTrailingSlash(dirpath);
        [m_RightPanelController GoToDirectory:dirpath];
    }
    else
    {
        m_RightPanelData->GetDirectoryPathWithTrailingSlash(dirpath);
        [m_LeftPanelController GoToDirectory:dirpath];
    }
}

- (void) HandleDetailedVolumeInformation // CMD+ALT+L
{
    PanelView *curview = [self ActivePanelView];
    PanelData *curdata = [self ActivePanelData];
    int curpos = [curview GetCursorPosition];
    int rawpos = curdata->SortPosToRawPos(curpos);
    char src[__DARWIN_MAXPATHLEN];
    curdata->ComposeFullPathForEntry(rawpos, src);

    DetailedVolumeInformationSheetController *sheet = [DetailedVolumeInformationSheetController new];
    [sheet ShowSheet:[self window] destpath:src];
}

- (void) HandleEntryAttributes // CTRL+A
{
    FileSysEntryAttrSheetController *sheet = [FileSysEntryAttrSheetController new];
    [sheet ShowSheet:[self window] entries:[self ActivePanelData] ];
    // TODO: callback delegate to grab result and to start background attrs altering process
}

- (void) FireDirectoryChanged: (const char*) _dir ticket:(unsigned long)_ticket
{
    [m_LeftPanelController FireDirectoryChanged:_dir ticket:_ticket];
    [m_RightPanelController FireDirectoryChanged:_dir ticket:_ticket];
}

- (void)keyDown:(NSEvent *)event
{
    NSString*  const character = [event charactersIgnoringModifiers];
    if ( [character length] != 1 ) return;
    unichar const unicode        = [character characterAtIndex:0];
    unsigned short const keycode = [event keyCode];
    NSUInteger const modif       = [event modifierFlags];
#define ISMODIFIER(_v) ( (modif&NSDeviceIndependentModifierFlagsMask) == (_v) )
    switch (unicode)
    {
        case NSHomeFunctionKey:
            if([self IsPanelActive])
                [[self ActivePanelView] HandleFirstFile];
            break;
        case NSEndFunctionKey:
            if([self IsPanelActive])
                [[self ActivePanelView] HandleLastFile];
            break;
        case NSLeftArrowFunctionKey:
            if([self IsPanelActive])
                [[self ActivePanelView] HandlePrevColumn];
            break;
        case NSRightArrowFunctionKey:
            if([self IsPanelActive])
                [[self ActivePanelView] HandleNextColumn];
            break;
        case NSUpArrowFunctionKey:
            if([self IsPanelActive])
                [[self ActivePanelView] HandlePrevFile];
            break;
        case NSDownArrowFunctionKey:
            if([self IsPanelActive])
                [[self ActivePanelView] HandleNextFile];
            break;
        case NSPageDownFunctionKey:
            if([self IsPanelActive])
                [[self ActivePanelView] HandleNextPage];
            break;
        case NSPageUpFunctionKey:
            if([self IsPanelActive])
                [[self ActivePanelView] HandlePrevPage];
            break;
        case NSCarriageReturnCharacter: // RETURN key
            if([self IsPanelActive])
            {
                if(ISMODIFIER(NSShiftKeyMask)) [[self ActivePanelController] HandleShiftReturnButton];
                else                           [[self ActivePanelController] HandleReturnButton];
            }
            break;
        case NSTabCharacter: // TAB key
            [self HandleTabButton];
            break;
        case NSF1FunctionKey:
            if([self IsPanelActive])
            {
                if(ISMODIFIER(NSAlternateKeyMask|NSFunctionKeyMask))
                   [[self LeftPanelGoToButton] performClick:self];
            }
            break;
        case NSF2FunctionKey:
            if([self IsPanelActive])
            {
                if(ISMODIFIER(NSAlternateKeyMask|NSFunctionKeyMask))
                    [[self RightPanelGoToButton] performClick:self];
            }
            break;
        case NSF3FunctionKey:
            if([self IsPanelActive])
            {
                if(ISMODIFIER(NSControlKeyMask|NSFunctionKeyMask))
                    [[self ActivePanelController] ToggleSortingByName];
            }
            break;
        case NSF4FunctionKey:
            if([self IsPanelActive])
            {
                if(ISMODIFIER(NSControlKeyMask|NSFunctionKeyMask))
                    [[self ActivePanelController] ToggleSortingByExt];
            }
            break;
        case NSF5FunctionKey:
            if([self IsPanelActive])
            {
                if(ISMODIFIER(NSControlKeyMask|NSFunctionKeyMask))
                    [[self ActivePanelController] ToggleSortingByMTime];
                else if(ISMODIFIER(NSShiftKeyMask|NSFunctionKeyMask))
                    [self HandleCopyAs];
                else // TODO: need to check of absence of any key modifiers here
                    [self HandleCopyCommand];
            }
            break;
        case NSF6FunctionKey:
            if([self IsPanelActive])
            {
                if(ISMODIFIER(NSControlKeyMask|NSFunctionKeyMask))
                    [[self ActivePanelController] ToggleSortingBySize];
            }
            break;
        case NSF7FunctionKey:
            if([self IsPanelActive])
            {
                [self HandleCreateDirectory];
            }
            break;            
        case NSF8FunctionKey:
            if([self IsPanelActive])
            {
                if(ISMODIFIER(NSControlKeyMask|NSFunctionKeyMask))
                    [[self ActivePanelController] ToggleSortingByBTime];
            }
            break;
    };
    
    switch (keycode)
    {
        case 0: // a button on keyboard
        {
            if([self IsPanelActive])
            {
                if(ISMODIFIER(NSControlKeyMask))
                    [self HandleEntryAttributes];
            }
            break;
        }
            
        case 15: // r button on keyboard
        {
            if([self IsPanelActive])
            {
                if(ISMODIFIER(NSCommandKeyMask))
                    [[self ActivePanelController] RefreshDirectory];
            }
            break;
        }
            
        case 32: // u button on keyboard
        {
            if([self IsPanelActive])
            {
                if(ISMODIFIER(NSCommandKeyMask|NSAlternateKeyMask))
                    [self HandleSynchronizePanels];
                else if([event modifierFlags] & NSCommandKeyMask )
                    ;// swap panel functionality should be called here            
            }
        }
            
        case 37: // l button on keyboard
        {
            if([self IsPanelActive])
            {

                if(ISMODIFIER(NSCommandKeyMask|NSAlternateKeyMask))
                    [self HandleDetailedVolumeInformation];
            }
        }
            
    }
#undef ISMODIFIER
}

- (void)flagsChanged:(NSEvent *)theEvent
{
    if([self IsPanelActive])
    {
        unsigned long flags = [theEvent modifierFlags];
        [[self LeftPanelView] ModifierFlagsChanged:flags];
        [[self RightPanelView] ModifierFlagsChanged:flags];
    }
    
}

- (IBAction)LeftPanelGoToButtonAction:(id)sender
{
    NSString *reqpath = [[self LeftPanelGoToButton] GetCurrentSelectionPath];
    [m_LeftPanelController GoToDirectory:[reqpath UTF8String]];
}

- (IBAction)RightPanelGoToButtonAction:(id)sender
{
    NSString *reqpath = [[self RightPanelGoToButton] GetCurrentSelectionPath];
    [m_RightPanelController GoToDirectory:[reqpath UTF8String]];
}
@end
