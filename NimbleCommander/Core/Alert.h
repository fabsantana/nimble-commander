#pragma once

// this class has two purposes:
// 1. it allows focus movement via arrow keys
// 2. it sets appropriate appearance
// full mimic of NSAlert's interface:
@interface Alert : NSObject
NS_ASSUME_NONNULL_BEGIN

+ (Alert *)alertWithError:(NSError *)error;
- (instancetype) init;

@property NSString  *messageText;
@property NSString  *informativeText;
@property NSImage   *icon;

- (NSButton *)addButtonWithTitle:(NSString *)title;
@property (readonly) NSArray<NSButton *> *buttons;

@property BOOL showsHelp;
@property NSString *helpAnchor;
@property NSAlertStyle alertStyle;

- (NSModalResponse)runModal;
- (void)beginSheetModalForWindow:(NSWindow *)sheetWindow completionHandler:(void (^ __nullable)(NSModalResponse returnCode))handler;

@property (readonly) NSWindow *window;
NS_ASSUME_NONNULL_END
@end

namespace nc::core {

void ShowExceptionAlert( const string &_message = "" );
void ShowExceptionAlert( const std::exception &_exception );

}
