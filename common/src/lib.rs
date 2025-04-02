pub mod algos;
pub mod logs;
pub mod merkle;
pub mod runners;
pub mod tx;

use crate::tx::trust::OwnedNamespace;
use alloy::hex::{self, FromHex};
use alloy_primitives::Address;
use alloy_rlp_derive::{RlpDecodable, RlpEncodable};
use getset::Getters;
use k256::ecdsa::SigningKey;
use merkle::hash_leaf;
use serde::{Deserialize, Serialize};
use sha3::Keccak256;
use std::{
    fmt::{Display, Formatter, Result as FmtResult},
    hash::{DefaultHasher, Hasher},
};

#[derive(
    Clone,
    Copy,
    Debug,
    Default,
    Hash,
    PartialEq,
    Eq,
    RlpEncodable,
    RlpDecodable,
    Serialize,
    Deserialize,
)]
/// Hash of the [Domain].
pub struct DomainHash(#[serde(with = "hex")] [u8; 8]);

impl DomainHash {
    /// Convert the hash value to a hex string.
    pub fn to_hex(self) -> String {
        hex::encode(self.0)
    }

    /// Get the inner value of the hash.
    pub fn inner(self) -> [u8; 8] {
        self.0
    }
}

impl FromHex for DomainHash {
    type Error = hex::FromHexError;

    /// Convert a hex string to a [DomainHash].
    fn from_hex<T: AsRef<[u8]>>(hex: T) -> Result<Self, Self::Error> {
        Ok(DomainHash(<[u8; 8]>::from_hex(hex)?))
    }
}

impl From<[u8; 8]> for DomainHash {
    fn from(value: [u8; 8]) -> Self {
        Self(value)
    }
}

impl Display for DomainHash {
    fn fmt(&self, f: &mut Formatter<'_>) -> FmtResult {
        write!(f, "{}", format_hex(self.to_hex()))
    }
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, Getters)]
#[getset(get = "pub")]
/// Domain of the openrank network. Consists of a trust namespace and a seed namespace + algorithm id.
pub struct Domain {
    /// Address of the trust namespace owner.
    trust_owner: Address,
    /// ID of the trust namespace.
    trust_id: u32,
    /// Address of the seed namespace owner.
    seed_owner: Address,
    /// ID of the seed namespace.
    seed_id: u32,
    /// ID of the algorithm used for the domain.
    algo_id: u64,
}

impl Domain {
    pub fn new(
        trust_owner: Address,
        trust_id: u32,
        seed_owner: Address,
        seed_id: u32,
        algo_id: u64,
    ) -> Self {
        Self {
            trust_owner,
            trust_id,
            seed_owner,
            seed_id,
            algo_id,
        }
    }

    /// Returns the trust namespace of the domain.
    pub fn trust_namespace(&self) -> OwnedNamespace {
        OwnedNamespace::new(self.trust_owner, self.trust_id)
    }

    /// Returns the seed namespace of the domain.
    pub fn seed_namespace(&self) -> OwnedNamespace {
        OwnedNamespace::new(self.seed_owner, self.seed_id)
    }

    /// Returns the domain hash, created from the trust and seed namespace + algo id.
    pub fn to_hash(&self) -> DomainHash {
        let mut s = DefaultHasher::new();
        s.write(self.trust_owner.as_slice());
        s.write(&self.trust_id.to_be_bytes());
        s.write(self.seed_owner.as_slice());
        s.write(&self.seed_id.to_be_bytes());
        s.write(&self.algo_id.to_be_bytes());
        let res = s.finish();
        DomainHash(res.to_be_bytes())
    }
}

/// Generates an address from a signing key.
/// The address is the first 20 bytes of the keccak256 hash of the public key,
/// which is compatible with Ethereum addresses.
pub fn address_from_sk(sk: &SigningKey) -> Address {
    // TODO: Update to a new method that correctly matches the Ethereum address format
    let vk = sk.verifying_key();
    let uncompressed_point = vk.to_encoded_point(false);
    let vk_bytes = uncompressed_point.as_bytes();

    let hash = hash_leaf::<Keccak256>(vk_bytes[1..].to_vec());
    let mut address_bytes = [0u8; 20];
    address_bytes.copy_from_slice(&hash.inner()[12..]);

    Address::from_slice(&address_bytes)
}

pub fn format_hex(hex: String) -> String {
    if hex.len() < 8 {
        return format!("0x{}", hex);
    }

    let first_part = hex.get(..4).unwrap();
    let second_part = hex.get((hex.len() - 4)..).unwrap();

    format!("0x{}...{}", first_part, second_part)
}

#[cfg(test)]
mod test {
    use crate::*;
    use alloy_primitives::Address;

    #[test]
    fn test_address_from_sk() {
        // reference:
        //  https://github.com/ethereum/tests/blob/develop/BasicTests/keyaddrtest.json
        //  https://github.com/ethereum/execution-spec-tests/blob/main/src/ethereum_test_base_types/constants.py
        let test_vectors: Vec<(&str, &str)> = vec![
            (
                "c85ef7d79691fe79573b1a7064c19c1a9819ebdbd1faaab1a8ec92344438aaf4",
                "cd2a3d9f938e13cd947ec05abc7fe734df8dd826",
            ),
            (
                "c87f65ff3f271bf5dc8643484f66b200109caffe4bf98c4cb393dc35740b28c0",
                "13978aee95f38490e9769c39b2773ed763d9cd5f",
            ),
            (
                "45A915E4D060149EB4365960E6A7A45F334393093061116B197E3240065FF2D8",
                "a94f5374fce5edbc8e2a8697c15331677e6ebf0b",
            ),
            (
                "9E7645D0CFD9C3A04EB7A9DB59A4EB7D359F2E75C9164A9D6B9A7D54E1B6A36F",
                "8a0a19589531694250d570040a0c4b74576919b8",
            ),
        ];

        for (key_bytes_hex, expected_addr_hex) in test_vectors {
            let sk_bytes = hex::decode(key_bytes_hex).unwrap();
            let sk = SigningKey::from_slice(&sk_bytes).unwrap();
            let address = address_from_sk(&sk);
            assert_eq!(address.0.to_vec(), hex::decode(expected_addr_hex).unwrap());
        }
    }

    #[test]
    fn test_domain_to_hash() {
        let domain = Domain::new(Address::default(), 1, Address::default(), 1, 1);

        let hash = domain.to_hash();
        assert_eq!(hash.to_hex(), "00902259a9dc1a51");
    }
}
