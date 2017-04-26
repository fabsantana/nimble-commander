#pragma once

#include <Utility/SheetController.h>
#include <NimbleCommander/Core/NetworkConnectionsManager.h>

@interface ConnectToServer : SheetController<NSTableViewDataSource, NSTableViewDelegate>

- (instancetype) initWithNetworkConnectionsManager:(NetworkConnectionsManager&)_manager;

@property (readonly, nonatomic) optional<NetworkConnectionsManager::Connection> connection;


@end
