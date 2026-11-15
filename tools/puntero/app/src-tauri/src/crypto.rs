//! The box every message travels in after the handshake: NaCl secretbox (XSalsa20-Poly1305), the same
//! construction tweetnacl's `nacl.secretbox` uses on the phone. A frame is the 24-byte random nonce
//! followed by the sealed bytes.

use crypto_secretbox::aead::{Aead, KeyInit};
use crypto_secretbox::{Key, Nonce, XSalsa20Poly1305};
use sha2::{Digest, Sha512};

pub const KEY_LEN: usize = 32;
const NONCE_LEN: usize = 24;

pub type SecretKey = [u8; KEY_LEN];

pub fn random<const N: usize>() -> [u8; N] {
    let mut bytes = [0u8; N];
    getrandom::fill(&mut bytes).expect("the system's random number generator");
    bytes
}

pub fn seal(key: &SecretKey, plain: &[u8]) -> Vec<u8> {
    let nonce: [u8; NONCE_LEN] = random();
    let cipher = XSalsa20Poly1305::new(Key::from_slice(key));
    let sealed = cipher
        .encrypt(Nonce::from_slice(&nonce), plain)
        .expect("sealing never fails with a valid key");
    let mut frame = Vec::with_capacity(NONCE_LEN + sealed.len());
    frame.extend_from_slice(&nonce);
    frame.extend_from_slice(&sealed);
    frame
}

pub fn open(key: &SecretKey, frame: &[u8]) -> Option<Vec<u8>> {
    if frame.len() < NONCE_LEN + 16 {
        return None;
    }
    let (nonce, sealed) = frame.split_at(NONCE_LEN);
    XSalsa20Poly1305::new(Key::from_slice(key))
        .decrypt(Nonce::from_slice(nonce), sealed)
        .ok()
}

/// The key a phone seals its pairing request with when it types the 6-digit code instead of scanning
/// the QR (the QR carries a full random key). Weaker, so the code changes after a few failed tries.
/// SHA-512 (its first 32 bytes) because that is the hash tweetnacl has on the phone.
pub fn code_key(code: &str) -> SecretKey {
    let mut hash = Sha512::new();
    hash.update(b"puntero-pair-v1:");
    hash.update(code.as_bytes());
    let digest = hash.finalize();
    let mut key = [0u8; KEY_LEN];
    key.copy_from_slice(&digest[..KEY_LEN]);
    key
}

#[cfg(test)]
mod tests {
    use super::*;

    const CODE_KEY_123456: &str = "22cc019b281db5c71e0f88d6fff25213fe93728b06f51a603aa49aaf63ec8292";

    #[test]
    fn seals_and_opens() {
        let key: SecretKey = random();
        let frame = seal(&key, b"{\"t\":\"m\",\"x\":1,\"y\":2}");
        assert_eq!(open(&key, &frame).unwrap(), b"{\"t\":\"m\",\"x\":1,\"y\":2}");
    }

    #[test]
    fn rejects_other_keys_and_tampering() {
        let key: SecretKey = random();
        let mut frame = seal(&key, b"hola");
        assert!(open(&random(), &frame).is_none());
        let last = frame.len() - 1;
        frame[last] ^= 1;
        assert!(open(&key, &frame).is_none());
        assert!(open(&key, &[0u8; 10]).is_none());
    }

    #[test]
    fn opens_a_tweetnacl_frame() {
        // nacl.secretbox(utf8("hola"), nonce = 24 x 0x01, key = 32 x 0x02), made with tweetnacl 1.0.3
        let mut frame = vec![1u8; 24];
        frame.extend(hex::decode("0254f01825de81034e55f4adbc235e6c4ab86845").unwrap());
        assert_eq!(open(&[2u8; 32], &frame).unwrap(), b"hola");
    }

    #[test]
    fn code_key_is_stable() {
        // nacl.hash(utf8("puntero-pair-v1:123456")).slice(0, 32) in tweetnacl
        assert_eq!(hex::encode(code_key("123456")), CODE_KEY_123456);
        assert_eq!(code_key("123456"), code_key("123456"));
        assert_ne!(code_key("123456"), code_key("123457"));
    }
}
