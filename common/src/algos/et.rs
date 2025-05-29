use rayon::iter::{IntoParallelRefIterator, ParallelIterator};
use std::{
    collections::{BTreeMap, HashSet},
    time::Instant,
};
use tracing::info;

use crate::runners::OutboundLocalTrust;

/// The trust weight given to the seed trust vector in the trust matrix calculation.
const PRE_TRUST_WEIGHT: f32 = 0.5;

/// The threshold value used for convergence check in the trust matrix calculation.
///
/// If the absolute difference between the current score and the next score is
/// less than `DELTA`, the score has converged.
const DELTA: f32 = 0.01;

fn find_reachable_peers(
    lt: &BTreeMap<u64, OutboundLocalTrust>,
    seed: &BTreeMap<u64, f32>,
) -> HashSet<u64> {
    let mut to_visit: Vec<&u64> = seed.keys().collect();
    let mut visited = HashSet::new();
    while let Some(i) = to_visit.pop() {
        if visited.contains(i) {
            continue;
        }
        visited.insert(*i);
        for (j, v) in lt.get(i).unwrap().outbound_trust_scores() {
            if !visited.contains(j) && *v > 0.0 {
                to_visit.push(j);
            }
        }
    }
    visited
}

/// Pre-processes a mutable local trust matrix `lt` by modifying it in-place:
///
/// - Removes self-trust (diagonal entries), as prohibited by EigenTrust.
fn pre_process(
    lt: &mut BTreeMap<u64, OutboundLocalTrust>,
    seed: &mut BTreeMap<u64, f32>,
    count: u64,
) {
    // Calculate the sum of all seed trust values.
    let sum: f32 = seed.par_iter().map(|(_, v)| v).sum();

    if sum == 0.0 {
        for i in 0..count {
            seed.insert(i, 1.0);
        }
    }

    for from in 0..count {
        let sum = lt.get(&from).map(|lt| lt.outbound_sum()).unwrap_or(&0.0);
        // If peer does not have outbound trust,
        // his trust will be distributed to seed peers based on their seed/pre-trust
        if *sum == 0.0 {
            let single_lt = OutboundLocalTrust::from_score_map(seed);
            lt.insert(from, single_lt);
        }
    }

    let reachable = find_reachable_peers(lt, seed);
    lt.retain(|from, _| reachable.contains(from));
}

/// Normalizes the `lt` matrix by dividing each element by the sum of its row.
fn normalise_lt(lt: &BTreeMap<u64, OutboundLocalTrust>) -> BTreeMap<u64, OutboundLocalTrust> {
    lt.par_iter()
        .fold(BTreeMap::new, |mut lt_norm, (from, from_map)| {
            let from_map_norm = from_map.norm();
            lt_norm.insert(*from, from_map_norm);
            lt_norm
        })
        .reduce(BTreeMap::new, |mut acc, lt_norm| {
            acc.extend(lt_norm);
            acc
        })
}

/// Normalizes the scores, to eliminate the rounding error
fn normalise_scores(scores: &BTreeMap<u64, f32>) -> BTreeMap<u64, f32> {
    // Calculate the sum of all seed trust values.
    let sum: f32 = scores.par_iter().map(|(_, v)| v).sum();

    scores
        .par_iter()
        .fold(BTreeMap::new, |mut scores, (i, value)| {
            scores.insert(*i, *value / sum);
            scores
        })
        .reduce(BTreeMap::new, |mut acc, scores| {
            acc.extend(scores);
            acc
        })
}

/// Performs the positive EigenTrust algorithm on the given local trust matrix (`lt`) and seed trust values (`seed`).
/// The algorithm iteratively updates the scores of each node until convergence.
/// It returns a vector of tuples containing the node ID and the final score.
pub fn positive_run(
    mut lt: BTreeMap<u64, OutboundLocalTrust>,
    mut seed: BTreeMap<u64, f32>,
    count: u64,
) -> Vec<(u64, f32)> {
    let start = Instant::now();
    info!(
        "PRE_PROCESS_START, LT_SIZE: {}, SEED_SIZE: {}",
        lt.len(),
        seed.len()
    );
    pre_process(&mut lt, &mut seed, count);
    info!(
        "PRE_PROCESS_FINISH: {:?}, LT_SIZE: {}, SEED_SIZE: {}",
        start.elapsed(),
        lt.len(),
        seed.len()
    );
    info!("NORMALISE_LT_SEED");
    seed = normalise_scores(&seed);
    lt = normalise_lt(&lt);

    // Initialize the scores of each node to the seed trust values.
    let mut scores = seed.clone();
    // Iterate until convergence.

    info!("COMPUTE_START");
    let start = Instant::now();
    let mut i = 0;
    loop {
        // Calculate the n+1 scores of each node.
        let n_plus_1_scores = iteration(&lt, &seed, &scores);
        // Normalise n+1 scores.
        let n_plus_1_scores = normalise_scores(&n_plus_1_scores);
        // Calculate the n+2 scores of each node.
        let n_plus_2_scores = iteration(&lt, &seed, &n_plus_1_scores);
        // Normalise n+2 scores
        let n_plus_2_scores = normalise_scores(&n_plus_2_scores);
        // Check for convergence.
        let (is_converged, delta) = is_converged(&n_plus_1_scores, &n_plus_2_scores);
        info!("ITER: {}, CONVERGED: {}, DELTA: {}", i, is_converged, delta);
        if is_converged {
            // Return previous iteration, since the scores are converged.
            scores = n_plus_1_scores;
            break;
        } else {
            // Update the scores with the latest scores.
            scores = n_plus_2_scores;
        }
        i += 1;
    }
    info!(
        "COMPUTE_END: {:?}, NUM_SCORES: {}, NUM_ITER: {}",
        start.elapsed(),
        scores.len(),
        i
    );
    scores.into_iter().collect()
}

