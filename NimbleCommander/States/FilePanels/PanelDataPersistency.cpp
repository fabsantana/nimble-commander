#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wshadow"
#include <boost/uuid/uuid_io.hpp>
#include <boost/uuid/string_generator.hpp>
#pragma clang diagnostic pop
#include <boost/container/static_vector.hpp>
#include <VFS/Native.h>
#include <VFS/ArcLA.h>
#include <VFS/ArcUnRAR.h>
#include <VFS/PS.h>
#include <VFS/XAttr.h>
#include <VFS/NetFTP.h>
#include <VFS/NetSFTP.h>
#include <VFS/NetDropbox.h>
#include <NimbleCommander/Core/NetworkConnectionsManager.h>
#include <NimbleCommander/Core/VFSInstanceManager.h>
#include "PanelDataPersistency.h"


#include <NimbleCommander/Core/ConfigBackedNetworkConnectionsManager.h>
static NetworkConnectionsManager &ConnectionsManager()
{
    return ConfigBackedNetworkConnectionsManager::Instance();
}


//type: "type", // VFSNativeHost::Tag, VFSPSHost::Tag, VFSArchiveHost::Tag, VFSArchiveUnRARHost::Tag, VFSXAttrHost::Tag, "network"
// perhaps "archive" in the future, when more of them will come and some dedicated "ArchiveManager" will appear
//junction: "path"

static const auto g_StackHostsKey = "hosts_v1";
static const auto g_StackPathKey = "path";
static const auto g_HostInfoTypeKey = "type";
static const auto g_HostInfoTypeNetworkValue = "network";
static const auto g_HostInfoJunctionKey = "junction";
static const auto g_HostInfoUuidKey = "uuid";
//
//{
//hosts: [...]
//path: "/erere/rere/trtr"
//}


namespace {

struct Native
{
    /* native hosts does not need any context information */
};

struct PSFS
{
    /* native hosts does not need any context information */
};

struct XAttr
{
    string junction;
};

struct Network
{
    boost::uuids::uuid connection;
};

struct ArcLA
{
    string junction;
};

struct ArcUnRAR
{
    string junction;
};

};

bool PanelDataPersisency::Location::is_native() const noexcept
{
    return hosts.empty();
}

bool PanelDataPersisency::Location::is_network() const noexcept
{
    return !hosts.empty() && any_cast<Network>(&hosts.front());
}

static optional<rapidjson::StandaloneValue> EncodeAny( const any& _host );

static bool IsNetworkVFS( const VFSHost& _host )
{
    const auto tag = _host.FSTag();
    return tag == VFSNetFTPHost::Tag ||
           tag == VFSNetSFTPHost::Tag ||
           tag == VFSNetDropboxHost::Tag;
}

static any EncodeState( const VFSHost& _host )
{
    auto tag = _host.FSTag();
    if( tag == VFSNativeHost::Tag ) {
        return Native{};
    }
    else if( tag == VFSPSHost::Tag ) {
        return PSFS{};
    }
    else if( tag == VFSXAttrHost::Tag ) {
        return XAttr{ _host.JunctionPath() };
    }
    else if( IsNetworkVFS(_host) ) {
        if( auto conn = ConnectionsManager().ConnectionForVFS(_host) )
            return Network{ conn->Uuid() };
    }
    else if( tag == VFSArchiveHost::Tag ) {
        return ArcLA{ _host.JunctionPath() };
    }
    else if( tag == VFSArchiveUnRARHost::Tag ) {
        return ArcUnRAR{ _host.JunctionPath() };
    }
    return {};
}

optional<PanelDataPersisency::Location> PanelDataPersisency::
EncodeLocation( const VFSHost &_vfs, const string &_path )
{
    Location location;

    // in case of native vfs we simply omit mentioning is - simply path is enough
    if( !_vfs.IsNativeFS() ) {
        boost::container::static_vector<const VFSHost*, 32> hosts;
        auto host_rec = &_vfs;
        while( host_rec ) {
            hosts.emplace_back( host_rec );
            host_rec = host_rec->Parent().get();
        }
        
        reverse( begin(hosts), end(hosts) );

        for( auto h: hosts ) {
            auto encoded = EncodeState(*h);
            if( !encoded.empty() )
                location.hosts.emplace_back( move(encoded) );
            else
                return nullopt;
        }
    }
    location.path = _path;
    if( location.path.empty() || location.path.back() != '/' )
        location.path.push_back('/');
    
    return location;
}

