// Guest apps: apps that run inside iContain rather than being installed on iOS.
//
// Import (`icontain_prepare_guest`):
//   1. Unpack an .ipa / .zip, or copy an .app / .xcarchive folder.
//   2. Find the .app (Payload/, Products/Applications/ or anywhere shallow).
//   3. Thin every Mach-O to arm64 and retag its platform (iOS Simulator builds become
//      iOS when running on a device, and the other way round in the Simulator).
//   4. Turn the main executable into a library iContain can dlopen: MH_DYLIB, a one-page
//      __PAGEZERO, an LC_ID_DYLIB, and @executable_path rewritten to @loader_path so the
//      guest's own Frameworks folder is found instead of iContain's.
//
// Signing (`icontain_sign_guest`):
//   A guest is loaded into iContain's own process, so iOS only checks that its code is
//   signed by the same team as iContain. No provisioning profile or App ID is needed.
//   The certificate comes from the Apple ID (isideload, the same sign-in and anisette
//   failover as installs) and is cached so later imports sign offline. In the
//   Simulator, guests are signed ad hoc.

use super::*;

use apple_codesign_quick::{sign_bundle, BundleSigningSettings, CmsSigner, RustCryptoCmsSigner};
use isideload::sideload::cert_identity::{APPLE_ROOT, APPLE_WWDR_G3_CERTIFICATE_DER};
use rsa::pkcs8::{DecodePrivateKey, EncodePrivateKey};
use rsa::RsaPrivateKey;
use x509_cert::der::{Decode, Encode};
use x509_cert::Certificate;

// MARK: - Mach-O constants

const MH_MAGIC_64: u32 = 0xfeed_facf;
const FAT_MAGIC: u32 = 0xcafe_babe;
const FAT_MAGIC_64: u32 = 0xcafe_babf;
const CPU_TYPE_ARM64: u32 = 0x0100_000c;
const MH_DYLIB: u32 = 6;
const MH_NO_REEXPORTED_DYLIBS: u32 = 0x0010_0000;

const LC_SEGMENT_64: u32 = 0x19;
const LC_ID_DYLIB: u32 = 0x0d;
const LC_LOAD_DYLIB: u32 = 0x0c;
const LC_LOAD_WEAK_DYLIB: u32 = 0x8000_0018;
const LC_REEXPORT_DYLIB: u32 = 0x8000_001f;
const LC_LAZY_LOAD_DYLIB: u32 = 0x20;
const LC_RPATH: u32 = 0x8000_001c;
const LC_BUILD_VERSION: u32 = 0x32;
const LC_ENCRYPTION_INFO_64: u32 = 0x2c;
const LC_MAIN: u32 = 0x8000_0028;

pub(super) const PLATFORM_IOS: u32 = 2;
pub(super) const PLATFORM_IOS_SIMULATOR: u32 = 7;

fn rd32(b: &[u8], o: usize) -> u32 {
    u32::from_le_bytes(b[o..o + 4].try_into().unwrap())
}
fn wr32(b: &mut [u8], o: usize, v: u32) {
    b[o..o + 4].copy_from_slice(&v.to_le_bytes());
}
fn rd64(b: &[u8], o: usize) -> u64 {
    u64::from_le_bytes(b[o..o + 8].try_into().unwrap())
}
fn wr64(b: &mut [u8], o: usize, v: u64) {
    b[o..o + 8].copy_from_slice(&v.to_le_bytes());
}
fn rdbe32(b: &[u8], o: usize) -> u32 {
    u32::from_be_bytes(b[o..o + 4].try_into().unwrap())
}
fn rdbe64(b: &[u8], o: usize) -> u64 {
    u64::from_be_bytes(b[o..o + 8].try_into().unwrap())
}

#[derive(Default, Debug)]
pub(super) struct MachInfo {
    /// Platform before retagging (2 iOS, 7 iOS Simulator, 0 unknown).
    pub platform: u32,
    pub encrypted: bool,
    pub has_main: bool,
}

