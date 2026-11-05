// Test mode for guest apps.
//
// The guest's windows are given the emulated device's size, then scaled to fit and
// centred on the real screen inside a device frame. What the app can ask about the
// device is answered for the emulated one:
//   UIScreen       bounds, nativeBounds, scale, nativeScale
//   UIDevice       model, localizedModel, userInterfaceIdiom
//   safe area      the root view controller's additionalSafeAreaInsets, so it reaches
//                  every view the way UIKit passes safe areas down
//   traits         size classes and light/dark appearance, via traitOverrides
// The frame behind the app is its own window, hidden from the app's window lists.
// Hardware the phone doesn't have (chip, RAM, sensors) isn't faked.

#import "DeviceEmulation.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static BOOL gEmulating;
static CGSize gSize;            // portrait, points
static CGFloat gScale;
static UIEdgeInsets gSafe;      // portrait
static CGFloat gCorner;
static BOOL gPad;
static NSString *gModel;
static NSString *gName;
static UIUserInterfaceStyle gStyle = UIUserInterfaceStyleUnspecified;

static IMP gOrigScreenBounds, gOrigScreenScale, gOrigWindowSetFrame, gOrigWindowLayout;
static IMP gOrigSceneWindows, gOrigAppWindows;
static BOOL gFitting;
static const void *kICBackdropKey = &kICBackdropKey;
static const void *kICIsBackdropKey = &kICIsBackdropKey;

static CGRect ICRealScreenBounds(void) {
    UIScreen *screen = UIScreen.mainScreen;
    return ((CGRect (*)(id, SEL))gOrigScreenBounds)(screen, @selector(bounds));
}

/// Emulated size in the current orientation (follows the real screen's).
static CGSize ICCurrentSize(void) {
    CGRect real = ICRealScreenBounds();
    BOOL landscape = real.size.width > real.size.height;
    return landscape ? CGSizeMake(gSize.height, gSize.width) : gSize;
}

// MARK: UIScreen

static CGRect IC_screenBounds(id self, SEL _cmd) {
    if (self != UIScreen.mainScreen) return ((CGRect (*)(id, SEL))gOrigScreenBounds)(self, _cmd);
    CGSize size = ICCurrentSize();
    return CGRectMake(0, 0, size.width, size.height);
}

static CGRect IC_screenNativeBounds(id self, SEL _cmd) {
    return CGRectMake(0, 0, gSize.width * gScale, gSize.height * gScale);
}

static CGFloat IC_screenScale(id self, SEL _cmd) {
    if (self != UIScreen.mainScreen) return ((CGFloat (*)(id, SEL))gOrigScreenScale)(self, _cmd);
    return gScale;
}

// MARK: UIDevice

static NSString *IC_deviceModel(id self, SEL _cmd) { return gModel; }
static UIUserInterfaceIdiom IC_deviceIdiom(id self, SEL _cmd) {
    return gPad ? UIUserInterfaceIdiomPad : UIUserInterfaceIdiomPhone;
}

// MARK: UIWindow

static BOOL gCreatingBackdrop;

static BOOL ICIsFlaggedBackdrop(UIWindow *window) {
    return [objc_getAssociatedObject(window, kICIsBackdropKey) boolValue];
}

static BOOL ICIsBackdrop(UIWindow *window) {
    return gCreatingBackdrop || ICIsFlaggedBackdrop(window);
}

/// Only the app's own windows are emulated, not alerts or system overlays above them.
static BOOL ICShouldEmulate(UIWindow *window) {
    return !ICIsBackdrop(window) && window.windowLevel <= UIWindowLevelNormal + 1;
}

/// The safe area the emulated device has in the current orientation.
static UIEdgeInsets ICTargetSafeArea(void) {
    CGSize size = ICCurrentSize();
    if (size.width > size.height) {
        // Landscape: the notch side gets the top inset, the Home indicator stays at the bottom.
        return UIEdgeInsetsMake(0, gSafe.top, gSafe.bottom > 0 ? 21 : 0, gSafe.top);
    }
    return gSafe;
}

/// The window sits away from the real notch, so its own insets are about zero; the
/// root view controller makes up the difference, and UIKit passes it to every view.
static void ICApplySafeArea(UIWindow *window) {
    UIViewController *root = window.rootViewController;
    if (!root) return;
    UIEdgeInsets want = ICTargetSafeArea(), have = window.safeAreaInsets;
    UIEdgeInsets extra = UIEdgeInsetsMake(MAX(0, want.top - have.top), MAX(0, want.left - have.left),
                                          MAX(0, want.bottom - have.bottom), MAX(0, want.right - have.right));
    if (!UIEdgeInsetsEqualToEdgeInsets(root.additionalSafeAreaInsets, extra)) root.additionalSafeAreaInsets = extra;
}

