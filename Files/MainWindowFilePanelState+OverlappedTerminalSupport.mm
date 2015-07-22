//
//  MainWindowFilePanelState+OverlappedTerminalSupport.m
//  Files
//
//  Created by Michael G. Kazakov on 17/07/15.
//  Copyright (c) 2015 Michael G. Kazakov. All rights reserved.
//

#import "MainWindowFilePanelState+OverlappedTerminalSupport.h"
#import "FilePanelOverlappedTerminal.h"
#import "FilePanelMainSplitView.h"
#import "PanelView.h"
#import "PanelController.h"
#import "PanelAux.h"

@implementation MainWindowFilePanelState (OverlappedTerminalSupport)

- (void) moveFocusToOverlappedTerminal
{
    if( self.isPanelActive )
        m_PreviouslyFocusedPanelController = self.activePanelController;
    [m_OverlappedTerminal focusTerminal];
}

- (void) moveFocusBackToPanels
{
    if( !self.isPanelActive) {
        if( auto p = (PanelController*)m_PreviouslyFocusedPanelController )
            [self ActivatePanelByController:p];
        else
            [self ActivatePanelByController:self.leftPanelController];
    }
}

- (bool) isOverlappedTerminalRunning
{
    if( !m_OverlappedTerminal )
        return false;
    auto s = m_OverlappedTerminal.state;
    return (s != TermShellTask::TaskState::Inactive) &&
           (s != TermShellTask::TaskState::Dead );
}

- (void) increaseBottomTerminalGap
{
    if( !m_OverlappedTerminal || self.isPanelsSplitViewHidden )
        return;
    m_OverlappedTerminalBottomGap++;
    m_OverlappedTerminalBottomGap = min(m_OverlappedTerminalBottomGap, m_OverlappedTerminal.totalScreenLines);
    [self frameDidChange];
    [self activateOverlappedTerminal];
    if(m_OverlappedTerminalBottomGap == 1) {
        [self moveFocusToOverlappedTerminal];
    }
}

- (void) decreaseBottomTerminalGap
{
    if( !m_OverlappedTerminal || self.isPanelsSplitViewHidden )
        return;
    if( m_OverlappedTerminalBottomGap == 0 )
        return;
    m_OverlappedTerminalBottomGap = min(m_OverlappedTerminalBottomGap, m_OverlappedTerminal.totalScreenLines);
    if( m_OverlappedTerminalBottomGap > 0 )
        m_OverlappedTerminalBottomGap--;
    [self frameDidChange];
    if(m_OverlappedTerminalBottomGap == 0)
        [self moveFocusBackToPanels];
}

- (void) activateOverlappedTerminal
{
    auto s = m_OverlappedTerminal.state;
    if( s == TermShellTask::TaskState::Inactive || s == TermShellTask::TaskState::Dead ) {
        string wd;
        if( auto p = self.activePanelController )
            if( p.vfs->IsNativeFS() )
                wd = p.currentDirectoryPath;
        
        [m_OverlappedTerminal runShell:wd];
        
        __weak MainWindowFilePanelState *weakself = self;
        m_OverlappedTerminal.onShellCWDChanged = [=]{
            [(MainWindowFilePanelState*)weakself onOverlappedTerminalShellCWDChanged];
        };
        m_OverlappedTerminal.onLongTaskStarted = [=]{
            [(MainWindowFilePanelState*)weakself onOverlappedTerminalLongTaskStarted];
        };
        m_OverlappedTerminal.onLongTaskFinished = [=]{
            [(MainWindowFilePanelState*)weakself onOverlappedTerminalLongTaskFinished];
        };
    }
}

- (void) onOverlappedTerminalShellCWDChanged
{
    auto pc = self.activePanelController;
    if( !pc )
        pc = m_PreviouslyFocusedPanelController;
    if( pc ) {
        auto cwd = m_OverlappedTerminal.cwd;
        if( cwd != pc.currentDirectoryPath || !pc.vfs->IsNativeFS() ) {
            auto r = make_shared<PanelControllerGoToDirContext>();
            r->RequestedDirectory = cwd;
            r->VFS = VFSNativeHost::SharedHost();
            [pc GoToDirWithContext:r];
        }
    }
}

- (void)onOverlappedTerminalLongTaskStarted
{
    if( self.overlappedTerminalVisible )
        [self hidePanelsSplitView];
}

- (void)onOverlappedTerminalLongTaskFinished
{
    if( self.isPanelsSplitViewHidden )
        [self showPanelsSplitView];
}

- (void) hidePanelsSplitView
{
    [self activateOverlappedTerminal];
    [self moveFocusToOverlappedTerminal];
    m_MainSplitView.hidden = true;
}

- (void) showPanelsSplitView
{
    m_MainSplitView.hidden = false;
    [self moveFocusBackToPanels];
}

- (bool) overlappedTerminalVisible
{
    return m_OverlappedTerminal && m_OverlappedTerminalBottomGap > 0;
}

- (void) synchronizeOverlappedTerminalWithPanel:(PanelController*)_pc
{
    if( _pc.vfs->IsNativeFS() && self.overlappedTerminalVisible )
        [self synchronizeOverlappedTerminalCWD:_pc.currentDirectoryPath];
}

- (void) synchronizeOverlappedTerminalCWD:(const string&)_new_cwd
{
    if( m_OverlappedTerminal )
        [m_OverlappedTerminal changeWorkingDirectory:_new_cwd];
}

- (void) handleCtrlAltTab
{
    if( !self.overlappedTerminalVisible )
        return;
    
    if( self.isPanelActive )
       [self moveFocusToOverlappedTerminal];
    else
        [self moveFocusBackToPanels];
}


- (void) feedOverlappedTerminalWithCurrentFilename
{
    if( !self.overlappedTerminalVisible ||
         m_OverlappedTerminal.state != TermShellTask::TaskState::Shell )
        return;
    
    auto pc = self.activePanelController;
    if( !pc )
        pc = m_PreviouslyFocusedPanelController;
    if( pc && pc.vfs->IsNativeFS() )
        if( auto entry = pc.view.item ) {
            if( panel::IsEligbleToTryToExecuteInConsole(*entry) &&
                m_OverlappedTerminal.isShellVirgin )
                [m_OverlappedTerminal feedShellWithInput:"./"s + entry->Name()];
            else
                [m_OverlappedTerminal feedShellWithInput:entry->Name()];
        }
}

- (bool) handleReturnKeyWithOverlappedTerminal
{
    if( self.overlappedTerminalVisible &&
        m_OverlappedTerminal.state == TermShellTask::TaskState::Shell &&
        m_OverlappedTerminal.isShellVirgin == false ) {
        // dirty, dirty shell... lets clear it all with Return key
        [m_OverlappedTerminal commitShell];        
        return true;
    }
    
    
    return false;
}

- (bool) executeInOverlappedTerminalIfPossible:(const string&)_filename at:(const string&)_path
{
    if( self.overlappedTerminalVisible &&
       m_OverlappedTerminal.state == TermShellTask::TaskState::Shell &&
       m_OverlappedTerminal.isShellVirgin == true ) {
        // assumes that _filename is eligible to execute in terminal (should be check by PanelController before)
        [m_OverlappedTerminal feedShellWithInput:"./"s + _filename];
        [m_OverlappedTerminal commitShell];
        return true;
    }
    return false;
}

@end