/// Returns the arm64 slice of a fat file, the file itself if it's thin 64-bit, or
/// None if it isn't a Mach-O. Err if it's a Mach-O without arm64 code.
fn thin_arm64(data: &[u8]) -> Result<Option<Vec<u8>>, String> {
    if data.len() < 8 {
        return Ok(None);
    }
    let le = rd32(data, 0);
    if le == MH_MAGIC_64 {
        let cpu = rd32(data, 4);
        return if cpu == CPU_TYPE_ARM64 {
            Ok(Some(data.to_vec()))
        } else {
            Err("has no arm64 code (it's an Intel build)".into())
        };
    }
    let be = rdbe32(data, 0);
    if be != FAT_MAGIC && be != FAT_MAGIC_64 {
        return Ok(None);
    }
    let count = rdbe32(data, 4) as usize;
    // Java class files share 0xcafebabe; they have a large "count" (their version).
    if count == 0 || count > 32 {
        return Ok(None);
    }
    let entry = if be == FAT_MAGIC { 20 } else { 32 };
    let mut fallback = None;
    for i in 0..count {
        let o = 8 + i * entry;
        if o + entry > data.len() {
            break;
        }
        let cpu = rdbe32(data, o);
        let sub = rdbe32(data, o + 4) & 0xff;
        let (off, size) = if be == FAT_MAGIC {
            (rdbe32(data, o + 8) as usize, rdbe32(data, o + 12) as usize)
        } else {
            (rdbe64(data, o + 8) as usize, rdbe64(data, o + 16) as usize)
        };
        if cpu != CPU_TYPE_ARM64 || off + size > data.len() {
            continue;
        }
        let slice = data[off..off + size].to_vec();
        // Plain arm64 first; arm64e only if that's all there is.
        if sub == 0 {
            return Ok(Some(slice));
        }
        fallback.get_or_insert(slice);
    }
    fallback.map(Some).ok_or_else(|| "has no arm64 code (it's an Intel build)".into())
}

struct Command {
    offset: usize,
    cmd: u32,
    size: usize,
}

fn commands(b: &[u8]) -> Result<Vec<Command>, String> {
    if b.len() < 32 || rd32(b, 0) != MH_MAGIC_64 {
        return Err("not a 64-bit Mach-O".into());
    }
    let ncmds = rd32(b, 16) as usize;
    let mut out = Vec::with_capacity(ncmds);
    let mut o = 32;
    for _ in 0..ncmds {
        if o + 8 > b.len() {
            return Err("load commands run past the end of the file".into());
        }
        let size = rd32(b, o + 4) as usize;
        if size < 8 || o + size > b.len() {
            return Err("malformed load command".into());
        }
        out.push(Command { offset: o, cmd: rd32(b, o), size });
        o += size;
    }
    Ok(out)
}

fn c_string_at(b: &[u8], start: usize, end: usize) -> String {
    let raw = &b[start..end];
    let len = raw.iter().position(|&c| c == 0).unwrap_or(raw.len());
    String::from_utf8_lossy(&raw[..len]).into_owned()
}

/// Rewrites a path string inside a load command in place when it starts with
/// @executable_path. "@loader_path" is shorter, so it always fits.
fn rewrite_executable_path(b: &mut [u8], cmd: &Command, name_field: usize) {
    let name_off = rd32(b, cmd.offset + name_field) as usize;
    if name_off >= cmd.size {
        return;
    }
    let start = cmd.offset + name_off;
    let end = cmd.offset + cmd.size;
    let path = c_string_at(b, start, end);
    if let Some(rest) = path.strip_prefix("@executable_path") {
        let new = format!("@loader_path{rest}");
        let field = &mut b[start..end];
        field.fill(0);
        field[..new.len()].copy_from_slice(new.as_bytes());
    }
}

