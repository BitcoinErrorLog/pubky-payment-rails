//! Derives the pubky (z-base-32) public key for paykit-server's
//! `marketplace.trusted_public_key(s)` from the marketplace-service's
//! `PAYKIT_REQUEST_SIGNING_KEY` (64 hex chars = 32-byte ed25519 seed), the
//! exact construction `PaykitClient::new` performs in marketplace-service.
//!
//! Reads the seed from the `PAYKIT_REQUEST_SIGNING_KEY` environment variable
//! and prints ONLY the 52-character public key on stdout; the seed is never
//! printed or logged.

use ed25519_dalek::SigningKey;
use std::env;
use std::process::ExitCode;

const ZBASE32_ALPHABET: &[u8; 32] = b"ybndrfg8ejkmcpqxot1uwisza345h769";

fn zbase32_encode(data: &[u8]) -> String {
    let mut output = String::new();
    let mut buffer: u32 = 0;
    let mut bits: u32 = 0;
    for &byte in data {
        buffer = (buffer << 8) | u32::from(byte);
        bits += 8;
        while bits >= 5 {
            bits -= 5;
            output.push(ZBASE32_ALPHABET[((buffer >> bits) & 0x1f) as usize] as char);
        }
    }
    if bits > 0 {
        output.push(ZBASE32_ALPHABET[((buffer << (5 - bits)) & 0x1f) as usize] as char);
    }
    output
}

fn hex_decode_32(hex: &str) -> Option<[u8; 32]> {
    let hex = hex.trim();
    if hex.len() != 64 {
        return None;
    }
    let mut out = [0u8; 32];
    for (i, byte) in out.iter_mut().enumerate() {
        *byte = u8::from_str_radix(hex.get(2 * i..2 * i + 2)?, 16).ok()?;
    }
    Some(out)
}

fn main() -> ExitCode {
    let Ok(seed_hex) = env::var("PAYKIT_REQUEST_SIGNING_KEY") else {
        eprintln!("error: PAYKIT_REQUEST_SIGNING_KEY is not set");
        return ExitCode::FAILURE;
    };
    let Some(seed) = hex_decode_32(&seed_hex) else {
        eprintln!("error: PAYKIT_REQUEST_SIGNING_KEY must be 64 hexadecimal characters (32-byte ed25519 seed)");
        return ExitCode::FAILURE;
    };
    let public = SigningKey::from_bytes(&seed).verifying_key();
    println!("{}", zbase32_encode(&public.to_bytes()));
    ExitCode::SUCCESS
}
