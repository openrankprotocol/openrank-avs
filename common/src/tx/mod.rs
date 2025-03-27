use alloy_rlp_derive::{RlpDecodable, RlpEncodable};
use getset::Getters;
use serde::{Deserialize, Serialize};

pub mod compute;
pub mod trust;

#[derive(
    Debug,
    Clone,
    PartialEq,
    Eq,
    Default,
    RlpDecodable,
    RlpEncodable,
    Serialize,
    Deserialize,
    Getters,
)]
#[getset(get = "pub")]
pub struct Signature {
    s: [u8; 32],
    r: [u8; 32],
    r_id: u8,
}

impl Signature {
    pub fn new(s: [u8; 32], r: [u8; 32], r_id: u8) -> Self {
        Self { s, r, r_id }
    }
}

#[cfg(test)]
mod test {
    use crate::tx::trust::{ScoreEntry, TrustEntry};
    use alloy_rlp::{encode, Decodable};

    #[test]
    fn test_decode_score_entry() {
        let se = ScoreEntry::default();
        let encoded_se = encode(se.clone());
        let decoded_se = ScoreEntry::decode(&mut encoded_se.as_slice()).unwrap();
        assert_eq!(se, decoded_se);
    }

    #[test]
    fn test_decode_trust_entry() {
        let te = TrustEntry::default();
        let encoded_te = encode(te.clone());
        let decoded_te = TrustEntry::decode(&mut encoded_te.as_slice()).unwrap();
        assert_eq!(te, decoded_te);
    }
}