optional<rapidjson::StandaloneValue> PanelDataPersisency::
EncodeVFSPath( const VFSListing &_listing )
{
    if( !_listing.IsUniform() )
        return nullopt;

    return EncodeVFSPath( *_listing.Host(), _listing.Directory() );
}

optional<rapidjson::StandaloneValue> PanelDataPersisency::
EncodeVFSPath( const VFSHost &_vfs, const string &_path )
{
    vector<const VFSHost*> hosts;
    auto host_rec = &_vfs;
    while( host_rec ) {
        hosts.emplace_back( host_rec );
        host_rec = host_rec->Parent().get();
    }
    
    reverse( begin(hosts), end(hosts) );
    
    rapidjson::StandaloneValue json(rapidjson::kObjectType);
    rapidjson::StandaloneValue json_hosts(rapidjson::kArrayType);
    for( auto h: hosts )
        if( auto v = EncodeVFSHostInfo(*h) )
            json_hosts.PushBack( move(*v), rapidjson::g_CrtAllocator );
        else
            return nullopt;
    if( !json_hosts.Empty() )
        json.AddMember(rapidjson::StandaloneValue(g_StackHostsKey, rapidjson::g_CrtAllocator),
                       move(json_hosts),
                       rapidjson::g_CrtAllocator);
    
    json.AddMember(rapidjson::StandaloneValue(g_StackPathKey, rapidjson::g_CrtAllocator),
                   rapidjson::StandaloneValue(_path.c_str(), rapidjson::g_CrtAllocator),
                   rapidjson::g_CrtAllocator);
    
    return move(json);
}

optional<rapidjson::StandaloneValue> PanelDataPersisency::
LocationToJSON( const Location &_location )
{
    rapidjson::StandaloneValue json(rapidjson::kObjectType);
    rapidjson::StandaloneValue json_hosts(rapidjson::kArrayType);
    for( auto &h: _location.hosts )
        if( auto v = EncodeAny(h) )
            json_hosts.PushBack( move(*v), rapidjson::g_CrtAllocator );
        else
            return nullopt;
    if( !json_hosts.Empty() )
        json.AddMember(rapidjson::StandaloneValue(g_StackHostsKey, rapidjson::g_CrtAllocator),
                       move(json_hosts),
                       rapidjson::g_CrtAllocator);
    
    json.AddMember(rapidjson::StandaloneValue(g_StackPathKey, rapidjson::g_CrtAllocator),
                   rapidjson::StandaloneValue(_location.path, rapidjson::g_CrtAllocator),
                   rapidjson::g_CrtAllocator);
    
    return move(json);
}

optional<PanelDataPersisency::Location> PanelDataPersisency::JSONToLocation( const json &_json )
{
    if( !_json.IsObject() || !_json.HasMember(g_StackPathKey) || !_json[g_StackPathKey].IsString() )
        return nullopt;

    Location result;
    result.path = _json[g_StackPathKey].GetString();
    
    if( !_json.HasMember(g_StackHostsKey) )
        return move(result);
    
    if( _json.HasMember(g_StackHostsKey) && _json[g_StackHostsKey].IsArray() ) {
        auto &hosts = _json[g_StackHostsKey];
        for( auto i = hosts.Begin(), e = hosts.End(); i != e; ++i ) {
            auto &h = *i;
            const auto has_string = [&h](const char *_key) { return h.HasMember(_key) && h[_key].IsString(); };
            
            if( !has_string(g_HostInfoTypeKey) )
                return nullopt; // invalid data
            const auto tag = string_view{ h[g_HostInfoTypeKey].GetString() };
            
            if( tag == VFSNativeHost::Tag ) {
                result.hosts.emplace_back( Native{} );
            }
            else if( tag == VFSPSHost::Tag ) {
                result.hosts.emplace_back( PSFS{} );
            }
            else if( tag == VFSXAttrHost::Tag ) {
                if( !has_string(g_HostInfoJunctionKey) )
                    return nullopt; // invalid data
                if( result.hosts.size() < 1 )
                    return nullopt; // invalid data
                
                result.hosts.emplace_back( XAttr{  h[g_HostInfoJunctionKey].GetString() } );
            }
            else if( tag == g_HostInfoTypeNetworkValue ) {
                if( !has_string(g_HostInfoUuidKey) )
                    return nullopt; // invalid data
                
                static const boost::uuids::string_generator uuid_gen{};
                const auto uuid = uuid_gen( h[g_HostInfoUuidKey].GetString() );
                
                result.hosts.emplace_back( Network{ uuid } );
            }
            else if( tag == VFSArchiveHost::Tag ) {
                if( !has_string(g_HostInfoJunctionKey) )
                    return nullopt; // invalid data
                if( result.hosts.size() < 1 )
                    return nullopt; // invalid data
                
                result.hosts.emplace_back( ArcLA{ h[g_HostInfoJunctionKey].GetString() } );
            }
            else if( tag == VFSArchiveUnRARHost::Tag ) {
                if( !has_string(g_HostInfoJunctionKey) )
                    return nullopt; // invalid data
                if( result.hosts.size() < 1 || !linb::any_cast<Native>(&result.hosts.back()) )
                    return nullopt; // invalid data
                
                result.hosts.emplace_back( ArcUnRAR{ h[g_HostInfoJunctionKey].GetString() } );
            }
        }
    }

    return move(result);
}

