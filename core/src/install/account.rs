// Certificate manager: account requests against the signed-in Apple ID's own team.

use super::*;

/// Runs one account request against the signed-in Apple ID's own team.
///
/// `request_json`:
///   {"op":"overview"}                          list certificates, App IDs, devices
///   {"op":"revoke","serials":["ABC…", …]}      revoke those certificates, then list
///
/// On success returns 0 and `*out_json` holds the overview JSON; on failure
/// returns 1 and `*out_json` holds the error message. Free with
/// `icontain_string_free`. Prompts (2FA) and cancellation use the same
/// `ICInstallSession` as installs.
#[no_mangle]
pub unsafe extern "C" fn icontain_account_session_run(
    session: *mut ICInstallSession,
    apple_id: *const c_char,
    password: *const c_char,
    anisette_url: *const c_char,
    request_json: *const c_char,
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
    let apple_id = match req(apple_id, "Apple ID") { Ok(v) => v, Err(e) => return fail(e) };
    let password = match req(password, "password") { Ok(v) => v, Err(e) => return fail(e) };
    let anisette = opt(anisette_url, "https://ani.jkcoxson.com");
    let request: serde_json::Value = serde_json::from_str(&opt(request_json, "{}"))
        .unwrap_or_else(|_| serde_json::json!({}));

    let session = &*session;
    let (tx, rx) = mpsc::unbounded_channel();
    *session.responder.lock().unwrap() = Some(tx);
    session.cancelled.store(false, Ordering::SeqCst);
    let cbs = Callbacks { progress: progress_cb, prompt: prompt_cb, ctx };

    let rt = match tokio::runtime::Builder::new_multi_thread().enable_all().build() {
        Ok(rt) => rt,
        Err(e) => return fail(format!("failed to start runtime: {e}")),
    };
    let result = rt.block_on(run_account(
        apple_id,
        password,
        anisette,
        request,
        cbs,
        Arc::new(AsyncMutex::new(rx)),
        &session.cancelled,
    ));
    *session.responder.lock().unwrap() = None;

    match result {
        Ok(json) => {
            *out_json = cstr(json.to_string());
            0
        }
        Err(e) => fail(e),
    }
}

#[no_mangle]
pub unsafe extern "C" fn icontain_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}

pub(super) async fn run_account(
    apple_id: String,
    password: String,
    anisette: String,
    request: serde_json::Value,
    cbs: Callbacks,
    replies: Replies,
    cancelled: &AtomicBool,
) -> Result<serde_json::Value, String> {
    let check = || if cancelled.load(Ordering::SeqCst) { Err("Cancelled.".to_string()) } else { Ok(()) };

    cbs.progress("Signing in to Apple…", -1.0);
    let mut dev = sign_in(&apple_id, &password, &anisette, cbs, replies).await?;
    check()?;

    cbs.progress("Loading your account…", -1.0);
    let team = dev
        .list_teams()
        .await
        .map_err(|e| err("Couldn't load your developer team", e))?
        .into_iter()
        .next()
        .ok_or("This Apple ID has no developer team.")?;

    if request.get("op").and_then(|v| v.as_str()) == Some("revoke") {
        let serials: Vec<String> = request
            .get("serials")
            .and_then(|v| v.as_array())
            .map(|a| a.iter().filter_map(|s| s.as_str().map(str::to_string)).collect())
            .unwrap_or_default();
        let total = serials.len().max(1) as f64;
        for (i, serial) in serials.iter().enumerate() {
            check()?;
            cbs.progress("Revoking certificate…", i as f64 / total);
            dev.revoke_development_cert(&team, serial, None::<DeveloperDeviceType>)
                .await
                .map_err(|e| err("Couldn't revoke the certificate", e))?;
        }
    }

    if request.get("op").and_then(|v| v.as_str()) == Some("set_capability") {
        // GetMoreRam: switch a capability (e.g. INCREASED_MEMORY_LIMIT) on or off for
        // App IDs. Apps pick it up the next time they're signed with a fresh profile.
        let capability = request.get("capability").and_then(|v| v.as_str()).unwrap_or("").to_string();
        let enabled = request.get("enabled").and_then(|v| v.as_bool()).unwrap_or(true);
        let identifiers: Vec<String> = request
            .get("identifiers")
            .and_then(|v| v.as_array())
            .map(|a| a.iter().filter_map(|s| s.as_str().map(str::to_string)).collect())
            .unwrap_or_default();
        if capability.is_empty() {
            return Err("No capability was given.".into());
        }
        let all = dev
            .list_app_ids(&team, None::<DeveloperDeviceType>)
            .await
            .map_err(|e| err("Couldn't list App IDs", e))?;
        let total = identifiers.len().max(1) as f64;
        for (i, identifier) in identifiers.iter().enumerate() {
            check()?;
            cbs.progress("Updating App IDs…", i as f64 / total);
            let app_id = all
                .app_ids
                .iter()
                .find(|a| &a.identifier == identifier)
                .ok_or_else(|| format!("{identifier} isn't an App ID on this account."))?;
            set_capability(&mut dev, &team, app_id, &capability, enabled).await?;
        }
    }

    check()?;
    cbs.progress("Loading your account…", -1.0);
    account_overview(&mut dev, &team).await
}

