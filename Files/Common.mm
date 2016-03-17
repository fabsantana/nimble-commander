#include "Common.h"

// REMOVE THIS WHEN CLANG WILL HAVE IT INSIDE DEFAULT LIB
bad_optional_access::~bad_optional_access() noexcept = default;

static void StringTruncateTo(NSMutableString *str, unsigned maxCharacters, ETruncationType truncationType)
{
    if ([str length] <= maxCharacters)
        return;
    
    NSRange replaceRange;
    replaceRange.length = [str length] - maxCharacters;
    
    switch (truncationType) {
        case kTruncateAtStart:
            replaceRange.location = 0;
            break;
            
        case kTruncateAtMiddle:
            replaceRange.location = maxCharacters / 2;
            break;
            
        case kTruncateAtEnd:
            replaceRange.location = maxCharacters;
            break;
            
        default:
#if DEBUG
            NSLog(@"Unknown truncation type in stringByTruncatingTo::");
#endif
            replaceRange.location = maxCharacters;
            break;
    }
    
    static NSString* sEllipsisString = nil;
    if (!sEllipsisString) {
        unichar ellipsisChar = 0x2026;
        sEllipsisString = [[NSString alloc] initWithCharacters:&ellipsisChar length:1];
    }
    
    [str replaceCharactersInRange:replaceRange withString:sEllipsisString];
}

static void StringTruncateToWidth(NSMutableString *str, float maxWidth, ETruncationType truncationType, NSDictionary *attributes)
{
    // First check if we have to truncate at all.
    if ([str sizeWithAttributes:attributes].width <= maxWidth)
        return;
    
    // Essentially, we perform a binary search on the string length
    // which fits best into maxWidth.
    
    float width = maxWidth;
    int lo = 0;
    int hi = (int)[str length];
    int mid;
    
    // Make a backup copy of the string so that we can restore it if we fail low.
    NSMutableString *backup = [str mutableCopy];
    
    while (hi >= lo) {
        mid = (hi + lo) / 2;
        
        // Cut to mid chars and calculate the resulting width
        StringTruncateTo(str, mid, truncationType);
        width = [str sizeWithAttributes:attributes].width;
        
        if (width > maxWidth) {
            // Fail high - string is still to wide. For the next cut, we can simply
            // work on the already cut string, so we don't restore using the backup.
            hi = mid - 1;
        }
        else if (width == maxWidth) {
            // Perfect match, abort the search.
            break;
        }
        else {
            // Fail low - we cut off too much. Restore the string before cutting again.
            lo = mid + 1;
            [str setString:backup];
        }
    }
    // Perform the final cut (unless this was already a perfect match).
    if (width != maxWidth)
        StringTruncateTo(str, hi, truncationType);
}

NSString *StringByTruncatingToWidth(NSString *str, float inWidth, ETruncationType truncationType, NSDictionary *attributes)
{
    if ([str sizeWithAttributes:attributes].width > inWidth)
    {
        NSMutableString *mutableCopy = [str mutableCopy];
        StringTruncateToWidth(mutableCopy, inWidth, truncationType, attributes);
        return mutableCopy;
    }
    
    return str;
}

void SyncMessageBoxUTF8(const char *_utf8_string)
{
    SyncMessageBoxNS([NSString stringWithUTF8String:_utf8_string]);
}

void SyncMessageBoxNS(NSString *_ns_string)
{
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText: _ns_string];
    
    if(dispatch_is_main_queue())
        [alert runModal];
    else
        dispatch_sync(dispatch_get_main_queue(), ^{ [alert runModal]; } );
}

@implementation NSColor (MyAdditions)

- (CGColorRef) copyCGColor
{
    return CGColorCreateCopy( self.CGColor );
}

@end

@implementation NSString(PerformanceAdditions)

- (const char *)fileSystemRepresentationSafe
{
    return self.length > 0 ? self.fileSystemRepresentation : "";
}

- (NSString*)stringByTrimmingLeadingWhitespace
{
    NSInteger i = 0;
    static NSCharacterSet *cs = [NSCharacterSet whitespaceCharacterSet];
    
    while( i < self.length && [cs characterIsMember:[self characterAtIndex:i]] )
        i++;
    return [self substringFromIndex:i];
}

+ (instancetype)stringWithUTF8StringNoCopy:(const char *)nullTerminatedCString
{
    return (NSString*) CFBridgingRelease(CFStringCreateWithBytesNoCopy(0,
                                         (UInt8*)nullTerminatedCString,
                                         strlen(nullTerminatedCString),
                                         kCFStringEncodingUTF8,
                                         false,
                                         kCFAllocatorNull));
}

+ (instancetype)stringWithUTF8StdString:(const string&)stdstring
{
    return (NSString*) CFBridgingRelease(CFStringCreateWithBytes(0,
                                                                 (UInt8*)stdstring.c_str(),
                                                                 stdstring.length(),
                                                                 kCFStringEncodingUTF8,
                                                                 false));
}

+ (instancetype)stringWithUTF8StdStringNoCopy:(const string&)stdstring
{
    return (NSString*) CFBridgingRelease(CFStringCreateWithBytesNoCopy(0,
                                                                       (UInt8*)stdstring.c_str(),
                                                                       stdstring.length(),
                                                                       kCFStringEncodingUTF8,
                                                                       false,
                                                                       kCFAllocatorNull));
}

+ (instancetype)stringWithCharactersNoCopy:(const unichar *)characters length:(NSUInteger)length
{
    return (NSString*) CFBridgingRelease(CFStringCreateWithCharactersNoCopy(0,
                                                                            characters,
                                                                            length,
                                                                            kCFAllocatorNull));
}