/// Patches one thin arm64 Mach-O. `target_platform` 0 leaves the platform alone.
fn patch_macho(b: &mut Vec<u8>, target_platform: u32, make_library: Option<&str>) -> Result<MachInfo, String> {
    let mut info = MachInfo::default();
    let cmds = commands(b)?;
    let mut first_section_offset = usize::MAX;

    for c in &cmds {
        match c.cmd {
            LC_BUILD_VERSION => {
                info.platform = rd32(b, c.offset + 8);
                let platform = info.platform;
                if target_platform != 0
                    && (platform == PLATFORM_IOS || platform == PLATFORM_IOS_SIMULATOR)
                    && platform != target_platform
                {
                    wr32(b, c.offset + 8, target_platform);
                }
            }
            LC_ENCRYPTION_INFO_64 => {
                if rd32(b, c.offset + 16) != 0 {
                    info.encrypted = true;
                }
            }
            LC_MAIN => info.has_main = true,
            LC_SEGMENT_64 => {
                let nsects = rd32(b, c.offset + 64) as usize;
                for s in 0..nsects {
                    let so = c.offset + 72 + s * 80;
                    if so + 80 > c.offset + c.size {
                        break;
                    }
                    let offset = rd32(b, so + 48) as usize;
                    let size = rd64(b, so + 40);
                    if offset != 0 && size != 0 {
                        first_section_offset = first_section_offset.min(offset);
                    }
                }
            }
            _ => {}
        }
    }

    let Some(executable_name) = make_library else { return Ok(info) };
    if info.encrypted {
        return Ok(info);
    }

    // MH_EXECUTE -> MH_DYLIB, so dlopen accepts it.
    wr32(b, 12, MH_DYLIB);
    let flags = rd32(b, 24) | MH_NO_REEXPORTED_DYLIBS;
    wr32(b, 24, flags);

    for c in &cmds {
        match c.cmd {
            LC_SEGMENT_64 => {
                let name = c_string_at(b, c.offset + 8, c.offset + 24);
                if name == "__PAGEZERO" {
                    // A 4 GB reservation is fine for a process but not for a library
                    // loaded into one: map a single page just below __TEXT instead.
                    wr64(b, c.offset + 24, 0x1_0000_0000 - 0x4000);
                    wr64(b, c.offset + 32, 0x4000);
                }
            }
            LC_RPATH => rewrite_executable_path(b, c, 8),
            LC_LOAD_DYLIB | LC_LOAD_WEAK_DYLIB | LC_REEXPORT_DYLIB | LC_LAZY_LOAD_DYLIB => {
                rewrite_executable_path(b, c, 8)
            }
            _ => {}
        }
    }

    // Add an LC_ID_DYLIB in the padding after the load commands.
    if !cmds.iter().any(|c| c.cmd == LC_ID_DYLIB) {
        let name = format!("@loader_path/{executable_name}");
        let size = (24 + name.len() + 1 + 7) & !7;
        let ncmds = rd32(b, 16);
        let sizeofcmds = rd32(b, 20) as usize;
        let at = 32 + sizeofcmds;
        if first_section_offset == usize::MAX || at + size > first_section_offset {
            return Err("there's no room in its header to load it as a library".into());
        }
        let mut cmd = vec![0u8; size];
        wr32(&mut cmd, 0, LC_ID_DYLIB);
        wr32(&mut cmd, 4, size as u32);
        wr32(&mut cmd, 8, 24); // name offset
        wr32(&mut cmd, 12, 2); // timestamp
        wr32(&mut cmd, 16, 0x0001_0000); // current version 1.0.0
        wr32(&mut cmd, 20, 0x0001_0000); // compatibility version 1.0.0
        cmd[24..24 + name.len()].copy_from_slice(name.as_bytes());
        if b[at..at + size].iter().any(|&x| x != 0) {
            return Err("its header padding isn't empty".into());
        }
        b[at..at + size].copy_from_slice(&cmd);
        wr32(b, 16, ncmds + 1);
        wr32(b, 20, (sizeofcmds + size) as u32);
    }
    Ok(info)
}

/// Thins, retags and (for the main executable) converts one file. Ok(None) when the
/// file isn't a Mach-O.
fn process_file(path: &Path, target_platform: u32, make_library: Option<&str>) -> Result<Option<MachInfo>, String> {
    let data = std::fs::read(path).map_err(|e| err(&format!("Couldn't read {}", path.display()), e))?;
    let Some(mut thin) = thin_arm64(&data).map_err(|e| format!("{} {e}", file_name(path)))? else {
        return Ok(None);
    };
    if rd32(&thin, 0) != MH_MAGIC_64 {
        return Ok(None);
    }
    let info = patch_macho(&mut thin, target_platform, make_library)
        .map_err(|e| format!("{}: {e}", file_name(path)))?;
    if thin != data {
        std::fs::write(path, &thin).map_err(|e| err(&format!("Couldn't write {}", path.display()), e))?;
    }
    Ok(Some(info))
}

fn file_name(p: &Path) -> String {
    p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()
}

// MARK: - Import

fn walk_files(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        let Ok(meta) = std::fs::symlink_metadata(&path) else { continue };
        if meta.file_type().is_symlink() {
            continue;
        }
        if meta.is_dir() {
            walk_files(&path, out);
        } else if meta.is_file() {
            out.push(path);
        }
    }
}

fn copy_dir(from: &Path, to: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(to)?;
    for entry in std::fs::read_dir(from)? {
        let entry = entry?;
        let src = entry.path();
        let dst = to.join(entry.file_name());
        let meta = std::fs::symlink_metadata(&src)?;
        if meta.file_type().is_symlink() {
            let target = std::fs::read_link(&src)?;
            std::os::unix::fs::symlink(target, &dst)?;
        } else if meta.is_dir() {
            copy_dir(&src, &dst)?;
        } else {
            std::fs::copy(&src, &dst)?;
        }
    }
    Ok(())
}

