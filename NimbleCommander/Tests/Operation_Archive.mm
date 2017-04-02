#import <XCTest/XCTest.h>
#include <sys/stat.h>
#include <VFS/VFS.h>
#include <VFS/ArcLA.h>
#include <VFS/Native.h>
#include <NimbleCommander/Operations/Copy/FileCopyOperation.h>
#include <NimbleCommander/Operations/Compress/FileCompressOperation.h>

static const string g_Preffix = "/.FilesTestingData/archives/";
static const string g_XNU   = g_Preffix + "xnu-2050.18.24.tar";
static const string g_XNU2  = g_Preffix + "xnu-3248.20.55.tar";
static const string g_Adium = g_Preffix + "adium.app.zip";
static const string g_Angular = g_Preffix + "angular-1.4.0-beta.4.zip";
static const string g_Files = g_Preffix + "files-1.1.0(1341).zip";
static const string g_Encrypted = g_Preffix + "encrypted_archive_pass1.zip";
static const string g_FileWithXAttr = "Leopard WaR3z.icns";

static vector<VFSListingItem> FetchItems(const string& _directory_path,
                                                 const vector<string> &_filenames,
                                                 VFSHost &_host)
{
    vector<VFSListingItem> items;
    _host.FetchFlexibleListingItems(_directory_path, _filenames, 0, items, nullptr);
    return items;
}

static int VFSCompareEntries(const path& _file1_full_path,
                             const VFSHostPtr& _file1_host,
                             const path& _file2_full_path,
                             const VFSHostPtr& _file2_host,
                             int &_result)
{
    // not comparing flags, perm, times, xattrs, acls etc now
    
    VFSStat st1, st2;
    int ret;
    if((ret =_file1_host->Stat(_file1_full_path.c_str(), st1, VFSFlags::F_NoFollow, 0)) < 0)
        return ret;
    
    if((ret =_file2_host->Stat(_file2_full_path.c_str(), st2, VFSFlags::F_NoFollow, 0)) < 0)
        return ret;
    
    if((st1.mode & S_IFMT) != (st2.mode & S_IFMT)) {
        _result = -1;
        return 0;
    }
    
    if( S_ISREG(st1.mode) ) {
        if(int64_t(st1.size) - int64_t(st2.size) != 0)
            _result = int(int64_t(st1.size) - int64_t(st2.size));
    }
    else if( S_ISLNK(st1.mode) ) {
        char link1[MAXPATHLEN], link2[MAXPATHLEN];
        if( (ret = _file1_host->ReadSymlink(_file1_full_path.c_str(), link1, MAXPATHLEN, 0)) < 0)
            return ret;
        if( (ret = _file2_host->ReadSymlink(_file2_full_path.c_str(), link2, MAXPATHLEN, 0)) < 0)
            return ret;
        if( strcmp(link1, link2) != 0)
            _result = strcmp(link1, link2);
    }
    else if ( S_ISDIR(st1.mode) ) {
        _file1_host->IterateDirectoryListing(_file1_full_path.c_str(), [&](const VFSDirEnt &_dirent) {
            int ret = VFSCompareEntries( _file1_full_path / _dirent.name,
                                        _file1_host,
                                        _file2_full_path / _dirent.name,
                                        _file2_host,
                                        _result);
            if(ret != 0)
                return false;
            return true;
        });
    }
    return 0;
}


@interface Operation_Archive_Tests : XCTestCase

@end


@implementation Operation_Archive_Tests

- (void)testAdiumZip_CopyFromVFS
{
    auto dir = self.makeTmpDir;
    
    shared_ptr<VFSArchiveHost> host;
    try {
        host = make_shared<VFSArchiveHost>(g_Adium.c_str(), VFSNativeHost::SharedHost());
    } catch (VFSErrorException &e) {
        XCTAssert( e.code() == 0 );
        return;
    }
    
    FileCopyOperation *op = [FileCopyOperation alloc];
    op = [op initWithItems:FetchItems("/", {"Adium.app"}, *host)
           destinationPath:dir.native()
           destinationHost:VFSNativeHost::SharedHost()
                   options:{}];    

    __block bool finished = false;
    [op AddOnFinishHandler:^{ finished = true; }];
    [op Start];
    [self waitUntilFinish:finished];
    
    int result = 0;
    XCTAssert( VFSCompareEntries("/Adium.app", host, dir / "Adium.app", VFSNativeHost::SharedHost(), result) == 0);
    XCTAssert( result == 0 );
    XCTAssert( VFSEasyDelete(dir.c_str(), VFSNativeHost::SharedHost()) == 0);
}

- (void)testExtractedFilesSignature
{
    auto dir = self.makeTmpDir;
    
    shared_ptr<VFSArchiveHost> host;
    try {
        host = make_shared<VFSArchiveHost>(g_Files.c_str(), VFSNativeHost::SharedHost());
    } catch (VFSErrorException &e) {
        XCTAssert( e.code() == 0 );
        return;
    }
    
    FileCopyOperation *op = [FileCopyOperation alloc];
    op = [op initWithItems:FetchItems("/", {"Files.app"}, *host)
           destinationPath:dir.native()
           destinationHost:VFSNativeHost::SharedHost()
                   options:{}];
    
    __block bool finished = false;
    [op AddOnFinishHandler:^{ finished = true; }];
    [op Start];
    [self waitUntilFinish:finished];
    
    string command = "/usr/bin/codesign --verify "s + (dir/"Files.app").native();
    XCTAssert( system( command.c_str() ) == 0);
    XCTAssert( VFSEasyDelete(dir.c_str(), VFSNativeHost::SharedHost()) == 0);
}

- (void) testCompressingItemsWithBigXAttrs
{
    auto dir = self.makeTmpDir;

    
    auto item = FetchItems(g_Preffix, {g_FileWithXAttr}, *VFSNativeHost::SharedHost());
    FileCompressOperation *op = [FileCompressOperation alloc];
    op = [op initWithFiles:item
                   dstroot:dir.native()
                    dstvfs:VFSNativeHost::SharedHost()];


    __block bool finished = false;
    [op AddOnFinishHandler:^{ finished = true; }];
    [op Start];
    [self waitUntilFinish:finished];

    this_thread::sleep_for(100ms);

    shared_ptr<VFSArchiveHost> host;
    try {
        host = make_shared<VFSArchiveHost>(  (dir/op.resultArchiveFilename).c_str(), VFSNativeHost::SharedHost());
    } catch (VFSErrorException &e) {
        XCTAssert( e.code() == 0 );
        return;
    }
    
    int result = 0;
    XCTAssert( VFSCompareEntries( "/" + g_FileWithXAttr, host,
                                 g_Preffix + g_FileWithXAttr, VFSNativeHost::SharedHost(),
                                 result)
              == 0);
    XCTAssert( result == 0 );


    XCTAssert( VFSEasyDelete(dir.c_str(), VFSNativeHost::SharedHost()) == 0);
}

- (path)makeTmpDir
{
    char dir[MAXPATHLEN];
    sprintf(dir, "%s" "info.filesmanager.files" ".tmp.XXXXXX", NSTemporaryDirectory().fileSystemRepresentation);
    XCTAssert( mkdtemp(dir) != nullptr );
    return dir;
}

- (void) waitUntilFinish:(volatile bool&)_finished
{
    microseconds sleeped = 0us, sleep_tresh = 60s;
    while (!_finished)
    {
        this_thread::sleep_for(100us);
        sleeped += 100us;
        XCTAssert( sleeped < sleep_tresh);
        if(sleeped > sleep_tresh)
            break;
    }
}

@end
