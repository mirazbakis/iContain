# How iContain works

iContain has two halves: a Rust core that prepares and signs apps, and an iOS app whose loader runs them. They meet in a C header, `core/include/icontain.h`.

```
iContain/
├── core/                    Rust core (static library, built into iContainFFI.xcframework)
│   ├── include/icontain.h   the C interface Swift sees as `import iContainFFI`
│   ├── src/install/
│   │   ├── guest.rs         importing apps, Mach-O patching, signing, .p12 certificates
│   │   ├── sign_in.rs       Apple ID sign-in with anisette server failover
│   │   ├── account.rs       certificates, App IDs, capabilities (More RAM)
│   │   ├── device.rs        device services over LocalDevVPN (location simulation)
│   │   └── …                tunnel, storage and prompt plumbing
│   └── examples/sign_test.rs  Mac-side check: import and sign an app with a .p12
├── ios/App/
│   ├── main.swift           runs a pending app before any UI, else starts iContain
│   ├── Loader/
│   │   ├── GuestLoader.m    loads an imported app into this process
│   │   └── DeviceEmulation.m  Test mode (another device's screen and traits)
│   ├── Core/                models and services (GuestStore, AppleAccount, DeviceProfiles, …)
│   ├── Features/            the four tabs: Apps, Location, Account, Settings
│   └── UI/Theme.swift       colours, Liquid Glass panels and buttons
├── site/                    the website (GitHub Pages), with ad images in site/ads/
├── marketing/               ad template (ad.html) and ready-to-paste ad copy
├── tests/Probe/             test app that shows what it sees from inside iContain
├── scripts/                 build, packaging, Simulator test and icon scripts
├── docs/                    this file, release notes, README assets
└── project.yml              XcodeGen spec (the .xcodeproj is generated, not committed)
```

## Importing an app (`core/src/install/guest.rs`)

`icontain_prepare_guest` takes an `.ipa`, `.zip`, `.app` or `.xcarchive`:

1. Unpacks or copies it, then finds the `.app` (`Payload/`, `Products/Applications/`, or anywhere shallow).
2. Removes what can't be used: the old signature, watch apps, App Store `SC_Info`.
3. For every Mach-O file: keeps only the arm64 code, and retags the platform. Simulator builds become iOS on a device, and device builds become Simulator in the Simulator.
4. Turns the main executable into a library that `dlopen` accepts:
   - `MH_EXECUTE` becomes `MH_DYLIB`
   - `__PAGEZERO` shrinks from 4 GB to one page just below `__TEXT`
   - an `LC_ID_DYLIB` is added in the header padding
   - `@executable_path` becomes `@loader_path`, so the app's own `Frameworks` folder is found instead of iContain's
5. Refuses App Store apps that are still FairPlay-encrypted, with an explanation.

## Signing

An imported app runs inside iContain's process, so iOS only checks that its code is signed **by the same team as iContain**. No provisioning profile or App ID is involved.

| Where | How |
| :-- | :-- |
| Device, Apple ID | `fetch_identity` signs in (anisette failover from `sign_in.rs`), reuses or creates iContain's development certificate, and caches it |
| Device, `.p12` | `import_p12` reads the key, the certificate and any intermediates; the team ID comes from the certificate |
| Simulator | `rehash_signatures` keeps each binary's own linker signature and recomputes its page hashes after the importer's edits |

The certificate chain is built by following issuers through the `.p12`'s intermediates, then Apple's WWDR G3 and root.

## Running an app (`ios/App/Loader/GuestLoader.m`)

`GuestStore.launch` writes `Library/iContain/launch.plist` (paths relative to iContain's home, which moves on reinstall), posts a notification and exits. On the next start, before any UI, `main.swift` calls `ICRunPendingGuest`, which:

1. points `HOME`, `CFFIXED_USER_HOME` and `TMPDIR` at the app's data folder
2. makes `+[NSBundle mainBundle]` return the app's bundle
3. `dlopen`s the app's executable
4. swaps the main `CFBundle`'s Info.plist for the app's
5. installs the location hooks and Test mode, if asked
6. jumps to the app's `main()` (from its `LC_MAIN`), which never returns

If loading fails, the reason is written to `Library/iContain/launch.log` (with the full dyld message in `launch.log.full`) and iContain's own UI starts and shows it.

## Test mode (`ios/App/Loader/DeviceEmulation.m`)

Profiles live in `ios/App/Core/DeviceProfiles.swift`. To add a device, add one line there, with points, scale, portrait safe area and corner radius.

The loader:
- gives the app's windows the profile's size, then scales and centres them in a frame window, which is hidden from the app's window lists
- answers `UIScreen` (bounds, scale) and `UIDevice` (model, idiom) for the profile
- sets the safe area through the root view controller's `additionalSafeAreaInsets`
- sets size classes and light or dark mode with `traitOverrides`

Hooks are only ever added on the class they're meant for (`UIWindow`, not `UIView`), so other views are unaffected.

## Location

- **Inside iContain:** `GuestLoader.m` replaces `CLLocationManager`'s location, updates and authorisation with the chosen coordinate.
- **Whole device:** `LocationSpoofer.swift` mounts the Developer Disk Image and uses DVT location simulation (idevice) over LocalDevVPN, the same way Xcode does.

## Testing

- `./scripts/test-sim.sh` builds iContain and Probe, then imports and opens Probe in a dedicated "iContain Test" simulator with no taps. It uses `--import-inbox` and `--open <app>`, which do the same as the `icontain://` links.
- `cargo run --example sign_test --manifest-path core/Cargo.toml -- <app.zip> <out dir> <cert.p12> [password]` checks importing and `.p12` signing on a Mac.

## Releasing

1. Set `MARKETING_VERSION` (and bump `CURRENT_PROJECT_VERSION`) in `project.yml`.
2. Write `docs/releases/vX.Y.Z.md` and add the version to `CHANGELOG.md`.
3. Run **Actions › Build IPA** with **Release** and the tag.

## Website and ads

`site/` is published by `.github/workflows/pages.yml` whenever it changes on `main` (Settings › Pages › Source: GitHub Actions). Its screenshots are in `site/assets/`. After changing `marketing/ad.html` or the screenshots, run `./scripts/render-ads.sh` to remake `site/ads/`.

## Roadmap

- Automatic relaunch into an app through LocalDevVPN (no notification tap)
- Keychain access for apps that use their own access group
- Running more than one app at a time, through app extensions
- Booting other iOS versions from an imported Simulator runtime: the runtime's own frameworks loaded in a helper process, with stand-ins for the Simulator's system services