/// Breadth-first search for the first .app folder, skipping macOS zip metadata.
fn find_app(root: &Path) -> Option<PathBuf> {
    if root.extension().is_some_and(|e| e.eq_ignore_ascii_case("app")) && root.join("Info.plist").exists() {
        return Some(root.to_path_buf());
    }
    let mut queue = std::collections::VecDeque::from([(root.to_path_buf(), 0usize)]);
    while let Some((dir, depth)) = queue.pop_front() {
        let Ok(entries) = std::fs::read_dir(&dir) else { continue };
        let mut subdirs: Vec<PathBuf> = entries
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.is_dir() && !file_name(p).starts_with("__MACOSX"))
            .collect();
        subdirs.sort();
        for p in &subdirs {
            if p.extension().is_some_and(|e| e.eq_ignore_ascii_case("app")) && p.join("Info.plist").exists() {
                return Some(p.clone());
            }
        }
        if depth < 4 {
            queue.extend(subdirs.into_iter().map(|p| (p, depth + 1)));
        }
    }
    None
}

fn info_string(info: &plist::Dictionary, key: &str) -> String {
    info.get(key).and_then(|v| v.as_string()).unwrap_or_default().to_string()
}

pub(super) fn prepare_guest(input: &Path, dest: &Path, target_platform: u32) -> Result<serde_json::Value, String> {
    std::fs::create_dir_all(dest).map_err(|e| err("Couldn't create the app folder", e))?;
    let staging = dest.join(".import");
    let _ = std::fs::remove_dir_all(&staging);
    std::fs::create_dir_all(&staging).map_err(|e| err("Couldn't create a work folder", e))?;

    if input.is_dir() {
        let name = file_name(input);
        copy_dir(input, &staging.join(&name)).map_err(|e| err("Couldn't copy the app", e))?;
    } else {
        let file = std::fs::File::open(input).map_err(|e| err("Couldn't open the file", e))?;
        let mut archive = zip::ZipArchive::new(file)
            .map_err(|e| err("This isn't an .ipa, .zip, .app or .xcarchive iContain can read", e))?;
        archive.extract(&staging).map_err(|e| err("Couldn't unpack the file", e))?;
    }

    let found = find_app(&staging).ok_or("No .app was found inside. Import an .ipa, an .xcarchive, or a zipped .app.")?;
    let app = dest.join(file_name(&found));
    let _ = std::fs::remove_dir_all(&app);
    std::fs::rename(&found, &app).map_err(|e| err("Couldn't move the app into place", e))?;
    let _ = std::fs::remove_dir_all(&staging);

    // The old signature and any watch app are of no use here.
    for junk in ["_CodeSignature", "embedded.mobileprovision", "Watch", "com.apple.WatchPlaceholder", "SC_Info"] {
        let p = app.join(junk);
        let _ = if p.is_dir() { std::fs::remove_dir_all(&p) } else { std::fs::remove_file(&p) };
    }

    let info: plist::Dictionary =
        plist::from_file(app.join("Info.plist")).map_err(|e| err("Couldn't read the app's Info.plist", e))?;
    let executable = info_string(&info, "CFBundleExecutable");
    if executable.is_empty() {
        return Err("The app's Info.plist doesn't name its executable.".into());
    }
    let main_path = app.join(&executable);

    let main = process_file(&main_path, target_platform, Some(&executable))?
        .ok_or("The app's executable isn't an iOS program.")?;
    if main.encrypted {
        return Err("This app is encrypted by the App Store (FairPlay), so it can't run anywhere but where Apple installed it. Import a decrypted .ipa, or a build from Xcode.".into());
    }

    let mut files = Vec::new();
    walk_files(&app, &mut files);
    for f in files.iter().filter(|f| **f != main_path) {
        // A framework without arm64 code can't load; say which one.
        process_file(f, target_platform, None)?;
    }

    let platform = match main.platform {
        PLATFORM_IOS => "ios",
        PLATFORM_IOS_SIMULATOR => "simulator",
        _ => "unknown",
    };
    let display_name = [info_string(&info, "CFBundleDisplayName"), info_string(&info, "CFBundleName"), executable.clone()]
        .into_iter()
        .find(|s| !s.is_empty())
        .unwrap_or_default();
    Ok(serde_json::json!({
        "appPath": app.to_string_lossy(),
        "bundleId": info_string(&info, "CFBundleIdentifier"),
        "name": display_name,
        "version": info_string(&info, "CFBundleShortVersionString"),
        "build": info_string(&info, "CFBundleVersion"),
        "executable": executable,
        "minimumOS": info_string(&info, "MinimumOSVersion"),
        "platform": platform,
    }))
}

// MARK: - Signing identity

const IDENTITY_KEY: &str = "identity";

