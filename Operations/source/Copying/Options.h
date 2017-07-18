#pragma once

namespace nc::ops {

struct FileCopyOperationOptions
{
    enum class ChecksumVerification : char
    {
        Never       = 0,
        WhenMoves   = 1,
        Always      = 2
    };
    
    enum class ExistBehavior : char
    {
        Ask             = 0, // default
        SkipAll         = 1, // silently skips any copiyng file, if target exists
        OverwriteAll    = 2, // overwrites existings target
        OverwriteOld    = 3, // overwrites existings target only if date is less, skip otherwise
        AppendAll       = 4  // appends to target
    };
    
    bool docopy = true;      // it it false then operation will do renaming/moving
    bool preserve_symlinks = true;
    bool copy_xattrs = true;
    bool copy_file_times = true;
    bool copy_unix_flags = true;
    bool copy_unix_owners = true;
    ChecksumVerification    verification = ChecksumVerification::Never;
    ExistBehavior           exist_behavior = ExistBehavior::Ask;
};

}
