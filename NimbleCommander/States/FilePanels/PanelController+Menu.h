#include <NimbleCommander/Core/NetworkConnectionsManager.h>
#include "PanelController.h"

@interface PanelController (Menu)

- (IBAction)OnGoBack:(id)sender;
- (IBAction)OnGoToSavedConnectionItem:(id)sender;
- (void)GoToSavedConnection:(NetworkConnectionsManager::Connection)connection;
- (IBAction)OnGoToFavoriteLocation:(id)sender;
- (IBAction)OnFileViewCommand:(id)sender;
- (IBAction)OnBatchRename:(id)sender;

@end