fn identity_storage() -> FileStorage {
    FileStorage::new("guest-identity", None)
}

struct GuestIdentity {
    team_id: String,
    key: RsaPrivateKey,
    cert: Certificate,
    expires: i64,
    /// Intermediates that came with the certificate (from a .p12), if any.
    chain: Vec<Certificate>,
}

fn cert_expiry(cert: &Certificate) -> i64 {
    cert.tbs_certificate
        .validity
        .not_after
        .to_unix_duration()
        .as_secs() as i64
}

/// The team ID is the certificate subject's OU.
fn cert_team(cert: &Certificate) -> String {
    for rdn in cert.tbs_certificate.subject.0.iter() {
        for atv in rdn.0.iter() {
            if atv.oid.to_string() == "2.5.4.11" {
                if let Ok(s) = atv.value.decode_as::<x509_cert::der::asn1::Utf8StringRef>() {
                    return s.as_str().to_string();
                }
                if let Ok(s) = atv.value.decode_as::<x509_cert::der::asn1::PrintableStringRef>() {
                    return s.as_str().to_string();
                }
            }
        }
    }
    String::new()
}

/// Uses a development certificate from a .p12 file instead of an Apple ID sign-in.
fn import_p12(path: &Path, password: &str) -> Result<GuestIdentity, String> {
    use p12_keystore::{KeyStore, Pkcs12ImportPolicy};
    let data = std::fs::read(path).map_err(|e| err("Couldn't read the certificate file", e))?;
    let store = KeyStore::from_pkcs12(&data, password, Pkcs12ImportPolicy::Relaxed)
        .map_err(|e| err("Couldn't open the certificate file (check the password)", format!("{e:?}")))?;
    let (_, chain) = store.private_key_chain().ok_or("The file has no private key.")?;
    let key = RsaPrivateKey::from_pkcs8_der(chain.key().as_der())
        .map_err(|e| err("The private key isn't an RSA key iContain can use", e))?;
    let cert_der = chain.certs().first().ok_or("The file has no certificate.")?.as_der();
    let cert = Certificate::from_der(cert_der).map_err(|e| err("Couldn't read the certificate", e))?;
    let team_id = cert_team(&cert);
    if team_id.is_empty() {
        return Err("The certificate doesn't name a team. Use an Apple development certificate.".into());
    }
    let expires = cert_expiry(&cert);
    let chain = chain
        .certs()
        .iter()
        .skip(1)
        .filter_map(|c| Certificate::from_der(c.as_der()).ok())
        .collect();
    let id = GuestIdentity { team_id, key, cert, expires, chain };
    save_identity(&id)?;
    Ok(id)
}

fn load_identity() -> Option<GuestIdentity> {
    let saved: serde_json::Value = serde_json::from_str(&identity_storage().retrieve(IDENTITY_KEY).ok()??).ok()?;
    use base64::Engine;
    let b64 = base64::engine::general_purpose::STANDARD;
    let key = RsaPrivateKey::from_pkcs8_der(&b64.decode(saved["key"].as_str()?).ok()?).ok()?;
    let cert = Certificate::from_der(&b64.decode(saved["cert"].as_str()?).ok()?).ok()?;
    let expires = cert_expiry(&cert);
    let chain = saved["chain"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|v| b64.decode(v.as_str()?).ok())
                .filter_map(|der| Certificate::from_der(&der).ok())
                .collect()
        })
        .unwrap_or_default();
    Some(GuestIdentity { team_id: saved["teamId"].as_str()?.to_string(), key, cert, expires, chain })
}

fn save_identity(id: &GuestIdentity) -> Result<(), String> {
    use base64::Engine;
    let b64 = base64::engine::general_purpose::STANDARD;
    let key = id.key.to_pkcs8_der().map_err(|e| err("Couldn't save the signing key", e))?;
    let cert = id.cert.to_der().map_err(|e| err("Couldn't save the certificate", e))?;
    let chain: Vec<String> = id.chain.iter().filter_map(|c| c.to_der().ok()).map(|d| b64.encode(d)).collect();
    let json = serde_json::json!({
        "teamId": id.team_id,
        "key": b64.encode(key.as_bytes()),
        "cert": b64.encode(cert),
        "chain": chain,
    });
    identity_storage()
        .store(IDENTITY_KEY, &json.to_string())
        .map_err(|e| err("Couldn't save the signing identity", e))
}

fn identity_json(id: &GuestIdentity) -> serde_json::Value {
    serde_json::json!({
        "teamId": id.team_id,
        "expires": id.expires,
        "serial": id.cert.tbs_certificate.serial_number.as_bytes().iter().map(|b| format!("{b:02X}")).collect::<String>(),
    })
}

