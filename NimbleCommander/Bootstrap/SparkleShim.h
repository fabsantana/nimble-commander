// Copyright (C) 2020 Michael Kazakov. Subject to GNU General Public License version 3.
#pragma once

// This shim only exists to work around an issue that "#if __has_feature(modules)" works weirdly
// when compiled in Objective-C++20.
// TODO: Remove this as soon as Sparkle finally removes usage of "@import" in a release version! 
@class SUUpdater;

#ifdef __cplusplus
extern "C" {
#endif

SUUpdater *NCBootstrapSharedSUUpdaterInstance(void);
SEL NCBootstrapSUUpdaterAction(void);

#ifdef __cplusplus
}
#endif
