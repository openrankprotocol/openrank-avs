use crate::{
    algos::et::convergence_check,
    merkle::{self, fixed::DenseMerkleTree, hash_leaf, Hash},
    tx::{
        compute,
        trust::{ScoreEntry, TrustEntry},
    },
    Domain, DomainHash,
};
use getset::Getters;
use sha3::Keccak256;
use std::collections::{BTreeMap, HashMap};
use tracing::info;

use super::{BaseRunner, Error as BaseError};

#[derive(Getters)]
#[getset(get = "pub")]
/// Struct containing the state of the verification runner
pub struct VerificationRunner {
    base: BaseRunner,
    compute_scores: HashMap<DomainHash, HashMap<Hash, Vec<ScoreEntry>>>,
    compute_tree: HashMap<DomainHash, HashMap<Hash, DenseMerkleTree<Keccak256>>>,
    commitments: HashMap<Hash, Hash>,
}

impl VerificationRunner {
    pub fn new(domains: &[Domain]) -> Self {
        let base = BaseRunner::new(domains);
        let mut compute_scores = HashMap::new();
        let mut compute_tree = HashMap::new();
        for domain in domains {
            let domain_hash = domain.to_hash();
            compute_scores.insert(domain_hash, HashMap::new());
            compute_tree.insert(domain_hash, HashMap::new());
        }
        Self {
            base,
            compute_scores,
            compute_tree,
            commitments: HashMap::new(),
        }
    }

    /// Update the state of trees for certain domain, with the given trust entries
    pub fn update_trust(
        &mut self,
        domain: Domain,
        trust_entries: Vec<TrustEntry>,
    ) -> Result<(), Error> {
        self.base
            .update_trust(domain, trust_entries)
            .map_err(Error::Base)
    }

    /// Update the state of trees for certain domain, with the given seed entries
    pub fn update_seed(
        &mut self,
        domain: Domain,
        seed_entries: Vec<ScoreEntry>,
    ) -> Result<(), Error> {
        self.base
            .update_seed(domain, seed_entries)
            .map_err(Error::Base)
    }

    /// Add a new commitment of certain assignment
    pub fn update_commitment(&mut self, compute_id: Hash, commitment: Hash) {
        self.commitments.insert(compute_id, commitment);
    }

    /// Add a new scores of certain transaction, for certain domain
    pub fn update_scores(
        &mut self,
        domain: Domain,
        compute_id: Hash,
        compute_scores: Vec<ScoreEntry>,
    ) -> Result<(), Error> {
        let score_values = self
            .compute_scores
            .get_mut(&domain.clone().to_hash())
            .ok_or(Error::ComputeScoresNotFoundWithDomain(domain.to_hash()))?;
        score_values.insert(compute_id, compute_scores);
        Ok(())
    }

    /// Get the list of completed assignments for certain domain
    pub fn verify_job(&mut self, domain: Domain, compute_id: Hash) -> Result<bool, Error> {
        info!("COMPLETED_ASSIGNMENT_SEARCH: {}", domain.to_hash());
        let commitment = self.commitments.get(&compute_id.clone()).unwrap();
        let cp_root = commitment.clone();

        self.create_compute_tree(domain.clone(), compute_id.clone())?;
        let (res_lt_root, res_compute_root) =
            self.get_root_hashes(domain.clone(), compute_id.clone())?;
        info!(
            "LT_ROOT: {}, COMPUTE_ROOT: {}",
            res_lt_root, res_compute_root
        );
        let is_root_equal = cp_root == res_compute_root;
        let is_converged = self.compute_verification(domain.clone(), compute_id.clone())?;
        info!(
            "COMPLETED_ASSIGNMENT, DOMAIN: {}, is_root_equal: {}, is_converged: {}",
            domain.to_hash(),
            is_root_equal,
            is_converged,
        );

        return Ok(is_root_equal && is_converged);
    }