/// Signs in, then reuses or creates iContain's development certificate on the team.
async fn fetch_identity(
    apple_id: &str,
    password: &str,
    anisette: &str,
    cbs: Callbacks,
    replies: Replies,
) -> Result<GuestIdentity, String> {
    cbs.progress("Signing in to Apple…", -1.0);
    let mut dev = sign_in(apple_id, password, anisette, cbs, replies.clone()).await?;
    cbs.progress("Getting a signing certificate…", -1.0);
    let team = dev
        .list_teams()
        .await
        .map_err(|e| err("Couldn't load your developer team", e))?
        .into_iter()
        .next()
        .ok_or("This Apple ID has no developer team.")?;

    let revoke_prompt = move |certs: Vec<DevelopmentCertificate>| {
        let replies = replies.clone();
        let json = certs_json(&certs);
        async move {
            cbs.prompt(PROMPT_REVOKE_CERTS, &json);
            let reply = replies.lock().await.recv().await.unwrap_or_default();
            let serials: Vec<String> = serde_json::from_str(&reply).unwrap_or_default();
            Ok::<_, rootcause::Report>(if serials.is_empty() { None } else { Some(serials) })
        }
    };
    let storage = FileStorage::new("signing", None);
    let identity = CertificateIdentity::retrieve(
        "iContain",
        apple_id,
        &mut dev,
        &team,
        &storage,
        &MaxCertsBehavior::Prompt(revoke_prompt),
    )
    .await
    .map_err(|e| err("Couldn't get a signing certificate", e))?;

    let expires = cert_expiry(&identity.certificate);
    let id = GuestIdentity {
        team_id: team.team_id.clone(),
        key: identity.private_key,
        cert: identity.certificate,
        expires,
        chain: Vec::new(),
    };
    save_identity(&id)?;
    Ok(id)
}

/// The certificates between the signing certificate and Apple's root, found by
/// following issuers through the .p12's own intermediates, then Apple's WWDR G3 and
/// root bundled with isideload. Certificates from other intermediates (a .p12 that
/// carries its WWDR certificate) work the same way.
fn signing_chain(id: &GuestIdentity) -> Result<Vec<Certificate>, String> {
    let mut candidates = id.chain.clone();
    for der in [APPLE_WWDR_G3_CERTIFICATE_DER, APPLE_ROOT] {
        candidates.push(Certificate::from_der(der).map_err(|e| err("Couldn't read Apple's certificates", e))?);
    }
    let mut chain = Vec::new();
    let mut issuer = id.cert.tbs_certificate.issuer.clone();
    while chain.len() < 4 {
        let Some(next) = candidates.iter().find(|c| c.tbs_certificate.subject == issuer).cloned() else {
            return Err(format!(
                "The certificate's issuer ({issuer}) is missing. Export the .p12 with its full certificate chain."
            ));
        };
        let is_root = next.tbs_certificate.subject == next.tbs_certificate.issuer;
        issuer = next.tbs_certificate.issuer.clone();
        chain.push(next);
        if is_root {
            break;
        }
    }
    Ok(chain)
}

fn sign_app(app: &Path, identity: Option<&GuestIdentity>) -> Result<(), String> {
    let signer = match identity {
        Some(id) => Some(RustCryptoCmsSigner::new(id.key.clone(), id.cert.clone(), signing_chain(id)?)),
        None => None,
    };
    let team = identity.map(|i| i.team_id.clone()).unwrap_or_default();
    let settings = BundleSigningSettings::new(
        team,
        plist::Dictionary::new(),
        signer.as_ref().map(|s| s as &dyn CmsSigner),
    );
    sign_bundle(app, &settings).map_err(|e| err("Signing failed", e))?;
    if identity.is_none() {
        mark_ad_hoc(app)?;
    }
    Ok(())
}

const LC_CODE_SIGNATURE: u32 = 0x1d;
const CSMAGIC_EMBEDDED_SIGNATURE: u32 = 0xfade_0cc0;
const CSMAGIC_CODEDIRECTORY: u32 = 0xfade_0c02;
const CS_ADHOC: u32 = 0x2;

