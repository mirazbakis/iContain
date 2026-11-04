// Runs an imported app ("guest") inside iContain's own process.
//
// iContain's main() checks for a launch request before any UI starts. If there is
// one, it:
//   1. points HOME, CFFIXED_USER_HOME and TMPDIR at the guest's own data folder,
//   2. makes +[NSBundle mainBundle] return the guest's bundle,
//   3. dlopens the guest's executable (iContain's importer turned it into a
//      library: see core/src/install/guest.rs),
//   4. swaps the main CFBundle's Info.plist for the guest's, so UIKit reads the
//      guest's scenes, launch screen and settings,
//   5. optionally fakes Core Location,
//   6. jumps to the guest's own main() (from its LC_MAIN), which never returns.
// Getting back to iContain means closing the guest from the app switcher; the next
// launch has no request and shows iContain.

#import "GuestLoader.h"

#import <CoreLocation/CoreLocation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <objc/runtime.h>
#include <limits.h>
#include <stdlib.h>

static NSString *gLastError;

NSString *ICLastLaunchError(void) {
    return gLastError;
}

static NSString *ICHostHome(void) {
    const char *home = getenv("HOME");
    return home ? @(home) : NSHomeDirectory();
}

NSString *ICLaunchRequestPath(void) {
    return [ICHostHome() stringByAppendingPathComponent:@"Library/iContain/launch.plist"];
}

static NSString *ICErrorPath(void) {
    return [ICHostHome() stringByAppendingPathComponent:@"Library/iContain/last-error.txt"];
}

// MARK: - Main bundle

static NSBundle *gGuestBundle;
static IMP gOriginalMainBundle;

static NSBundle *IC_mainBundle(id self, SEL _cmd) {
    return gGuestBundle;
}

static void ICOverrideMainBundle(NSBundle *guest) {
    gGuestBundle = guest;
    Method method = class_getClassMethod(NSBundle.class, @selector(mainBundle));
    gOriginalMainBundle = method_setImplementation(method, (IMP)IC_mainBundle);
}

static void ICRestoreMainBundle(void) {
    if (!gOriginalMainBundle) return;
    Method method = class_getClassMethod(NSBundle.class, @selector(mainBundle));
    method_setImplementation(method, gOriginalMainBundle);
    gOriginalMainBundle = NULL;
    gGuestBundle = nil;
}

/// CFBundleGetValueForInfoDictionaryKey(CFBundleGetMainBundle(), …) and friends read
/// this dictionary, not NSBundle, so its contents are replaced in place.
static void ICReplaceMainInfoDictionary(NSDictionary *info) {
    CFDictionaryRef dict = CFBundleGetInfoDictionary(CFBundleGetMainBundle());
    if (!dict || !info) return;
    @try {
        NSMutableDictionary *mutable = (__bridge NSMutableDictionary *)dict;
        [mutable removeAllObjects];
        [mutable addEntriesFromDictionary:info];
    } @catch (NSException *exception) {
        // Immutable on this iOS version: NSBundle still answers for the guest.
    }
}

// MARK: - Simulated location

static CLLocationCoordinate2D gFakeCoordinate;
static double gFakeAltitude;
static const void *kICLocationTimerKey = &kICLocationTimerKey;

static CLLocation *ICFakeLocation(void) {
    return [[CLLocation alloc] initWithCoordinate:gFakeCoordinate
                                         altitude:gFakeAltitude
                               horizontalAccuracy:5
                                 verticalAccuracy:5
                                           course:-1
                                            speed:0
                                        timestamp:NSDate.date];
}

static void ICDeliverLocation(CLLocationManager *manager) {
    id<CLLocationManagerDelegate> delegate = manager.delegate;
    if ([delegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
        [delegate locationManager:manager didUpdateLocations:@[ICFakeLocation()]];
    }
}

static void ICDeliverAuthorization(CLLocationManager *manager) {
    id<CLLocationManagerDelegate> delegate = manager.delegate;
    if ([delegate respondsToSelector:@selector(locationManagerDidChangeAuthorization:)]) {
        [delegate locationManagerDidChangeAuthorization:manager];
    } else if ([delegate respondsToSelector:@selector(locationManager:didChangeAuthorizationStatus:)]) {
        [delegate locationManager:manager didChangeAuthorizationStatus:kCLAuthorizationStatusAuthorizedWhenInUse];
    }
}

static CLLocation *IC_location(id self, SEL _cmd) {
    return ICFakeLocation();
}

static void IC_startUpdating(CLLocationManager *self, SEL _cmd) {
    __weak CLLocationManager *weakSelf = self;
    dispatch_source_t timer = objc_getAssociatedObject(self, kICLocationTimerKey);
    if (timer) return;
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), NSEC_PER_SEC, NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(timer, ^{
        CLLocationManager *manager = weakSelf;
        if (manager) ICDeliverLocation(manager);
    });
    objc_setAssociatedObject(self, kICLocationTimerKey, timer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_resume(timer);
}

static void IC_stopUpdating(CLLocationManager *self, SEL _cmd) {
    dispatch_source_t timer = objc_getAssociatedObject(self, kICLocationTimerKey);
    if (timer) dispatch_source_cancel(timer);
    objc_setAssociatedObject(self, kICLocationTimerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void IC_requestLocation(CLLocationManager *self, SEL _cmd) {
    __weak CLLocationManager *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        CLLocationManager *manager = weakSelf;
        if (manager) ICDeliverLocation(manager);
    });
}

static void IC_requestAuthorization(CLLocationManager *self, SEL _cmd) {
    __weak CLLocationManager *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        CLLocationManager *manager = weakSelf;
        if (manager) ICDeliverAuthorization(manager);
    });
}