static const char *VFSTagForNetworkConnection( const NetworkConnectionsManager::Connection &_conn )
{
    if( auto ftp = _conn.Cast<NetworkConnectionsManager::FTPConnection>() )
        return VFSNetFTPHost::Tag;
    else if( auto sftp =_conn.Cast<NetworkConnectionsManager::SFTPConnection>() )
        return VFSNetSFTPHost::Tag;
    else if( auto dropbox = _conn.Cast<NetworkConnectionsManager::Dropbox>() )
        return VFSNetDropboxHost::Tag;
    else
        return "<unknown_vfs>";
}

string PanelDataPersisency::MakeFootprintString( const Location &_loc )
{
    string footprint;
    if( _loc.hosts.empty() ) {
        footprint += VFSNativeHost::Tag;
        footprint += "||";
    }
    for( auto &h: _loc.hosts ) {
        if( auto native = any_cast<Native>(&h) ) {
            footprint += VFSNativeHost::Tag;
            footprint += "|";
        }
        else if( auto psfs = any_cast<PSFS>(&h) ) {
            footprint += VFSPSHost::Tag;
            footprint += "|[psfs]:";
        }
        else if( auto xattr = any_cast<XAttr>(&h) ) {
            footprint += VFSXAttrHost::Tag;
            footprint += "|";
            footprint += xattr->junction;
        }
        else if( auto network = any_cast<Network>(&h) ) {
            const auto &mgr = ConnectionsManager();
            if( auto conn = mgr.ConnectionByUUID(network->connection) ) {
                footprint += VFSTagForNetworkConnection(*conn);
                footprint += "|";
                footprint += NetworkConnectionsManager::MakeConnectionPath(*conn);
            }
        }
        else if( auto la = any_cast<ArcLA>(&h) ) {
            footprint += VFSArchiveHost::Tag;
            footprint += "|";
            footprint += la->junction;
        }
        else if( auto rar = any_cast<ArcUnRAR>(&h) ) {
            footprint += VFSArchiveUnRARHost::Tag;
            footprint += "|";
            footprint += rar->junction;
        }
        footprint += "|";
    }
    
    footprint += _loc.path;
    return footprint;
}

size_t PanelDataPersisency::MakeFootprintStringHash( const Location &_loc )
{
    return hash<string>()( MakeFootprintString(_loc) );
}

string PanelDataPersisency::MakeVerbosePathString( const Location &_loc )
{
    string verbose;
    for( auto &h: _loc.hosts ) {
        if( auto psfs = any_cast<PSFS>(&h) )
            verbose += "[psfs]:";
        else if( auto xattr = any_cast<XAttr>(&h) )
            verbose += xattr->junction;
        else if( auto network = any_cast<Network>(&h) ) {
            const auto &mgr = ConnectionsManager();
            if( auto conn = mgr.ConnectionByUUID(network->connection) )
                verbose += NetworkConnectionsManager::MakeConnectionPath(*conn);
        }
        else if( auto la = any_cast<ArcLA>(&h) )
            verbose += la->junction;
        else if( auto rar = any_cast<ArcUnRAR>(&h) )
            verbose += rar->junction;
    }
    
    verbose += _loc.path;
    return verbose;
}

