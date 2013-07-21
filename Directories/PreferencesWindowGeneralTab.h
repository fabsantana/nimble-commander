//
//  PreferencesWindowGeneralTab.h
//  Files
//
//  Created by Michael G. Kazakov on 13.07.13.
//  Copyright (c) 2013 Michael G. Kazakov. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "3rd_party/RHPreferences/RHPreferences/RHPreferences.h"

@interface PreferencesWindowGeneralTab : NSViewController <RHPreferencesViewControllerProtocol>
- (IBAction)ResetToDefaults:(id)sender;




@end