static CLAuthorizationStatus IC_authorizationStatus(id self, SEL _cmd) {
    return kCLAuthorizationStatusAuthorizedWhenInUse;
}

static CLAccuracyAuthorization IC_accuracy(id self, SEL _cmd) {
    return CLAccuracyAuthorizationFullAccuracy;
}

static BOOL IC_yes(id self, SEL _cmd) {
    return YES;
}

static void ICReplace(Class cls, SEL selector, IMP implementation, BOOL classMethod) {
    Method method = classMethod ? class_getClassMethod(cls, selector) : class_getInstanceMethod(cls, selector);
    if (method) method_setImplementation(method, implementation);
}

static void ICInstallLocationHooks(double latitude, double longitude, double altitude) {
    gFakeCoordinate = CLLocationCoordinate2DMake(latitude, longitude);
    gFakeAltitude = altitude;
    Class cls = CLLocationManager.class;
    ICReplace(cls, @selector(location), (IMP)IC_location, NO);
    ICReplace(cls, @selector(startUpdatingLocation), (IMP)IC_startUpdating, NO);
    ICReplace(cls, @selector(startMonitoringSignificantLocationChanges), (IMP)IC_startUpdating, NO);
    ICReplace(cls, @selector(stopUpdatingLocation), (IMP)IC_stopUpdating, NO);
    ICReplace(cls, @selector(stopMonitoringSignificantLocationChanges), (IMP)IC_stopUpdating, NO);
    ICReplace(cls, @selector(requestLocation), (IMP)IC_requestLocation, NO);
    ICReplace(cls, @selector(requestWhenInUseAuthorization), (IMP)IC_requestAuthorization, NO);
    ICReplace(cls, @selector(requestAlwaysAuthorization), (IMP)IC_requestAuthorization, NO);
    ICReplace(cls, @selector(authorizationStatus), (IMP)IC_authorizationStatus, NO);
    ICReplace(cls, @selector(authorizationStatus), (IMP)IC_authorizationStatus, YES);
    ICReplace(cls, @selector(accuracyAuthorization), (IMP)IC_accuracy, NO);
    ICReplace(cls, @selector(locationServicesEnabled), (IMP)IC_yes, YES);
}

// MARK: - Loading

static const struct mach_header_64 *ICFindImage(const char *path) {
    char wanted[PATH_MAX];
    if (!realpath(path, wanted)) strlcpy(wanted, path, sizeof wanted);
    for (uint32_t i = _dyld_image_count(); i-- > 0;) {
        const char *name = _dyld_get_image_name(i);
        char found[PATH_MAX];
        if (!name) continue;
        if (strcmp(name, wanted) == 0 || (realpath(name, found) && strcmp(found, wanted) == 0)) {
            return (const struct mach_header_64 *)_dyld_get_image_header(i);
        }
    }
    return NULL;
}

static uint64_t ICEntryOffset(const struct mach_header_64 *header) {
    const uint8_t *cursor = (const uint8_t *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmd == LC_MAIN) {
            return ((const struct entry_point_command *)command)->entryoff;
        }
        cursor += command->cmdsize;
    }
    return 0;
}

static NSString *ICLogPath(void) {
    return [ICHostHome() stringByAppendingPathComponent:@"Library/iContain/launch.log"];
}

/// dyld lists every path it tried; the last one (the real file) holds the reason.
static NSString *ICShortDyldError(NSString *full) {
    NSRange tried = [full rangeOfString:@"tried: "];
    if (tried.location == NSNotFound) return full;
    NSArray<NSString *> *parts = [[full substringFromIndex:NSMaxRange(tried)] componentsSeparatedByString:@"', '"];
    NSString *last = parts.lastObject ?: full;
    NSRange quote = [last rangeOfString:@"' (" options:NSBackwardsSearch];
    if (quote.location != NSNotFound) {
        last = [last substringFromIndex:quote.location + 3];
        if ([last hasSuffix:@")"]) last = [last substringToIndex:last.length - 1];
    }
    return last;
}

