// iContain's Rust core. Implemented in core/src (MIT).
#ifndef ICONTAIN_H
#define ICONTAIN_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- On-device sideloading (core/src/install/mod.rs) ---- */

typedef void (*ICProgressCb)(void *ctx, const char *stage, double fraction); /* fraction < 0: indeterminate */
typedef void (*ICPromptCb)(void *ctx, int32_t kind, const char *json);       /* 1 = two-factor, 2 = revoke certificates */

typedef struct {
    const char *host;
    uint16_t port;
    const char *identifier; /* TXT "identifier" of _remotepairing._tcp */
    const char *auth_tag;   /* TXT "authTag" */
} ICEndpoint;

typedef struct {
    const char *apple_id;
    const char *password;
    const char *anisette_url;
    const char *pairing_file_path;
    const char *host_name;
    const ICEndpoint *endpoints;
    size_t endpoint_count;
    const char *ipa_path;
    const char *device_name;
    const char *machine_name;
    const char *server_id;
    /* Comma-separated App Store Connect capability IDs to enable on the app's
       App ID before signing (e.g. "INCREASED_MEMORY_LIMIT,PUSH_NOTIFICATIONS").
       NULL or "" for none. */
    const char *capabilities;
    /* App extensions: 0 keep, 1 keep and sign with the main profile, 2 remove. */
    int32_t extensions_mode;
} ICInstallConfig;

typedef struct {
    char *error;
    char *bundle_id;
    char *app_name;
    char *app_version;
    char *udid;
    char *team_id;
    int64_t expiration_unix;
} ICInstallResult;

typedef struct ICInstallSession ICInstallSession;

ICInstallSession *icontain_install_session_new(void);
int32_t icontain_install_session_run(ICInstallSession *session,
                                    const ICInstallConfig *config,
                                    ICProgressCb progress_cb,
                                    ICPromptCb prompt_cb,
                                    void *ctx,
                                    ICInstallResult *out);
int32_t icontain_install_session_respond(ICInstallSession *session, const char *response);
void icontain_install_session_cancel(ICInstallSession *session);
void icontain_install_session_free(ICInstallSession *session);
void icontain_install_result_free(ICInstallResult *r);


/* ---- Certificate manager: your own Apple ID (core/src/install/mod.rs) ---- */

/* Runs {"op":"overview"}, {"op":"revoke","serials":[...]} or
   {"op":"set_capability","identifiers":[...],"capability":"INCREASED_MEMORY_LIMIT","enabled":true}
   against the Apple
   ID's own team. Reuses an ICInstallSession for 2FA prompts and cancel.
   Returns 0 with overview JSON in *out_json, or 1 with an error message.
   Free *out_json with icontain_string_free. Blocking. */
int32_t icontain_account_session_run(ICInstallSession *session,
                                    const char *apple_id,
                                    const char *password,
                                    const char *anisette_url,
                                    const char *request_json,
                                    ICProgressCb progress_cb,
                                    ICPromptCb prompt_cb,
                                    void *ctx,
                                    char **out_json);
void icontain_string_free(char *s);


/* ---- Device ops: on-device AltServer + files into apps (core/src/install/device.rs) ---- */

/* Opens the tunnel from config (pairing_file_path, host_name, endpoints; the
   Apple ID fields are ignored) and runs one op from request_json:
   install_app, install_profiles, remove_profiles, remove_app, list_apps, place_file.
   Returns 0 with result JSON in *out_json, or 1 with an error message.
   Free *out_json with icontain_string_free. Blocking. */
int32_t icontain_device_run(const ICInstallConfig *config,
                           const char *request_json,
                           ICProgressCb progress_cb,
                           void *ctx,
                           char **out_json);

/* Move / end a running {"op":"simulate_location"} (which blocks until stopped). */
void icontain_location_update(double latitude, double longitude);
void icontain_location_stop(void);


/* ---- Guest apps: apps that run inside iContain (core/src/install/guest.rs) ---- */

/* Unpacks an .ipa/.zip or copies an .app/.xcarchive folder into dest_dir, finds the
   .app, thins it to arm64, retags its platform (2 = iOS on a device, 7 = Simulator)
   and turns the main executable into a library iContain can load.
   0: *out_json holds {"appPath","bundleId","name","version","build","executable",
   "minimumOS","platform"}; 1: *out_json holds an error. Free with icontain_string_free. */
int32_t icontain_prepare_guest(const char *input,
                               const char *dest_dir,
                               uint32_t target_platform,
                               char **out_json);

/* Signs a prepared guest .app. mode 0 ad hoc (Simulator), 1 cached certificate (signs
   in only if needed), 2 sign in and refresh the certificate first.
   0: {"teamId","expires","serial"}; 1: error; 3: a sign-in is needed. */
int32_t icontain_sign_guest(ICInstallSession *session,
                            const char *app_path,
                            int32_t mode,
                            const char *apple_id,
                            const char *password,
                            const char *anisette_url,
                            ICProgressCb progress_cb,
                            ICPromptCb prompt_cb,
                            void *ctx,
                            char **out_json);

/* The cached guest-signing identity as JSON, or NULL. Free with icontain_string_free. */
int32_t icontain_identity_import_p12(const char *path, const char *password, char **out_json);
char *icontain_identity_info(void);
void icontain_identity_forget(void);

#ifdef __cplusplus
}
#endif

#endif // ICONTAIN_H
