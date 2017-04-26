#pragma once

#include <Utility/SheetController.h>
#include <NimbleCommander/Core/NetworkConnectionsManager.h>
#include "ConnectionSheetProtocol.h"

@interface FTPConnectionSheetController : SheetController<ConnectionSheetProtocol>

@property (nonatomic) NetworkConnectionsManager::Connection connection;
@property (nonatomic) string password;

@end