@end

@implementation NSPasteboard(SyntaxSugar)
+ (void) writeSingleString:(const char *)_s
{
    NSPasteboard *pb = NSPasteboard.generalPasteboard;
    [pb declareTypes:@[NSStringPboardType] owner:nil];
    [pb setString:[NSString stringWithUTF8String:_s] forType:NSStringPboardType];
}
@end

@implementation NSMenu(Hierarchical)
- (NSMenuItem *)itemWithTagHierarchical:(NSInteger)tag
{
    if(NSMenuItem *i = [self itemWithTag:tag])
        return i;
    for(NSMenuItem *it in self.itemArray)
        if(it.hasSubmenu)
            if(NSMenuItem *i = [it.submenu itemWithTagHierarchical:tag])
                return i;
    return nil;
}

- (NSMenuItem *)itemContainingItemWithTagHierarchicalRec:(NSInteger)tag withParent:(NSMenuItem*)_menu_item
{
    if([self itemWithTag:tag] != nil)
        return _menu_item;
    
    for(NSMenuItem *it in self.itemArray)
        if(it.hasSubmenu)
            if(NSMenuItem *i = [it.submenu itemContainingItemWithTagHierarchicalRec:tag withParent:it])
                return i;

    return nil;
}

- (NSMenuItem *)itemContainingItemWithTagHierarchical:(NSInteger)tag
{
    return [self itemContainingItemWithTagHierarchicalRec:tag withParent:nil];
}

- (void)performActionForItemWithTagHierarchical:(NSInteger)tag
{
    if( auto it = [self itemWithTagHierarchical:tag] )
        if( auto parent = it.menu ) {
            auto ind = [parent indexOfItem:it];
            if( ind > 0 )
                [parent performActionForItemAtIndex:ind];
        }
}

@end

CFStringRef CFStringCreateWithUTF8StringNoCopy(string_view _s) noexcept
{
    return CFStringCreateWithBytesNoCopy(0,
                                         (UInt8*)_s.data(),
                                         _s.length(),
                                         kCFStringEncodingUTF8,
                                         false,
                                         kCFAllocatorNull);
}

CFStringRef CFStringCreateWithUTF8StdStringNoCopy(const string &_s) noexcept
{
    return CFStringCreateWithBytesNoCopy(0,
                                         (UInt8*)_s.c_str(),
                                         _s.length(),
                                         kCFStringEncodingUTF8,
                                         false,
                                         kCFAllocatorNull);
}

CFStringRef CFStringCreateWithUTF8StringNoCopy(const char *_s) noexcept
{
    return CFStringCreateWithBytesNoCopy(0,
                                         (UInt8*)_s,
                                         strlen(_s),
                                         kCFStringEncodingUTF8,
                                         false,
                                         kCFAllocatorNull);
}

CFStringRef CFStringCreateWithUTF8StringNoCopy(const char *_s, size_t _len) noexcept
{
    return CFStringCreateWithBytesNoCopy(0,
                                         (UInt8*)_s,
                                         _len,
                                         kCFStringEncodingUTF8,
                                         false,
                                         kCFAllocatorNull);
}

CFStringRef CFStringCreateWithMacOSRomanStdStringNoCopy(const string &_s) noexcept
{
    return CFStringCreateWithBytesNoCopy(0,
                                         (UInt8*)_s.c_str(),
                                         _s.length(),
                                         kCFStringEncodingMacRoman,
                                         false,
                                         kCFAllocatorNull);

}

CFStringRef CFStringCreateWithMacOSRomanStringNoCopy(const char *_s) noexcept
{
    return CFStringCreateWithBytesNoCopy(0,
                                         (UInt8*)_s,
                                         strlen(_s),
                                         kCFStringEncodingMacRoman,
                                         false,
                                         kCFAllocatorNull);
}

CFStringRef CFStringCreateWithMacOSRomanStringNoCopy(const char *_s, size_t _len) noexcept
{
    return CFStringCreateWithBytesNoCopy(0,
                                         (UInt8*)_s,
                                         _len,
                                         kCFStringEncodingMacRoman,
                                         false,
                                         kCFAllocatorNull);
}

MachTimeBenchmark::MachTimeBenchmark() noexcept:
    last(machtime())
{
};

nanoseconds MachTimeBenchmark::Delta() const
{
    return machtime() - last;
}

void MachTimeBenchmark::ResetNano(const char *_msg)
{
    auto now = machtime();
    printf("%s%llu\n", _msg, (now - last).count());
    last = now;
}

void MachTimeBenchmark::ResetMicro(const char *_msg)
{
    auto now = machtime();
    printf("%s%llu\n", _msg, duration_cast<microseconds>(now - last).count());
    last = now;
}

void MachTimeBenchmark::ResetMilli(const char *_msg)
{
    auto now = machtime();
    printf("%s%llu\n", _msg, duration_cast<milliseconds>(now - last).count() );
    last = now;
}

NSError* ErrnoToNSError(int _error)
{
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:_error userInfo:nil];
}

@implementation NSFont (StringDescription)
+ (NSFont*) fontWithStringDescription:(NSString*)_description
{
    if( !_description )
        return nil;
    
    NSArray *arr = [_description componentsSeparatedByString:@","];
    if( !arr || arr.count != 2 )
        return nil;

    NSString *family = arr[0];
    NSString *size = [arr[1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return [NSFont fontWithName:family size:size.intValue];
}

- (NSString*) toStringDescription
{
    return [NSString stringWithFormat:@"%@, %s",
            self.fontName,
            to_string(int(floor(self.pointSize + 0.5))).c_str()
            ];
}

@end