string PanelDataPersisency::MakeVerbosePathString( const VFSHost &_host, const string &_directory )
{
    array<const VFSHost*, 32> hosts;
    int hosts_n = 0;

    auto cur = &_host;
    while( cur ) {
        hosts[hosts_n++] = cur;
        cur = cur->Parent().get();
    }
    
    string s;
    while(hosts_n > 0)
        s += hosts[--hosts_n]->Configuration().VerboseJunction();
    s += _directory;
    if(s.back() != '/') s += '/';
    return s;
}

optional<rapidjson::StandaloneValue> PanelDataPersisency::EncodeVFSHostInfo( const VFSHost& _host )
{
    using namespace rapidjson;
    auto tag = _host.FSTag();
    rapidjson::StandaloneValue json(rapidjson::kObjectType);
    if( tag == VFSNativeHost::Tag ) {
        json.AddMember( MakeStandaloneString(g_HostInfoTypeKey), MakeStandaloneString(tag), g_CrtAllocator );
        return move(json);
    }
    else if( tag == VFSPSHost::Tag ) {
        json.AddMember( MakeStandaloneString(g_HostInfoTypeKey), MakeStandaloneString(tag), g_CrtAllocator );
        return move(json);
    }
    else if( tag == VFSXAttrHost::Tag ) {
        json.AddMember( MakeStandaloneString(g_HostInfoTypeKey), MakeStandaloneString(tag), g_CrtAllocator );
        json.AddMember( MakeStandaloneString(g_HostInfoJunctionKey), MakeStandaloneString(_host.JunctionPath()), g_CrtAllocator );
        return move(json);
    }
    else if( IsNetworkVFS(_host) ) {
        if( auto conn = ConnectionsManager().ConnectionForVFS(_host) )  {
            json.AddMember( MakeStandaloneString(g_HostInfoTypeKey), MakeStandaloneString(g_HostInfoTypeNetworkValue), g_CrtAllocator );
            json.AddMember( MakeStandaloneString(g_HostInfoUuidKey), MakeStandaloneString(to_string(conn->Uuid()).c_str()), g_CrtAllocator );
            return move(json);
        }
    }
    else if( tag == VFSArchiveHost::Tag ||
             tag == VFSArchiveUnRARHost::Tag ) {
        json.AddMember( MakeStandaloneString(g_HostInfoTypeKey), MakeStandaloneString(tag), g_CrtAllocator );
        json.AddMember( MakeStandaloneString(g_HostInfoJunctionKey), MakeStandaloneString(_host.JunctionPath()), g_CrtAllocator );
        return move(json);
    }
    return nullopt;
}

static optional<rapidjson::StandaloneValue> EncodeAny( const any& _host )
{
    using namespace rapidjson;
    rapidjson::StandaloneValue json(rapidjson::kObjectType);
    if( auto native = any_cast<Native>(&_host) ) {
        json.AddMember(MakeStandaloneString(g_HostInfoTypeKey),
                       MakeStandaloneString(VFSNativeHost::Tag),
                       g_CrtAllocator );
        return move(json);
    }
    else if( auto psfs = any_cast<PSFS>(&_host) ) {
        json.AddMember(MakeStandaloneString(g_HostInfoTypeKey),
                       MakeStandaloneString(VFSPSHost::Tag),
                       g_CrtAllocator );
        return move(json);
    }
    else if( auto xattr = any_cast<XAttr>(&_host) ) {
        json.AddMember(MakeStandaloneString(g_HostInfoTypeKey),
                       MakeStandaloneString(VFSXAttrHost::Tag),
                       g_CrtAllocator );
        json.AddMember( MakeStandaloneString(g_HostInfoJunctionKey),
                       MakeStandaloneString(xattr->junction),
                       g_CrtAllocator );
        return move(json);
    }
    else if( auto network = any_cast<Network>(&_host) ) {
        json.AddMember(MakeStandaloneString(g_HostInfoTypeKey),
                       MakeStandaloneString(g_HostInfoTypeNetworkValue),
                       g_CrtAllocator );
        json.AddMember(MakeStandaloneString(g_HostInfoUuidKey),
                       MakeStandaloneString(to_string(network->connection)),
                       g_CrtAllocator );
        return move(json);
    }
    else if( auto la = any_cast<ArcLA>(&_host) ) {
        json.AddMember(MakeStandaloneString(g_HostInfoTypeKey),
                       MakeStandaloneString(VFSArchiveHost::Tag),
                       g_CrtAllocator );
        json.AddMember(MakeStandaloneString(g_HostInfoJunctionKey),
                       MakeStandaloneString(la->junction),
                       g_CrtAllocator );
        return move(json);
    }
    else if( auto rar = any_cast<ArcUnRAR>(&_host) ) {
        json.AddMember(MakeStandaloneString(g_HostInfoTypeKey),
                       MakeStandaloneString(VFSArchiveUnRARHost::Tag),
                       g_CrtAllocator );
        json.AddMember(MakeStandaloneString(g_HostInfoJunctionKey),
                       MakeStandaloneString(rar->junction),
                       g_CrtAllocator );
        return move(json);
    }
    
    return nullopt;
}

