use crate::tx::trust::ScoreEntry;
use crate::{merkle::Hash, DomainHash};
use alloy_primitives::Address;
use alloy_rlp_derive::{RlpDecodable, RlpEncodable};
use getset::Getters;
use serde::{Deserialize, Serialize};

#[derive(
    Debug, Clone, Default, PartialEq, Serialize, Deserialize, RlpEncodable, RlpDecodable, Getters,
)]
#[getset(get = "pub")]
pub struct Commitment {
    assignment_id: Hash,
    lt_root_hash: Hash,
    compute_root_hash: Hash,
    scores_id: Hash,
}

impl Commitment {
    pub fn new(
        assignment_id: Hash,
        lt_root_hash: Hash,
        compute_root_hash: Hash,
        scores_id: Hash,
    ) -> Self {
        Self {
            assignment_id,
            lt_root_hash,
            compute_root_hash,
            scores_id,
        }
    }
}

#[derive(
    Debug, Clone, Default, PartialEq, Serialize, Deserialize, RlpEncodable, RlpDecodable, Getters,
)]
#[getset(get = "pub")]
pub struct Scores {
    entries: Vec<ScoreEntry>,
}

impl Scores {
    pub fn new(entries: Vec<ScoreEntry>) -> Self {
        Self { entries }
    }
}

#[derive(
    Debug, Clone, PartialEq, Default, Serialize, Deserialize, RlpEncodable, RlpDecodable, Getters,
)]
#[getset(get = "pub")]
#[rlp(trailing)]
pub struct Request {
    domain_id: DomainHash,
    block_height: u32,
    compute_id: Hash,
    seq_number: Option<u64>,
}

impl Request {
    pub fn new(domain_id: DomainHash, block_height: u32, compute_id: Hash) -> Self {
        Self {
            domain_id,
            block_height,
            compute_id,
            seq_number: None,
        }
    }

    pub fn set_seq_number(&mut self, seq_number: u64) {
        self.seq_number = Some(seq_number)
    }
}

#[derive(
    Debug, Clone, PartialEq, Default, Serialize, Deserialize, RlpEncodable, RlpDecodable, Getters,
)]
#[getset(get = "pub")]
pub struct Assignment {
    request_id: Hash,
    assigned_compute_node: Address,
    assigned_verifier_nodes: Vec<Address>,
}

impl Assignment {
    pub fn new(
        request_id: Hash,
        assigned_compute_node: Address,
        assigned_verifier_nodes: Vec<Address>,
    ) -> Self {
        Self {
            request_id,
            assigned_compute_node,
            assigned_verifier_nodes,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, RlpEncodable, RlpDecodable, Getters)]
#[getset(get = "pub")]
pub struct Verification {
    assignment_id: Hash,
    verification_result: bool,
}

impl Verification {
    pub fn new(assignment_id: Hash, verification_result: bool) -> Self {
        Self {
            assignment_id,
            verification_result,
        }
    }
}

impl Default for Verification {
    fn default() -> Self {
        Self {
            assignment_id: Hash::default(),
            verification_result: true,
        }
    }
}