/// The Simulator: keep each binary's own (linker or ad hoc) signature and recompute
/// its page hashes after the importer's edits, which only touch the header page.
/// macOS accepts that, while it refuses apple-codesign-quick's certificate-less output.
fn rehash_signatures(app: &Path) -> Result<(), String> {
    use sha1::Digest as _;
    let mut files = Vec::new();
    walk_files(app, &mut files);
    for path in files {
        let Ok(mut b) = std::fs::read(&path) else { continue };
        if b.len() < 32 || rd32(&b, 0) != MH_MAGIC_64 {
            continue;
        }
        let Ok(cmds) = commands(&b) else { continue };
        let Some(sig) = cmds.iter().find(|c| c.cmd == LC_CODE_SIGNATURE) else {
            return Err(format!("{} isn't signed. Build it again with Xcode.", file_name(&path)));
        };
        let start = rd32(&b, sig.offset + 8) as usize;
        let size = rd32(&b, sig.offset + 12) as usize;
        if start + size > b.len() || rdbe32(&b, start) != CSMAGIC_EMBEDDED_SIGNATURE {
            continue;
        }
        let count = rdbe32(&b, start + 8) as usize;
        for i in 0..count {
            let blob = start + rdbe32(&b, start + 12 + i * 8 + 4) as usize;
            if blob + 40 > b.len() || rdbe32(&b, blob) != CSMAGIC_CODEDIRECTORY {
                continue;
            }
            let hash_offset = rdbe32(&b, blob + 16) as usize;
            let slots = rdbe32(&b, blob + 28) as usize;
            let limit = (rdbe32(&b, blob + 32) as usize).min(start);
            let hash_size = b[blob + 36] as usize;
            let hash_type = b[blob + 37];
            let page = 1usize << b[blob + 39];
            for slot in 0..slots {
                let from = slot * page;
                let to = (from + page).min(limit);
                if from >= to {
                    break;
                }
                let digest: Vec<u8> = match hash_type {
                    1 => sha1::Sha1::digest(&b[from..to]).to_vec(),
                    _ => sha2::Sha256::digest(&b[from..to]).to_vec(),
                };
                let at = blob + hash_offset + slot * hash_size;
                let n = hash_size.min(digest.len());
                b[at..at + n].copy_from_slice(&digest[..n]);
            }
        }
        std::fs::write(&path, &b).map_err(|e| err(&format!("Couldn't write {}", path.display()), e))?;
    }
    Ok(())
}

/// apple-codesign-quick leaves the CodeDirectory flags at 0 when there's no
/// certificate, which macOS (and so the Simulator) reads as "not signed". Setting
/// CS_ADHOC makes it a proper ad hoc signature. The flags aren't covered by the page
/// hashes, so nothing else needs to change.
fn mark_ad_hoc(app: &Path) -> Result<(), String> {
    let mut files = Vec::new();
    walk_files(app, &mut files);
    for path in files {
        let Ok(mut b) = std::fs::read(&path) else { continue };
        if b.len() < 32 || rd32(&b, 0) != MH_MAGIC_64 {
            continue;
        }
        let Ok(cmds) = commands(&b) else { continue };
        let Some(sig) = cmds.iter().find(|c| c.cmd == LC_CODE_SIGNATURE) else { continue };
        let start = rd32(&b, sig.offset + 8) as usize;
        let size = rd32(&b, sig.offset + 12) as usize;
        if start + size > b.len() || size < 12 || rdbe32(&b, start) != CSMAGIC_EMBEDDED_SIGNATURE {
            continue;
        }
        let count = rdbe32(&b, start + 8) as usize;
        let mut changed = false;
        for i in 0..count {
            let entry = start + 12 + i * 8;
            if entry + 8 > start + size {
                break;
            }
            let blob = start + rdbe32(&b, entry + 4) as usize;
            if blob + 16 <= b.len() && rdbe32(&b, blob) == CSMAGIC_CODEDIRECTORY {
                let flags = rdbe32(&b, blob + 12) | CS_ADHOC;
                b[blob + 12..blob + 16].copy_from_slice(&flags.to_be_bytes());
                changed = true;
            }
        }
        if changed {
            std::fs::write(&path, &b).map_err(|e| err(&format!("Couldn't write {}", path.display()), e))?;
        }
    }
    Ok(())
}

// MARK: - FFI

/// Imports `input` into `dest_dir` (see the top of this file). `target_platform` is
/// 2 on a device and 7 in the Simulator. Returns 0 with the app's details as JSON in
/// `*out_json`, or 1 with an error message. Free with icontain_string_free. Blocking.
#[no_mangle]
pub unsafe extern "C" fn icontain_prepare_guest(
    input: *const c_char,
    dest_dir: *const c_char,
    target_platform: u32,
    out_json: *mut *mut c_char,
) -> i32 {
    if out_json.is_null() {
        return 2;
    }
    let result = (|| {
        let input = req(input, "input")?;
        let dest = req(dest_dir, "destination")?;
        prepare_guest(Path::new(&input), Path::new(&dest), target_platform)
    })();
    match result {
        Ok(json) => {
            *out_json = cstr(json.to_string());
            0
        }
        Err(e) => {
            *out_json = cstr(e);
            1
        }
    }
}

