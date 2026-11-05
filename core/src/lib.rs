// iContain's Rust core, exposed to Swift as a C library (see include/icontain.h).
//
//   install/guest.rs     importing apps into iContain and signing them for loading
//   install/sign_in.rs   Apple ID sign-in with anisette server failover
//   install/account.rs   certificates, App IDs and capabilities (GetMoreRam)
//   install/device.rs    device services through LocalDevVPN (location simulation)

mod install;

/// Lets examples link the library.
pub fn touch() {}
