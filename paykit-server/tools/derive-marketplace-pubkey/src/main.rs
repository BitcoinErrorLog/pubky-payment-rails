//! Derives the pubky public key for paykit-server's
//! `marketplace.trusted_public_key(s)` from the marketplace-service's
//! `PAYKIT_REQUEST_SIGNING_KEY` (64 hex chars = 32-byte ed25519 seed), the
//! exact construction `PaykitClient::new` performs in marketplace-service.
//!
//! Prints ONLY the 57-character `pubky`-prefixed z-base-32 public key on
//! stdout - the exact form the paykit-server fork's config parser accepts
//! (proven in BitcoinErrorLog/paykit-server @ 37ffdd4). The seed is never
//! printed or logged and is zeroized after use.
//!
//! Seed input (exactly one):
//!   - `--stdin`: read the 64-char hex seed from stdin, so the seed never
//!     lands in shell history. Recommended:
//!       read -rs PAYKIT_REQUEST_SIGNING_KEY && export PAYKIT_REQUEST_SIGNING_KEY && \
//!         printf '%s' "$PAYKIT_REQUEST_SIGNING_KEY" | cargo run --quiet -- --stdin; \
//!         unset PAYKIT_REQUEST_SIGNING_KEY
//!   - default: read the seed from the `PAYKIT_REQUEST_SIGNING_KEY` env var.

use ed25519_dalek::SigningKey;
use std::env;
use std::io::Read;
use std::process::ExitCode;
use zeroize::Zeroizing;

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

fn pubky_public_key(seed: &[u8; 32]) -> String {
    let public = SigningKey::from_bytes(seed).verifying_key();
    format!("pubky{}", zbase32_encode(&public.to_bytes()))
}

fn hex_decode_32(hex: &str) -> Option<Zeroizing<[u8; 32]>> {
    let hex = hex.trim();
    if hex.len() != 64 {
        return None;
    }
    let mut out = Zeroizing::new([0u8; 32]);
    for (i, byte) in out.iter_mut().enumerate() {
        *byte = u8::from_str_radix(hex.get(2 * i..2 * i + 2)?, 16).ok()?;
    }
    Some(out)
}

fn read_seed_hex() -> Result<Zeroizing<String>, ExitCode> {
    let use_stdin = env::args().any(|arg| arg == "--stdin");
    if use_stdin {
        let mut buf = Zeroizing::new(String::new());
        if std::io::stdin().read_to_string(&mut buf).is_err() {
            eprintln!("error: failed to read the hex seed from stdin");
            return Err(ExitCode::FAILURE);
        }
        Ok(buf)
    } else {
        match env::var("PAYKIT_REQUEST_SIGNING_KEY") {
            Ok(value) => Ok(Zeroizing::new(value)),
            Err(_) => {
                eprintln!(
                    "error: PAYKIT_REQUEST_SIGNING_KEY is not set (or pass --stdin to read the hex seed from stdin)"
                );
                Err(ExitCode::FAILURE)
            }
        }
    }
}

fn main() -> ExitCode {
    let seed_hex = match read_seed_hex() {
        Ok(seed_hex) => seed_hex,
        Err(code) => return code,
    };
    let Some(seed) = hex_decode_32(&seed_hex) else {
        eprintln!("error: the seed must be 64 hexadecimal characters (32-byte ed25519 seed)");
        return ExitCode::FAILURE;
    };
    println!("{}", pubky_public_key(&seed));
    ExitCode::SUCCESS
}

#[cfg(test)]
mod tests {
    use super::*;

    // RFC 8032 ed25519 test vector 1.
    const RFC8032_SEED_HEX: &str =
        "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60";
    const RFC8032_PUBLIC_HEX: &str =
        "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a";

    #[test]
    fn hex_decode_32_accepts_64_hex_chars() {
        let seed = hex_decode_32(RFC8032_SEED_HEX).expect("valid 64-char hex");
        assert_eq!(seed[0], 0x9d);
        assert_eq!(seed[31], 0x60);
    }

    #[test]
    fn hex_decode_32_rejects_bad_forms() {
        assert!(hex_decode_32("").is_none());
        assert!(hex_decode_32(&RFC8032_SEED_HEX[..63]).is_none());
        assert!(hex_decode_32(&format!("{RFC8032_SEED_HEX}00")).is_none());
        assert!(hex_decode_32(&RFC8032_SEED_HEX.replacen('9', "zz", 1)).is_none());
        // Surrounding whitespace is tolerated (stdin lines end with '\n').
        assert!(hex_decode_32(&format!("{RFC8032_SEED_HEX}\n")).is_some());
    }

    #[test]
    fn zbase32_encode_uses_exact_z_base_32_alphabet() {
        assert_eq!(zbase32_encode(&[0u8; 32]), "y".repeat(52));
        let encoded = zbase32_encode(&[0xffu8; 32]);
        assert!(
            encoded
                .chars()
                .all(|ch| b"ybndrfg8ejkmcpqxot1uwisza345h769".contains(&(ch as u8))),
            "output must stay inside the z-base-32 alphabet: {encoded}"
        );
    }

    #[test]
    fn pubky_public_key_is_prefixed_57_char_parser_form() {
        // Derive through ed25519-dalek and cross-check against the RFC 8032
        // public key, re-encoded as z-base-32 with our own encoder.
        let seed = hex_decode_32(RFC8032_SEED_HEX).unwrap();
        let expected_body = {
            let mut public = [0u8; 32];
            for (i, byte) in public.iter_mut().enumerate() {
                *byte = u8::from_str_radix(&RFC8032_PUBLIC_HEX[2 * i..2 * i + 2], 16).unwrap();
            }
            zbase32_encode(&public)
        };
        let key = pubky_public_key(&seed);
        assert_eq!(key, format!("pubky{expected_body}"));
        assert!(key.starts_with("pubky"), "key must carry the pubky prefix");
        assert_eq!(key.len(), 57, "parser-accepted form is exactly 57 chars");
        assert!(
            key[5..]
                .chars()
                .all(|ch| "ybndrfg8ejkmcpqxot1uwisza345h769".contains(ch)),
            "body must be 52 z-base-32 chars: {key}"
        );
    }
}