/// Given the previous scores (`scores`) and the next scores (`next_scores`), checks if the scores have converged.
/// It returns `true` if the scores have converged and `false` otherwise.
pub fn is_converged(scores: &BTreeMap<u64, f32>, next_scores: &BTreeMap<u64, f32>) -> (bool, f32) {
    // Iterate over the scores and check if they have converged.
    let total_delta = scores
        .par_iter()
        .fold(
            || 0.0,
            |sum, (i, v)| {
                // Get the next score of the node.
                let next_score = next_scores.get(i).unwrap_or(&0.0);
                (next_score - v).abs() + sum
            },
        )
        .reduce(|| 0.0, |sum_a, sum_b| sum_a + sum_b);
    (total_delta <= DELTA, total_delta)
}

/// It performs a single iteration of the positive run EigenTrust algorithm on the given local trust matrix (`lt`),
/// seed trust values (`seed`), and previous scores (`scores`).
/// It returns `true` if the scores have converged and `false` otherwise.
pub fn convergence_check(
    mut lt: BTreeMap<u64, OutboundLocalTrust>,
    mut seed: BTreeMap<u64, f32>,
    scores: &BTreeMap<u64, f32>,
    count: u64,
) -> bool {
    info!(
        "PRE_PROCESS_START, LT_SIZE: {}, SEED_SIZE: {}",
        lt.len(),
        seed.len()
    );
    pre_process(&mut lt, &mut seed, count);
    info!(
        "PRE_PROCESS_END. LT_SIZE: {}, SEED_SIZE: {}",
        lt.len(),
        seed.len()
    );
    info!("NORMALISE_LT_SEED");
    seed = normalise_scores(&seed);
    lt = normalise_lt(&lt);

    info!("CONVERGENCE_START");
    let start = Instant::now();
    // Calculate the next scores of each node
    let next_scores = iteration(&lt, &seed, scores);
    // Normalize the weighted next scores
    let next_scores = normalise_scores(&next_scores);

    // Check if the scores have converged
    let (is_converged, delta) = is_converged(scores, &next_scores);
    info!(
        "CONVERGENCE_RESULT: {:?}, DELTA: {}, TIME: {:?}",
        is_converged,
        delta,
        start.elapsed(),
    );
    is_converged
}

fn iteration(
    lt: &BTreeMap<u64, OutboundLocalTrust>,
    seed: &BTreeMap<u64, f32>,
    scores: &BTreeMap<u64, f32>,
) -> BTreeMap<u64, f32> {
    // Step 1-3: Compute raw contributions per node
    let mut next_scores = lt
        .par_iter()
        .map(|(from, from_map)| {
            let origin_score = scores.get(from).unwrap_or(&0.0);
            let mut partial = BTreeMap::new();
            for (to, value) in from_map.outbound_trust_scores() {
                let score = *value * origin_score;
                let to_score = partial.get(to).unwrap_or(&0.0);
                partial.insert(*to, to_score + score);
            }
            partial
        })
        .reduce(
            || BTreeMap::new(),
            |mut acc, partial| {
                for (k, v) in partial {
                    *acc.entry(k).or_insert(0.0) += v;
                }
                acc
            },
        );

    // Step 4: Apply pre-trust weighted normalization
    for (i, v) in &mut next_scores {
        let pre_trust = seed.get(i).unwrap_or(&0.0);
        *v = PRE_TRUST_WEIGHT * pre_trust + *v * (1.0 - PRE_TRUST_WEIGHT);
    }

    next_scores
}
