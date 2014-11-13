//
//  VFSArchive_Tests.m
//  Files
//
//  Created by Michael G. Kazakov on 23/10/14.
//  Copyright (c) 2014 Michael G. Kazakov. All rights reserved.
//

#import "tests_common.h"
#import "VFS.h"

static string g_Preffix = "/.FilesTestingData/archives/";

@interface VFSArchive_Tests : XCTestCase

@end

@implementation VFSArchive_Tests

- (void)testXNUSource_TAR
{
    auto host = make_shared<VFSArchiveHost>((g_Preffix+"xnu-2050.18.24.tar").c_str(), VFSNativeHost::SharedHost());

    XCTAssert( host->Open() == 0 );
    XCTAssert( host->StatTotalDirs() == 246 );
    XCTAssert( host->StatTotalRegs() == 3288 );
    XCTAssert( host->IsDirectory("/", 0, 0) == true );
    XCTAssert( host->IsDirectory("/xnu-2050.18.24/EXTERNAL_HEADERS/mach-o/x86_64", 0, 0) == true );
    XCTAssert( host->IsDirectory("/xnu-2050.18.24/EXTERNAL_HEADERS/mach-o/x86_64/", 0, 0) == true );
    XCTAssert( host->Exists("/xnu-2050.18.24/2342423/9182391273/x86_64") == false );
    
    VFSStat st;
    XCTAssert( host->Stat("/xnu-2050.18.24/bsd/security/audit/audit_bsm_socket_type.c", st, 0, 0) == 0 );
    XCTAssert( st.mode_bits.reg );
    XCTAssert( st.size == 3313 );
    
    vector<string> filenames {
        "/xnu-2050.18.24/bsd/bsm/audit_domain.h",
        "/xnu-2050.18.24/bsd/netat/ddp_rtmp.c",
        "/xnu-2050.18.24/bsd/vm/vm_unix.c",
        "/xnu-2050.18.24/iokit/bsddev/DINetBootHook.cpp",
        "/xnu-2050.18.24/iokit/Kernel/x86_64/IOAsmSupport.s",
        "/xnu-2050.18.24/iokit/Kernel/IOSubMemoryDescriptor.cpp",
        "/xnu-2050.18.24/libkern/c++/Tests/TestSerialization/test2/test2.xcodeproj/project.pbxproj",
        "/xnu-2050.18.24/libkern/zlib/intel/inffastS.s",
        "/xnu-2050.18.24/osfmk/x86_64/pmap.c",
        "/xnu-2050.18.24/pexpert/gen/device_tree.c",
        "/xnu-2050.18.24/pexpert/i386/pe_init.c",
        "/xnu-2050.18.24/pexpert/pexpert/i386/efi.h",
        "/xnu-2050.18.24/security/mac_policy.h",
        "/xnu-2050.18.24/tools/lockstat/lockstat.c"
    };

    dispatch_group_t dg = dispatch_group_create();

    // massive concurrent access to archive
    for(int i = 0; i < 1000; ++i)
        dispatch_group_async(dg, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            string fn = filenames[ rand()%filenames.size() ];
            
            VFSStat st;
            XCTAssert( host->Stat(fn.c_str(), st, 0, 0) == 0 );
            
            VFSFilePtr file;
            XCTAssert( host->CreateFile(fn.c_str(), file, nullptr) == 0);
            XCTAssert( file->Open(VFSFile::OF_Read) == 0);
            this_thread::sleep_for(5ms);
            auto d = file->ReadFile();
            XCTAssert(d.get() != nullptr);
            XCTAssert(d->size() > 0);
            XCTAssert(d->size() == st.size);
        });
    
    dispatch_group_wait(dg, DISPATCH_TIME_FOREVER);
}

// contains symlinks
- (void)testAdiumZip
{
    auto host = make_shared<VFSArchiveHost>((g_Preffix+"adium.app.zip").c_str(), VFSNativeHost::SharedHost());
    XCTAssert( host->Open() == 0 );
    
    VFSStat st;
    XCTAssert( host->Stat("/Adium.app/Contents/Info.plist", st, 0, 0) == 0 );
    XCTAssert( st.mode_bits.reg );
    XCTAssert( st.size == 6201 );
    XCTAssert( host->Stat("/Adium.app/Contents/Info.plist", st, VFSHost::F_NoFollow, 0) == 0 );
    XCTAssert( st.mode_bits.reg );
    XCTAssert( st.size == 6201 );
    
    XCTAssert( host->Stat("/Adium.app/Contents/Frameworks/Adium.framework/Adium", st, 0, 0) == 0 );
    XCTAssert( st.mode_bits.reg && !st.mode_bits.chr );
    XCTAssert( st.size == 2013068 );
    
    XCTAssert( host->Stat("/Adium.app/Contents/Frameworks/Adium.framework/Adium", st, VFSHost::F_NoFollow, 0) == 0 );
    XCTAssert( st.mode_bits.reg && st.mode_bits.chr );
    
    XCTAssert( host->IsDirectory("/Adium.app/Contents/Frameworks/Adium.framework/Headers", 0, 0) == true );
    XCTAssert( host->IsSymlink  ("/Adium.app/Contents/Frameworks/Adium.framework/Headers", VFSHost::F_NoFollow, 0) == true );
}


@end
