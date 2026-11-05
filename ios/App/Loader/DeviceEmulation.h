#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Test mode: makes the guest believe it runs on another device and/or in a fixed
/// appearance. `device` holds the keys DeviceProfile.request writes (or is nil to
/// keep this device); `appearance` is "light", "dark" or nil. Call before the
/// guest's main().
void ICInstallDeviceEmulation(NSDictionary *_Nullable device, NSString *_Nullable appearance);

NS_ASSUME_NONNULL_END