pub(super) fn unix(date: Option<plist::Date>) -> i64 {
    date.and_then(|d| SystemTime::from(d).duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

pub(super) async fn account_overview(
    dev: &mut DeveloperSession,
    team: &DeveloperTeam,
) -> Result<serde_json::Value, String> {
    let certs = dev
        .list_ios_certs(team)
        .await
        .map_err(|e| err("Couldn't list certificates", e))?;

    let certificates: Vec<serde_json::Value> = certs
        .iter()
        .map(|c| {
            serde_json::json!({
                "serial": c.serial_number.clone().unwrap_or_default(),
                "certificateId": c.certificate_id.clone().unwrap_or_default(),
                "name": c.name.clone().unwrap_or_default(),
                "machineName": c.machine_name.clone().unwrap_or_default(),
                "machineId": c.machine_id.clone().unwrap_or_default(),
                "platform": c.certificate_platform.clone().unwrap_or_default(),
                "type": c.certificate_type.as_ref().and_then(|t| t.name.clone()).unwrap_or_default(),
                "maxActive": c.certificate_type.as_ref().and_then(|t| t.max_active_certs).unwrap_or(0),
                "status": c.status.clone().unwrap_or_default(),
                "expires": unix(c.expiration_date.clone()),
            })
        })
        .collect();

    // App IDs and devices are extra detail: don't fail the whole overview if
    // Apple refuses one of them.
    let app_ids = match dev.list_app_ids(team, None::<DeveloperDeviceType>).await {
        Ok(r) => serde_json::json!({
            "items": r.app_ids.iter().map(|a| serde_json::json!({
                "id": a.app_id_id,
                "identifier": a.identifier,
                "name": a.name,
                "features": serde_json::to_value(&a.features).unwrap_or_default(),
                "expires": unix(a.expiration_date.clone()),
            })).collect::<Vec<_>>(),
            "max": r.max_quantity,
            "available": r.available_quantity,
        }),
        Err(e) => serde_json::json!({ "error": e.to_string() }),
    };

    let devices = match dev.list_devices(team, None::<DeveloperDeviceType>).await {
        Ok(list) => serde_json::Value::Array(
            list.iter()
                .map(|d| serde_json::json!({
                    "name": d.name.clone().unwrap_or_default(),
                    "udid": d.device_number,
                    "status": d.status.clone().unwrap_or_default(),
                }))
                .collect(),
        ),
        Err(_) => serde_json::Value::Array(Vec::new()),
    };

    Ok(serde_json::json!({
        "team": { "id": team.team_id, "name": team.name.clone().unwrap_or_default() },
        "certificates": certificates,
        "appIds": app_ids,
        "devices": devices,
    }))
}

/// PATCHes one capability on an App ID through the App Store Connect-style endpoint
/// Xcode uses (the same request installs send in bundle.rs, with `enabled` settable).
pub(super) async fn set_capability(
    dev: &mut DeveloperSession,
    team: &DeveloperTeam,
    app_id: &isideload::dev::app_ids::AppId,
    capability: &str,
    enabled: bool,
) -> Result<(), String> {
    let body = serde_json::json!({
        "data": {
            "type": "bundleIds",
            "id": app_id.app_id_id,
            "attributes": {
                "identifier": app_id.identifier,
                "seedId": team.team_id,
                "teamId": team.team_id,
                "name": app_id.name,
                "bundleType": "bundle",
                "hasExclusiveManagedCapabilities": false
            },
            "relationships": {
                "bundleIdCapabilities": {
                    "data": [{
                        "type": "bundleIdCapabilities",
                        "attributes": { "enabled": enabled, "settings": [] },
                        "relationships": {
                            "capability": { "data": { "type": "capabilities", "id": capability } }
                        }
                    }]
                }
            }
        }
    });
    let mut headers = dev.get_headers().await.map_err(|e| err("Couldn't get anisette headers", e))?;
    headers.insert("Content-Type", "application/vnd.api+json".parse().expect("static header"));
    headers.insert("Accept", "application/vnd.api+json".parse().expect("static header"));
    let url = format!("https://developerservices2.apple.com/services/v1/bundleIds/{}", app_id.app_id_id);
    let response = dev
        .get_grandslam_client()
        .patch(&url)
        .map_err(|e| err("Couldn't build the request", e))?
        .headers(headers)
        .body(body.to_string())
        .send()
        .await
        .map_err(|e| err(&format!("Couldn't change {capability}"), e))?;
    if !response.status().is_success() {
        let status = response.status();
        let text = response.text().await.unwrap_or_default();
        let detail = serde_json::from_str::<serde_json::Value>(&text)
            .ok()
            .and_then(|v| v["errors"][0]["detail"].as_str().map(str::to_string))
            .unwrap_or_else(|| format!("HTTP {status}"));
        return Err(format!("Apple wouldn't change {capability} on {}: {detail}", app_id.identifier));
    }
    Ok(())
}