int PanelDataPersisency::CreateVFSFromState( const rapidjson::StandaloneValue &_state, VFSHostPtr &_host )
{
    if( _state.IsObject() && !_state.HasMember(g_StackHostsKey) && _state.HasMember(g_StackPathKey) ) {
        _host = VFSNativeHost::SharedHost();
        return 0;
    }

    if( _state.IsObject() && _state.HasMember(g_StackHostsKey) && _state[g_StackHostsKey].IsArray() ) {
        auto &hosts = _state[g_StackHostsKey];
        vector<VFSHostPtr> vfs;
        
        try {
            for( auto i = hosts.Begin(), e = hosts.End(); i != e; ++i ) {
                auto &h = *i;
                const auto has_string = [&h](const char *_key) { return h.HasMember(_key) && h[_key].IsString(); };
                
                if( !has_string(g_HostInfoTypeKey) )
                    return VFSError::GenericError; // invalid data
                const auto tag = string_view{ h[g_HostInfoTypeKey].GetString() };
                
                if( tag == VFSNativeHost::Tag ) {
                    vfs.emplace_back( VFSNativeHost::SharedHost() );
                }
                else if( tag == VFSPSHost::Tag ) {
                    vfs.emplace_back( VFSPSHost::GetSharedOrNew() );
                }
                else if( tag == VFSXAttrHost::Tag ) {
                    if( !has_string(g_HostInfoJunctionKey) )
                        return VFSError::GenericError; // invalid data
                    if( vfs.size() < 1 )
                        return VFSError::GenericError; // invalid data
                    
                    auto xattr_vfs = make_shared<VFSXAttrHost>( h[g_HostInfoJunctionKey].GetString(), vfs.back() );
                    vfs.emplace_back( xattr_vfs );
                }
                else if( tag == g_HostInfoTypeNetworkValue ) {
                    if( !has_string(g_HostInfoUuidKey) )
                        return VFSError::GenericError; // invalid data

                    static const boost::uuids::string_generator uuid_gen{};
                    const auto uuid = uuid_gen( h[g_HostInfoUuidKey].GetString() );
                    if( auto connection = ConnectionsManager().ConnectionByUUID( uuid ) ) {
                        if ( auto host = ConnectionsManager().SpawnHostFromConnection(*connection) )
                            vfs.emplace_back( host );
                        else
                            return VFSError::GenericError; // failed to spawn connection
                    }
                    else
                        return VFSError::GenericError; // failed to find connection by uuid
                }
                else if( tag == VFSArchiveHost::Tag ) {
                    if( !has_string(g_HostInfoJunctionKey) )
                        return VFSError::GenericError; // invalid data
                    if( vfs.size() < 1 )
                        return VFSError::GenericError; // invalid data
                    
                    auto host = make_shared<VFSArchiveHost>( h[g_HostInfoJunctionKey].GetString(), vfs.back() );
                    vfs.emplace_back( host );
                }
                else if( tag == VFSArchiveUnRARHost::Tag ) {
                    if( !has_string(g_HostInfoJunctionKey) )
                        return VFSError::GenericError; // invalid data
                    if( vfs.size() < 1 || !vfs.back()->IsNativeFS() )
                        return VFSError::GenericError; // invalid data
                    
                    auto host = make_shared<VFSArchiveUnRARHost>( h[g_HostInfoJunctionKey].GetString() );
                    vfs.emplace_back( host );
                }
                // ...
            }
        }
        catch(VFSErrorException &ee) {
            return ee.code();
        }
        if( !vfs.empty() )
            _host = vfs.back();
        return VFSError::Ok;
    }
    
    return VFSError::GenericError;
}