    /// Build the compute tree of certain assignment, for certain domain.
    fn create_compute_tree(&mut self, domain: Domain, compute_id: Hash) -> Result<(), Error> {
        info!("CREATE_COMPUTE_TREE: {}", domain.to_hash());
        let compute_tree_map = self
            .compute_tree
            .get_mut(&domain.to_hash())
            .ok_or(Error::ComputeTreeNotFoundWithDomain(domain.to_hash()))?;
        let compute_scores = self
            .compute_scores
            .get(&domain.to_hash())
            .ok_or(Error::ComputeScoresNotFoundWithDomain(domain.to_hash()))?;
        let scores = compute_scores.get(&compute_id).unwrap();
        let score_entries: Vec<f32> = scores.iter().map(|x| *x.value()).collect();
        let score_hashes: Vec<Hash> = score_entries
            .iter()
            .map(|&x| hash_leaf::<Keccak256>(x.to_be_bytes().to_vec()))
            .collect();
        let compute_tree =
            DenseMerkleTree::<Keccak256>::new(score_hashes).map_err(Error::Merkle)?;
        info!(
            "COMPUTE_TREE_ROOT_HASH: {}",
            compute_tree.root().map_err(Error::Merkle)?
        );
        compute_tree_map.insert(compute_id, compute_tree);

        Ok(())
    }

    /// Get the verification result(True or False) of certain assignment, for certain domain
    fn compute_verification(&mut self, domain: Domain, compute_id: Hash) -> Result<bool, Error> {
        let compute_scores = self
            .compute_scores
            .get(&domain.to_hash())
            .ok_or(Error::ComputeScoresNotFoundWithDomain(domain.to_hash()))?;
        let domain_indices = self
            .base
            .indices
            .get(&domain.to_hash())
            .ok_or::<Error>(BaseError::IndicesNotFound(domain.to_hash()).into())?;
        let lt = self
            .base
            .local_trust
            .get(&domain.trust_namespace())
            .ok_or::<Error>(BaseError::LocalTrustNotFound(domain.trust_namespace()).into())?;
        let count = self
            .base
            .count
            .get(&domain.to_hash())
            .ok_or::<Error>(BaseError::CountNotFound(domain.to_hash()).into())?;
        let seed = self
            .base
            .seed_trust
            .get(&domain.seed_namespace())
            .ok_or::<Error>(BaseError::SeedTrustNotFound(domain.seed_namespace()).into())?;
        let scores = compute_scores.get(&compute_id).unwrap();
        let score_entries: BTreeMap<u64, f32> = {
            let mut score_entries_map: BTreeMap<u64, f32> = BTreeMap::new();
            for entry in scores {
                let i = domain_indices
                    .get(entry.id())
                    .ok_or(Error::DomainIndexNotFound(entry.id().clone()))?;
                score_entries_map.insert(*i, *entry.value());
            }
            score_entries_map
        };
        Ok(convergence_check(
            lt.clone(),
            seed.clone(),
            &score_entries,
            *count,
        ))
    }

    /// Get the local trust tree root and compute tree root of certain assignment, for certain domain
    pub fn get_root_hashes(
        &self,
        domain: Domain,
        assignment_id: Hash,
    ) -> Result<(Hash, Hash), Error> {
        let tree_roots = self.base.get_base_root_hashes(&domain)?;

        let compute_tree_map = self
            .compute_tree
            .get(&domain.to_hash())
            .ok_or(Error::ComputeTreeNotFoundWithDomain(domain.to_hash()))?;
        let compute_tree = compute_tree_map.get(&assignment_id).unwrap();
        let ct_tree_root = compute_tree.root().map_err(Error::Merkle)?;

        Ok((tree_roots, ct_tree_root))
    }
}

#[derive(thiserror::Error, Debug)]
pub enum Error {
    #[error("{0}")]
    Base(BaseError),
    #[error("compute_tree not found for domain: {0}")]
    ComputeTreeNotFoundWithDomain(DomainHash),
    #[error("compute_scores not found for domain: {0}")]
    ComputeScoresNotFoundWithDomain(DomainHash),
    #[error("active_assignments not found for domain: {0}")]
    ActiveAssignmentsNotFound(DomainHash),
    #[error("domain_indice not found for address: {0}")]
    DomainIndexNotFound(String),
    #[error("{0}")]
    Merkle(merkle::Error),
}

impl From<BaseError> for Error {
    fn from(err: BaseError) -> Self {
        Self::Base(err)
    }
}
