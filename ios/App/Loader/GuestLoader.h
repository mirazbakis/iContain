#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Where the next launch's request lives: $HOME/Library/iContain/launch.plist.
/// Built from getenv("HOME") so nothing caches the host's home folder before a
/// guest's is set.
NSString *ICLaunchRequestPath(void);

/// If a launch was requested, consumes the request and runs that guest app in this
/// process. Only returns if there was no request, or the guest couldn't be loaded;
/// in that case `error` says why and iContain's own UI should start.
void ICRunPendingGuest(int argc, char *_Nullable *_Nonnull argv, NSString *_Nullable *_Nullable error);

/// The last load failure, kept so iContain can show it after falling back to its UI.
NSString *_Nullable ICLastLaunchError(void);

NS_ASSUME_NONNULL_END