static void ICFail(NSString *message, NSString *_Nullable *_Nullable error) {
    gLastError = message;
    NSLog(@"[iContain] %@", message);
    [message writeToFile:ICErrorPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [message writeToFile:ICLogPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    if (error) *error = message;
}

typedef int (*ICGuestMain)(int, char **, char **, char **);
extern char **environ;

void ICRunPendingGuest(int argc, char *_Nullable *_Nonnull argv, NSString *_Nullable *_Nullable error) {
    NSString *requestPath = ICLaunchRequestPath();
    NSDictionary *request = [NSDictionary dictionaryWithContentsOfFile:requestPath];
    if (!request) return;
    [NSFileManager.defaultManager removeItemAtPath:requestPath error:nil];
    [NSFileManager.defaultManager removeItemAtPath:ICErrorPath() error:nil];

    // Paths are relative to iContain's home, which moves when iContain is reinstalled.
    NSString *home = ICHostHome();
    NSString *appPath = request[@"appPath"] ? [home stringByAppendingPathComponent:request[@"appPath"]] : nil;
    NSString *dataPath = request[@"dataPath"] ? [home stringByAppendingPathComponent:request[@"dataPath"]] : nil;
    NSBundle *guest = appPath ? [NSBundle bundleWithPath:appPath] : nil;
    NSString *executable = guest.executablePath;
    if (!guest || !executable || !dataPath) {
        ICFail(@"The app's files are missing. Delete it from iContain and import it again.", error);
        return;
    }

    // 1. The guest's own data folder.
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *sub in @[@"Documents", @"Library/Preferences", @"Library/Caches", @"Library/Application Support", @"tmp"]) {
        [fm createDirectoryAtPath:[dataPath stringByAppendingPathComponent:sub] withIntermediateDirectories:YES attributes:nil error:nil];
    }
    NSString *oldHome = ICHostHome();
    const char *oldTmp = getenv("TMPDIR");
    NSString *savedTmp = oldTmp ? @(oldTmp) : nil;
    setenv("HOME", dataPath.fileSystemRepresentation, 1);
    setenv("CFFIXED_USER_HOME", dataPath.fileSystemRepresentation, 1);
    setenv("TMPDIR", [[dataPath stringByAppendingPathComponent:@"tmp"] stringByAppendingString:@"/"].fileSystemRepresentation, 1);

    // 2-3. Main bundle, then load.
    ICOverrideMainBundle(guest);
    void *handle = dlopen(executable.fileSystemRepresentation, RTLD_LAZY | RTLD_GLOBAL);
    const struct mach_header_64 *header = handle ? ICFindImage(executable.fileSystemRepresentation) : NULL;
    uint64_t entry = header ? ICEntryOffset(header) : 0;
    if (!handle || !header || !entry) {
        const char *reason = dlerror();
        ICRestoreMainBundle();
        setenv("HOME", oldHome.fileSystemRepresentation, 1);
        unsetenv("CFFIXED_USER_HOME");
        if (savedTmp) setenv("TMPDIR", savedTmp.fileSystemRepresentation, 1);
        NSString *detail = reason ? @(reason) : (!header ? @"iContain couldn't find the loaded app." : @"The app has no entry point.");
        NSString *name = guest.infoDictionary[@"CFBundleName"] ?: @"The app";
        NSLog(@"[iContain] full loader error: %@", detail);
        [detail writeToFile:[ICLogPath() stringByAppendingString:@".full"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        ICFail([NSString stringWithFormat:@"%@ couldn't start: %@", name, ICShortDyldError(detail)], error);
        return;
    }

    // 4. Info.plist, for code that asks CFBundle.
    ICReplaceMainInfoDictionary(guest.infoDictionary);

    // 5. Location.
    NSDictionary *location = request[@"location"];
    if ([location isKindOfClass:NSDictionary.class]) {
        ICInstallLocationHooks([location[@"latitude"] doubleValue],
                               [location[@"longitude"] doubleValue],
                               [location[@"altitude"] doubleValue]);
    }

    // 6. Hand over. The guest's main() calls UIApplicationMain and never returns.
    ICGuestMain guestMain = (ICGuestMain)((const uint8_t *)header + entry);
    char *guestArgv[] = { (char *)executable.fileSystemRepresentation, NULL };
    char *apple[] = { NULL };
    exit(guestMain(1, guestArgv, environ, apple));
}
