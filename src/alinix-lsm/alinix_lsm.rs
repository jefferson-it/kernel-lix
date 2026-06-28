// SPDX-License-Identifier: GPL-2.0

//! Alinix Root Limiter — módulo Rust do kernel
//!
//! Interface via `/dev/alinix-auth` (misc device).
//! Comandos: `set_key <64hex>`, `auth <64hex>`, `deauth`.
//!
//! O C core (`security/commoncap.c`) faz o enforcement no `cap_capable()`.
//! Este módulo Rust gerencia a chave mestra e chama
//! `alinix_set_uid_auth()` para marcar UIDs autorizados.

#![allow(non_camel_case_types)]

use core::ffi::{c_char, c_int, c_uint, c_uchar, c_void};
use core::fmt;
use core::fmt::Write;
use core::sync::atomic::{AtomicBool, Ordering};

use kernel::{
    c_str,
    fs::{File, Kiocb},
    iov::{IovIterDest, IovIterSource},
    miscdevice::{MiscDevice, MiscDeviceOptions, MiscDeviceRegistration},
    prelude::*,
};

// ═══════════════════════════════════════════════════════════════════════════
// FFI — C exports em kernel/alinix.c
// ═══════════════════════════════════════════════════════════════════════════
extern "C" {
    fn alinix_enable();
    fn alinix_disable();
    fn alinix_set_uid_auth(uid: c_uint, auth: bool);
    fn alinix_uid_is_authed(uid: c_uint) -> bool;
    fn alinix_is_enabled() -> bool;

    // kernel crypto API
    fn crypto_alloc_shash(name: *const c_char, type_: u32, mask: u32) -> *mut c_void;
    fn crypto_shash_tfm_digest(
        tfm: *mut c_void,
        data: *const c_uchar,
        len: c_uint,
        out: *mut c_uchar,
    ) -> c_int;
    fn crypto_destroy_tfm(mem: *mut c_void, tfm: *mut c_void);
}

// ═══════════════════════════════════════════════════════════════════════════
// SHA-256 via kernel crypto API
// ═══════════════════════════════════════════════════════════════════════════
fn sha256(data: &[u8]) -> Result<[u8; 32]> {
    let name = b"sha256\0";
    let tfm = unsafe { crypto_alloc_shash(name.as_ptr() as *const c_char, 0, 0) };
    if tfm.is_null() {
        return Err(EIO);
    }
    let mut out = [0u8; 32];
    let ret = unsafe {
        crypto_shash_tfm_digest(
            tfm,
            data.as_ptr() as *const c_uchar,
            data.len() as c_uint,
            out.as_mut_ptr(),
        )
    };
    unsafe { crypto_destroy_tfm(tfm, tfm) }
    if ret == 0 { Ok(out) } else { Err(EIO) }
}

// ═══════════════════════════════════════════════════════════════════════════
// Estado global protegido
// ═══════════════════════════════════════════════════════════════════════════
const KEY_HEX_LEN: usize = 64;

struct Inner {
    root_key_hash: [u8; 32],
    key_defined: bool,
}

kernel::sync::global_lock! {
    // SAFETY: Inicializado no init do módulo antes do primeiro uso.
    unsafe(uninit) static STATE: Mutex<Inner> = Inner {
        root_key_hash: [0u8; 32],
        key_defined: false,
    };
}

static LOADED: AtomicBool = AtomicBool::new(false);

// ═══════════════════════════════════════════════════════════════════════════
// Hex utils
// ═══════════════════════════════════════════════════════════════════════════
fn nibble(c: u8) -> Result<u8> {
    match c {
        b'0'..=b'9' => Ok(c - b'0'),
        b'a'..=b'f' => Ok(c - b'a' + 10),
        b'A'..=b'F' => Ok(c - b'A' + 10),
        _ => Err(EINVAL),
    }
}

fn unhex(s: &[u8]) -> Result<[u8; 32]> {
    if s.len() < KEY_HEX_LEN {
        return Err(EINVAL);
    }
    let mut out = [0u8; 32];
    for i in 0..32 {
        out[i] = (nibble(s[i * 2])? << 4) | nibble(s[i * 2 + 1])?;
    }
    Ok(out)
}

fn trim(s: &[u8]) -> &[u8] {
    let start = s.iter().position(|b| !b.is_ascii_whitespace()).unwrap_or(s.len());
    let end = s.iter().rposition(|b| !b.is_ascii_whitespace()).map_or(0, |p| p + 1);
    &s[start..end]
}

// ═══════════════════════════════════════════════════════════════════════════
// Comandos
// ═══════════════════════════════════════════════════════════════════════════
fn do_set_key(arg: &[u8]) -> Result<()> {
    let arg = trim(arg);
    if arg.len() != KEY_HEX_LEN {
        return Err(EPERM);
    }
    let raw = unhex(arg)?;
    let h = sha256(&raw)?;

    let mut st = STATE.lock();
    if st.key_defined {
        return Err(EPERM);
    }
    st.root_key_hash = h;
    st.key_defined = true;

    unsafe { alinix_enable() }
    pr_info!("[Alinix] Chave definida — limitador ativo\n");
    Ok(())
}

fn do_auth(arg: &[u8]) -> Result<()> {
    let arg = trim(arg);
    if arg.len() != KEY_HEX_LEN {
        return Err(EPERM);
    }
    let raw = unhex(arg)?;
    let h = sha256(&raw)?;

    let st = STATE.lock();
    if !st.key_defined {
        return Err(ENXIO);
    }

    let mut diff: u8 = 0;
    for i in 0..32 {
        diff |= st.root_key_hash[i] ^ h[i];
    }
    if diff != 0 {
        return Err(EPERM);
    }

    let uid = current!().uid().into_uid_in_current_ns();
    drop(st);
    unsafe { alinix_set_uid_auth(uid, true) }
    pr_info!("[Alinix] UID {} autorizado como root\n", uid);
    Ok(())
}

