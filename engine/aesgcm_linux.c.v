module engine

#include "@VMODROOT/engine/aesgcm.h"

@[typedef]
struct C.viltrum_gcm {}

fn C.viltrum_aesgcm_supported() int
fn C.viltrum_gcm_new() &C.viltrum_gcm
fn C.viltrum_gcm_wipe(g &C.viltrum_gcm)
fn C.viltrum_gcm_init(g &C.viltrum_gcm, key &u8, key_len int) int
fn C.viltrum_gcm_seal(g &C.viltrum_gcm, iv &u8, aad &u8, aad_len usize, src &u8, dst &u8, n usize, tag &u8)
fn C.viltrum_gcm_open(g &C.viltrum_gcm, iv &u8, aad &u8, aad_len usize, src &u8, dst &u8, n usize, tag &u8) int

// aesgcm_supported is whether this build and CPU can run aesgcm.h; without it TLS
// stays on mbedtls.
const aesgcm_supported = C.viltrum_aesgcm_supported() != 0