static bool Fits( VFSHost& _alive, const any &_encoded )
{
    const auto tag = _alive.FSTag();
    const auto encoded = &_encoded;

    if( tag == VFSNativeHost::Tag ) {
        if( any_cast<Native>(encoded) )
            return true;
    }
    else if( tag == VFSPSHost::Tag ) {
        if( any_cast<PSFS>(encoded) )
            return true;
    }
    else if( tag == VFSXAttrHost::Tag ) {
        if( auto xattr = any_cast<XAttr>(encoded) )
            return xattr->junction == _alive.JunctionPath();
    }
    else if( IsNetworkVFS(_alive) ) {
        if( auto network = any_cast<Network>(encoded) )
            if( auto conn = ConnectionsManager().ConnectionForVFS( _alive ) )
                return network->connection == conn->Uuid();
    }
    else if( tag == VFSArchiveHost::Tag ) {
        if( auto la = any_cast<ArcLA>(encoded) )
            return la->junction == _alive.JunctionPath();
    }
    else if( tag == VFSArchiveUnRARHost::Tag ) {
        if( auto unrar = any_cast<ArcUnRAR>(encoded) )
            return unrar->junction == _alive.JunctionPath();
    }
    return false;
}

static VFSHostPtr FindFitting(
    const vector<weak_ptr<VFSHost>> &_hosts,
    const any &_encoded,
    const VFSHost *_parent /* may be nullptr */ )
{
    for( auto &weak_host: _hosts )
        if( auto host = weak_host.lock() )
            if( Fits(*host, _encoded) )
                if( host->Parent().get() == _parent ) // comparison of two nullptrs is ok here
                    return host;
    return nullptr;
}

int PanelDataPersisency::CreateVFSFromLocation( const Location &_state, VFSHostPtr &_host )
{
    if( _state.hosts.empty() ) {
        // short path for most common case - native vfs
        _host = VFSNativeHost::SharedHost();
        return 0;
    }

    vector<VFSHostPtr> vfs;
    auto alive_hosts = VFSInstanceManager::Instance().AliveHosts(); // make it optional perhaps?
    try {
        for( auto &h: _state.hosts) {
            const VFSHostPtr back = vfs.empty() ? nullptr : vfs.back();

            if( auto exist = FindFitting(alive_hosts, h, back.get() ) ) { // we're lucky!
                vfs.emplace_back( exist );
                continue;
            }
            // no luck - have to build this layer from scratch
            
            if( auto native = any_cast<Native>(&h) ) {
                vfs.emplace_back( VFSNativeHost::SharedHost() );
            }
            else if( auto psfs = any_cast<PSFS>(&h) ) {
                vfs.emplace_back( VFSPSHost::GetSharedOrNew() );
            }
            else if( auto xattr = any_cast<XAttr>(&h) ) {
                if( vfs.size() < 1 )
                    return VFSError::GenericError; // invalid data
                
                auto xattr_vfs = make_shared<VFSXAttrHost>( xattr->junction.c_str(), vfs.back() );
                vfs.emplace_back( xattr_vfs );
            }
            else if( auto network = any_cast<Network>(&h) ) {
                auto &mgr = ConnectionsManager();
                if( auto conn = mgr.ConnectionByUUID(network->connection) ) {
                    if ( auto host = mgr.SpawnHostFromConnection(*conn) )
                        vfs.emplace_back( host );
                    else
                        return VFSError::GenericError; // failed to spawn connection
                }
                else
                    return VFSError::GenericError; // failed to find connection by uuid
            }
            else if( auto la = any_cast<ArcLA>(&h) ) {
                if( vfs.size() < 1 )
                    return VFSError::GenericError; // invalid data
                
                auto host = make_shared<VFSArchiveHost>( la->junction.c_str(), vfs.back() );
                vfs.emplace_back( host );
            }
            else if( auto rar = any_cast<ArcUnRAR>(&h) ) {
                if( vfs.size() < 1 || !vfs.back()->IsNativeFS() )
                    return VFSError::GenericError; // invalid data
                
                auto host = make_shared<VFSArchiveUnRARHost>( rar->junction.c_str() );
                vfs.emplace_back( host );
            }
        }
    }
    catch(VFSErrorException &ee) {
        return ee.code();
    }
    
    if( !vfs.empty() ) {
        _host = vfs.back();
        return VFSError::Ok;
    }
    else
        return VFSError::GenericError;
}

string PanelDataPersisency::GetPathFromState( const rapidjson::StandaloneValue &_state )
{
    if( _state.IsObject() && _state.HasMember(g_StackPathKey) && _state[g_StackPathKey].IsString() )
        return _state[g_StackPathKey].GetString();
    
    return "";
}