/// Signs a prepared guest .app.
///   mode 0: ad hoc (the Simulator).
///   mode 1: with the cached certificate; signs in first only if there's none or it
///           has expired (needs apple_id/password then).
///   mode 2: always sign in and refresh the certificate first.
/// Returns 0 with {"teamId","expires","serial"} (or {} ad hoc), 1 with an error,
/// 3 when a sign-in is needed but no Apple ID was given.
#[no_mangle]
pub unsafe extern "C" fn icontain_sign_guest(
    session: *mut ICInstallSession,
    app_path: *const c_char,
    mode: i32,
    apple_id: *const c_char,
    password: *const c_char,
    anisette_url: *const c_char,
    progress_cb: ICProgressCb,
    prompt_cb: ICPromptCb,
    ctx: *mut c_void,
    out_json: *mut *mut c_char,
) -> i32 {
    if session.is_null() || out_json.is_null() {
        return 2;
    }
    *out_json = ptr::null_mut();
    init_once();
    let fail = |msg: String| -> i32 {
        *out_json = cstr(msg);
        1
    };
    let app = match req(app_path, "app path") { Ok(v) => PathBuf::from(v), Err(e) => return fail(e) };
    let cbs = Callbacks { progress: progress_cb, prompt: prompt_cb, ctx };

    if mode == 0 {
        cbs.progress("Signing…", -1.0);
        return match rehash_signatures(&app) {
            Ok(()) => {
                *out_json = cstr("{}");
                0
            }
            Err(e) => fail(e),
        };
    }

    let now = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs() as i64);
    let cached = if mode == 1 { load_identity().filter(|i| i.expires > now + 3600) } else { None };
    let identity = match cached {
        Some(id) => id,
        None => {
            let apple_id = opt(apple_id, "");
            let password = opt(password, "");
            if apple_id.is_empty() || password.is_empty() {
                *out_json = cstr("Sign in with your Apple ID so iContain can get a signing certificate.");
                return 3;
            }
            let anisette = opt(anisette_url, "https://ani.jkcoxson.com");
            let session = &*session;
            let (tx, rx) = mpsc::unbounded_channel();
            *session.responder.lock().unwrap() = Some(tx);
            session.cancelled.store(false, Ordering::SeqCst);
            let rt = match tokio::runtime::Builder::new_multi_thread().enable_all().build() {
                Ok(rt) => rt,
                Err(e) => return fail(format!("failed to start runtime: {e}")),
            };
            let result = rt.block_on(fetch_identity(&apple_id, &password, &anisette, cbs, Arc::new(AsyncMutex::new(rx))));
            *session.responder.lock().unwrap() = None;
            match result {
                Ok(id) => id,
                Err(e) => return fail(e),
            }
        }
    };

    cbs.progress("Signing…", -1.0);
    match sign_app(&app, Some(&identity)) {
        Ok(()) => {
            *out_json = cstr(identity_json(&identity).to_string());
            0
        }
        Err(e) => fail(e),
    }
}

/// The cached signing identity as {"teamId","expires","serial"}, or null if none.
#[no_mangle]
pub unsafe extern "C" fn icontain_identity_info() -> *mut c_char {
    match load_identity() {
        Some(id) => cstr(identity_json(&id).to_string()),
        None => ptr::null_mut(),
    }
}

/// Imports a development certificate (.p12) as the signing identity.
/// 0: {"teamId","expires","serial"}; 1: error message. Free with icontain_string_free.
#[no_mangle]
pub unsafe extern "C" fn icontain_identity_import_p12(path: *const c_char, password: *const c_char, out_json: *mut *mut c_char) -> i32 {
    if out_json.is_null() {
        return 2;
    }
    let path = match req(path, "certificate path") { Ok(v) => v, Err(e) => { *out_json = cstr(e); return 1; } };
    match import_p12(Path::new(&path), &opt(password, "")) {
        Ok(id) => { *out_json = cstr(identity_json(&id).to_string()); 0 }
        Err(e) => { *out_json = cstr(e); 1 }
    }
}

#[no_mangle]
pub extern "C" fn icontain_identity_forget() {
    let _ = identity_storage().delete(IDENTITY_KEY);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn non_macho_files_are_left_alone() {
        assert!(thin_arm64(b"hello world").unwrap().is_none());
        assert!(thin_arm64(&[0xca, 0xfe, 0xba, 0xbe, 0, 0, 0, 50]).unwrap().is_none());
    }
}