fn do_deauth() -> Result<()> {
    let uid = current!().uid().into_uid_in_current_ns();
    unsafe { alinix_set_uid_auth(uid, false) }
    pr_info!("[Alinix] UID {} desautorizado\n", uid);
    Ok(())
}

fn do_status(buf: &mut [u8]) -> Result<usize> {
    let uid = current!().uid().into_uid_in_current_ns();
    let authed = unsafe { alinix_uid_is_authed(uid) };
    let enabled = unsafe { alinix_is_enabled() };
    let st = STATE.lock();

    let mut f = Fmt::new(buf);
    let _ = write!(
        &mut f,
        "Alinix Root Limiter\n\
         Ativo:      {}\n\
         Chave:      {}\n\
         Seu UID:    {}\n\
         Autorizado: {}\n",
         if enabled { "sim" } else { "não" },
         if st.key_defined { "definida" } else { "não definida" },
         uid,
         if authed { "sim" } else { "não" },
    );
    Ok(f.len())
}

// ═══════════════════════════════════════════════════════════════════════════
// Misc device: /dev/alinix-auth
// ═══════════════════════════════════════════════════════════════════════════
struct AuthDev;

#[vtable]
impl MiscDevice for AuthDev {
    type Ptr = Pin<KBox<Self>>;

    fn open(_file: &File, _misc: &MiscDeviceRegistration<Self>) -> Result<Pin<KBox<Self>>> {
        let b = KBox::new(AuthDev, GFP_KERNEL)?;
        Ok(Pin::from(b))
    }

    fn read_iter(mut kiocb: Kiocb<'_, Self::Ptr>, iov: &mut IovIterDest<'_>) -> Result<usize> {
        let mut status_buf = [0u8; 512];
        let status_len = do_status(&mut status_buf)?;
        let read = iov.simple_read_from_buffer(kiocb.ki_pos_mut(), &status_buf[..status_len])?;
        Ok(read)
    }

    fn write_iter(mut _kiocb: Kiocb<'_, Self::Ptr>, iov: &mut IovIterSource<'_>) -> Result<usize> {
        let mut buffer = [0u8; 128];
        let len = iov.copy_from_iter(&mut buffer);
        let input = trim(&buffer[..len]);
        if input.is_empty() {
            return Ok(len);
        }

        let (cmd, arg) = match input.iter().position(|b| *b == b' ' || *b == b'\n') {
            Some(p) => {
                let (c, a) = input.split_at(p);
                (c, trim(a))
            }
            None => (input, &[][..]),
        };

        match cmd {
            b"set_key" | b"setkey" => do_set_key(arg),
            b"auth" | b"authenticate" => do_auth(arg),
            b"deauth" => do_deauth(),
            _ => {
                pr_warn!("[Alinix] comando inválido\n");
                Err(EINVAL)
            }
        }?;

        Ok(len)
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Módulo
// ═══════════════════════════════════════════════════════════════════════════
#[pin_data(PinnedDrop)]
struct AlinixModule {
    #[pin]
    _miscdev: MiscDeviceRegistration<AuthDev>,
}

impl kernel::InPlaceModule for AlinixModule {
    fn init(_module: &'static ThisModule) -> impl PinInit<Self, Error> {
        pr_info!("[Alinix] Carregando módulo Rust (root limiter)...\n");

        // SAFETY: Inicialização única do global lock do módulo.
        unsafe { STATE.init() };

        let options = MiscDeviceOptions {
            name: c_str!("alinix-auth"),
        };

        LOADED.store(true, Ordering::Release);

        pr_info!("[Alinix] Interface: /dev/alinix-auth\n");
        pr_info!("[Alinix]   echo set_key <64hex> > /dev/alinix-auth\n");
        pr_info!("[Alinix]   echo auth    <64hex> > /dev/alinix-auth\n");

        try_pin_init!(Self {
            _miscdev <- MiscDeviceRegistration::register(options),
        })
    }
}

#[pinned_drop]
impl PinnedDrop for AlinixModule {
    fn drop(self: Pin<&mut Self>) {
        LOADED.store(false, Ordering::Release);
        unsafe { alinix_disable() }
        pr_info!("[Alinix] Módulo descarregado — limitador desativado\n");
    }
}

module! {
    type: AlinixModule,
    name: "alinix_lsm",
    authors: ["Alinix Team"],
    description: "Alinix Root Limiter (Rust) — autenticação de root via chave",
    license: "GPL",
}

// ═══════════════════════════════════════════════════════════════════════════
// Fmt — escreve em &[u8] sem alocar
// ═══════════════════════════════════════════════════════════════════════════
struct Fmt<'a> {
    buf: &'a mut [u8],
    pos: usize,
}

impl<'a> Fmt<'a> {
    fn new(buf: &'a mut [u8]) -> Self {
        Self { buf, pos: 0 }
    }
    fn len(&self) -> usize {
        self.pos
    }
}

impl fmt::Write for Fmt<'_> {
    fn write_str(&mut self, s: &str) -> fmt::Result {
        let b = s.as_bytes();
        let n = b.len().min(self.buf.len().saturating_sub(self.pos));
        self.buf[self.pos..self.pos + n].copy_from_slice(&b[..n]);
        self.pos += n;
        Ok(())
    }
}