/// Keeps the frame window out of the lists apps search for "their" window.
static NSArray<UIWindow *> *ICWithoutBackdrops(NSArray<UIWindow *> *windows) {
    NSIndexSet *keep = [windows indexesOfObjectsPassingTest:^BOOL(UIWindow *w, NSUInteger i, BOOL *stop) {
        return !ICIsFlaggedBackdrop(w);
    }];
    return keep.count == windows.count ? windows : [windows objectsAtIndexes:keep];
}

static NSArray *IC_sceneWindows(id self, SEL _cmd) {
    return ICWithoutBackdrops(((NSArray *(*)(id, SEL))gOrigSceneWindows)(self, _cmd));
}

static NSArray *IC_appWindows(id self, SEL _cmd) {
    return ICWithoutBackdrops(((NSArray *(*)(id, SEL))gOrigAppWindows)(self, _cmd));
}

/// The frame behind the guest: a dark rounded device outline with its name.
static UIWindow *ICBackdropFor(UIWindow *guest) {
    UIWindow *backdrop = objc_getAssociatedObject(guest, kICBackdropKey);
    if (backdrop || !guest.windowScene) return backdrop;
    gCreatingBackdrop = YES;
    backdrop = [[UIWindow alloc] initWithWindowScene:guest.windowScene];
    objc_setAssociatedObject(backdrop, kICIsBackdropKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    gCreatingBackdrop = NO;
    backdrop.windowLevel = UIWindowLevelNormal - 1;
    backdrop.userInteractionEnabled = NO;
    UIViewController *controller = [UIViewController new];
    controller.view.backgroundColor = [UIColor colorWithRed:0.08 green:0.09 blue:0.13 alpha:1];
    UIView *bezel = [UIView new];
    bezel.tag = 7001;
    bezel.backgroundColor = UIColor.blackColor;
    bezel.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
    bezel.layer.borderWidth = 1;
    [controller.view addSubview:bezel];
    UILabel *label = [UILabel new];
    label.tag = 7002;
    label.text = [NSString stringWithFormat:@"%@ · iContain Test mode", gName];
    label.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    label.textColor = [UIColor colorWithWhite:1 alpha:0.55];
    label.textAlignment = NSTextAlignmentCenter;
    [controller.view addSubview:label];
    backdrop.rootViewController = controller;
    backdrop.hidden = NO;
    objc_setAssociatedObject(guest, kICBackdropKey, backdrop, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return backdrop;
}

/// Gives the guest window the emulated size, scaled to fit and centred.
static void ICFit(UIWindow *window) {
    if (!ICShouldEmulate(window) || gFitting) return;
    gFitting = YES;
    CGRect real = ICRealScreenBounds();
    if (window.windowScene) real = window.windowScene.coordinateSpace.bounds;
    CGSize size = ICCurrentSize();
    CGFloat margin = 28;
    CGFloat fit = MIN((real.size.width - margin) / size.width, (real.size.height - margin * 2) / size.height);
    CGFloat scale = MIN(1, fit);
    CGPoint center = CGPointMake(CGRectGetMidX(real), CGRectGetMidY(real) - 6);

    window.transform = CGAffineTransformIdentity;
    window.bounds = CGRectMake(0, 0, size.width, size.height);
    window.center = center;
    window.transform = CGAffineTransformMakeScale(scale, scale);
    window.layer.cornerRadius = gCorner;
    window.layer.cornerCurve = kCACornerCurveContinuous;
    window.layer.masksToBounds = gCorner > 0;

    if (@available(iOS 17.0, *)) {
        BOOL landscape = size.width > size.height;
        window.traitOverrides.horizontalSizeClass = (gPad || (landscape && size.width >= 900)) ? UIUserInterfaceSizeClassRegular : UIUserInterfaceSizeClassCompact;
        window.traitOverrides.verticalSizeClass = (gPad || !landscape) ? UIUserInterfaceSizeClassRegular : UIUserInterfaceSizeClassCompact;
        if (gStyle != UIUserInterfaceStyleUnspecified) window.traitOverrides.userInterfaceStyle = gStyle;
    }

    UIWindow *backdrop = ICBackdropFor(window);
    if (backdrop) {
        UIView *root = backdrop.rootViewController.view;
        UIView *bezel = [root viewWithTag:7001];
        UILabel *label = (UILabel *)[root viewWithTag:7002];
        CGFloat w = size.width * scale, h = size.height * scale, border = 7;
        bezel.frame = CGRectMake(center.x - w / 2 - border, center.y - h / 2 - border, w + border * 2, h + border * 2);
        bezel.layer.cornerRadius = gCorner > 0 ? gCorner * scale + border : 10;
        bezel.layer.cornerCurve = kCACornerCurveContinuous;
        label.frame = CGRectMake(0, CGRectGetMaxY(bezel.frame) + 4, real.size.width, 16);
    }
    ICApplySafeArea(window);
    gFitting = NO;
}

static void IC_windowSetFrame(UIWindow *self, SEL _cmd, CGRect frame) {
    if (!ICShouldEmulate(self) || gFitting) {
        // Our own resizing (if UIKit routes it through setFrame:) and other windows.
        ((void (*)(id, SEL, CGRect))gOrigWindowSetFrame)(self, _cmd, frame);
        return;
    }
    // UIKit sizes windows to the scene; keep ours at the emulated size instead.
    ICFit(self);
}

static void IC_windowLayout(UIWindow *self, SEL _cmd) {
    ((void (*)(id, SEL))gOrigWindowLayout)(self, _cmd);
    if (!ICShouldEmulate(self) || gFitting) return;
    if (!CGSizeEqualToSize(self.bounds.size, ICCurrentSize())) ICFit(self);
    else ICApplySafeArea(self);   // the root view controller may have been set since
}

// Appearance only, when the device isn't emulated.
static void IC_windowLayoutStyleOnly(UIWindow *self, SEL _cmd) {
    ((void (*)(id, SEL))gOrigWindowLayout)(self, _cmd);
    if (@available(iOS 17.0, *)) {
        if (self.traitOverrides.userInterfaceStyle != gStyle) self.traitOverrides.userInterfaceStyle = gStyle;
    }
}

/// Replaces `selector` on `cls` only. If `cls` inherits it (say UIWindow from
/// UIView), the replacement is added as an override instead of changing the
/// superclass, which would affect every view. Returns the implementation to call on.
static IMP ICSwap(Class cls, SEL selector, IMP replacement) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NULL;
    IMP original = method_getImplementation(method);
    if (!class_addMethod(cls, selector, replacement, method_getTypeEncoding(method))) {
        method_setImplementation(method, replacement);
    }
    return original;
}

void ICInstallDeviceEmulation(NSDictionary *device, NSString *appearance) {
    if ([appearance isEqualToString:@"dark"]) gStyle = UIUserInterfaceStyleDark;
    if ([appearance isEqualToString:@"light"]) gStyle = UIUserInterfaceStyleLight;

    if (![device isKindOfClass:NSDictionary.class]) {
        if (gStyle != UIUserInterfaceStyleUnspecified) {
            gOrigWindowLayout = ICSwap(UIWindow.class, @selector(layoutSubviews), (IMP)IC_windowLayoutStyleOnly);
        }
        return;
    }

    gEmulating = YES;
    gSize = CGSizeMake([device[@"width"] doubleValue], [device[@"height"] doubleValue]);
    gScale = [device[@"scale"] doubleValue] ?: 2;
    gSafe = UIEdgeInsetsMake([device[@"safeTop"] doubleValue], 0, [device[@"safeBottom"] doubleValue], 0);
    gCorner = [device[@"corner"] doubleValue];
    gPad = [device[@"idiom"] isEqualToString:@"pad"];
    gModel = device[@"model"] ?: (gPad ? @"iPad" : @"iPhone");
    gName = device[@"name"] ?: gModel;

    Class screen = UIScreen.class;
    gOrigScreenBounds = ICSwap(screen, @selector(bounds), (IMP)IC_screenBounds);
    ICSwap(screen, @selector(nativeBounds), (IMP)IC_screenNativeBounds);
    gOrigScreenScale = ICSwap(screen, @selector(scale), (IMP)IC_screenScale);
    ICSwap(screen, @selector(nativeScale), (IMP)IC_screenScale);

    Class uiDevice = UIDevice.class;
    ICSwap(uiDevice, @selector(model), (IMP)IC_deviceModel);
    ICSwap(uiDevice, @selector(localizedModel), (IMP)IC_deviceModel);
    ICSwap(uiDevice, @selector(userInterfaceIdiom), (IMP)IC_deviceIdiom);

    gOrigSceneWindows = ICSwap(UIWindowScene.class, @selector(windows), (IMP)IC_sceneWindows);
    gOrigAppWindows = ICSwap(UIApplication.class, NSSelectorFromString(@"windows"), (IMP)IC_appWindows);

    Class window = UIWindow.class;
    gOrigWindowSetFrame = ICSwap(window, @selector(setFrame:), (IMP)IC_windowSetFrame);
    gOrigWindowLayout = ICSwap(window, @selector(layoutSubviews), (IMP)IC_windowLayout);
}
