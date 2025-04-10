use crate::sol::OpenRankManager::{
    ChallengeEvent, ComputeRequestEvent, ComputeResultEvent, JobFinalized, MetaChallengeEvent,
    MetaComputeRequestEvent, MetaComputeResultEvent, MetaJobFinalized,
};
use crate::BUCKET_NAME;
use alloy::eips::{BlockId, BlockNumberOrTag};
use alloy::hex::{self, ToHexExt};
use alloy::primitives::Uint;
use alloy::providers::Provider;
use alloy::rpc::types::Log;
use aws_sdk_s3::Client;
use aws_sdk_s3::Error as AwsError;
use csv::StringRecord;
use futures_util::StreamExt;
use openrank_common::merkle::fixed::DenseMerkleTree;
use openrank_common::merkle::Hash;
use openrank_common::runners::verification_runner::VerificationRunner;
use openrank_common::tx::trust::{ScoreEntry, TrustEntry};
use openrank_common::Domain;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use sha3::Keccak256;
use std::collections::HashMap;
use std::fs::File;
use std::io::Write;
use tokio::select;
use tracing::{debug, error, info};

use crate::sol::OpenRankManager::OpenRankManagerInstance;

#[derive(Serialize, Deserialize)]
struct JobDescription {
    alpha: f32,
    trust_id: String,
    seed_id: String,
}

#[derive(Serialize, Deserialize)]
struct JobResult {
    scores_id: String,
    commitment: String,
}

pub async fn download_meta<T: DeserializeOwned>(
    client: &Client,
    meta_id: String,
) -> Result<T, AwsError> {
    let res = client
        .get_object()
        .bucket(BUCKET_NAME)
        .key(format!("meta/{}", meta_id))
        .send()
        .await?;
    let res_bytes = res.body.collect().await.unwrap();
    let meta: T = serde_json::from_slice(res_bytes.to_vec().as_slice()).unwrap();
    Ok(meta)
}

async fn handle_compute_result<PH: Provider>(
    contract: &OpenRankManagerInstance<(), PH>,
    provider: &PH,
    s3_client: &Client,
    compute_res: ComputeResultEvent,
    log: Log,
    compute_request_map: &HashMap<Uint<256, 4>, ComputeRequestEvent>,
    challanged_jobs_map: &HashMap<Uint<256, 4>, Log>,
    finalized_jobs_map: &HashMap<Uint<256, 4>, Log>,
    challenge_window: u64,
) {
    info!(
        "ComputeResultEvent: ComputeId({}), Commitment({:#}), ScoresId({:#})",
        compute_res.computeId, compute_res.commitment, compute_res.scores_id
    );
    debug!("Log: {:?}", log);

    let already_challenged = challanged_jobs_map.contains_key(&compute_res.computeId);
    let already_finalized = finalized_jobs_map.contains_key(&compute_res.computeId);

    let block = provider
        .get_block(BlockId::Number(BlockNumberOrTag::Latest))
        .await
        .unwrap()
        .unwrap();
    let log_block = provider
        .get_block(BlockId::Number(BlockNumberOrTag::Number(
            log.block_number.unwrap(),
        )))
        .await
        .unwrap()
        .unwrap();
    if already_challenged || already_finalized {
        return;
    }

    let compute_req = compute_request_map.get(&compute_res.computeId).unwrap();

    info!("Downloading data...");

    let trust_id_str = hex::encode(compute_req.trust_id.as_slice());
    let seed_id_str = hex::encode(compute_req.seed_id.as_slice());
    let scores_id_str = hex::encode(compute_res.scores_id.as_slice());
    let mut trust_file = File::create(&format!("./trust/{}", trust_id_str)).unwrap();
    let mut seed_file = File::create(&format!("./seed/{}", seed_id_str)).unwrap();
    let mut scores_file = File::create(&format!("./scores/{}", scores_id_str)).unwrap();

    let mut trust_res = s3_client
        .get_object()
        .bucket(BUCKET_NAME)
        .key(format!("trust/{}", trust_id_str))
        .send()
        .await
        .unwrap();
    let mut seed_res = s3_client
        .get_object()
        .bucket(BUCKET_NAME)
        .key(format!("seed/{}", seed_id_str))
        .send()
        .await
        .unwrap();
    let mut scores_res = s3_client
        .get_object()
        .bucket(BUCKET_NAME)
        .key(format!("scores/{}", scores_id_str))
        .send()
        .await
        .unwrap();

    while let Some(bytes) = trust_res.body.next().await {
        trust_file.write(&bytes.unwrap()).unwrap();
    }
    while let Some(bytes) = seed_res.body.next().await {
        seed_file.write(&bytes.unwrap()).unwrap();
    }
    while let Some(bytes) = scores_res.body.next().await {
        scores_file.write(&bytes.unwrap()).unwrap();
    }

    let trust_file = File::open(&format!("./trust/{}", trust_id_str)).unwrap();
    let seed_file = File::open(&format!("./seed/{}", seed_id_str)).unwrap();
    let scores_file = File::open(&format!("./scores/{}", scores_id_str)).unwrap();

    let mut trust_rdr = csv::Reader::from_reader(trust_file);
    let mut seed_rdr = csv::Reader::from_reader(seed_file);
    let mut scores_rdr = csv::Reader::from_reader(scores_file);

    let mut trust_entries = Vec::new();
    for result in trust_rdr.records() {
        let record: StringRecord = result.unwrap();
        let (from, to, value): (String, String, f32) = record.deserialize(None).unwrap();
        let trust_entry = TrustEntry::new(from, to, value);
        trust_entries.push(trust_entry);
    }

    let mut seed_entries = Vec::new();
    for result in seed_rdr.records() {
        let record: StringRecord = result.unwrap();
        let (id, value): (String, f32) = record.deserialize(None).unwrap();
        let seed_entry = ScoreEntry::new(id, value);
        seed_entries.push(seed_entry);
    }

    let mut scores_entries = Vec::new();
    for result in scores_rdr.records() {
        let record: StringRecord = result.unwrap();
        let (id, value): (String, f32) = record.deserialize(None).unwrap();
        let score_entry = ScoreEntry::new(id, value);
        scores_entries.push(score_entry);
    }

    info!("Starting core compute...");
    let mock_domain = Domain::default();
    let mut runner = VerificationRunner::new(&[mock_domain.clone()]);
    runner
        .update_trust_map(mock_domain.clone(), trust_entries.to_vec())
        .unwrap();
    runner
        .update_seed_map(mock_domain.clone(), seed_entries.to_vec())
        .unwrap();
    runner.update_commitment(
        Hash::from_bytes(compute_res.computeId.to_be_bytes()),
        Hash::from_slice(compute_res.commitment.as_slice()),
    );
    runner
        .update_scores(
            mock_domain.clone(),
            Hash::from_bytes(compute_res.computeId.to_be_bytes()),
            scores_entries,
        )
        .unwrap();
    let result = runner
        .verify_job(
            mock_domain,
            Hash::from_bytes(compute_res.computeId.to_be_bytes()),
        )
        .unwrap();
    info!("Core Compute verification completed. Result({})", result);

    let challenge_window_open =
        (block.header.timestamp - log_block.header.timestamp) < challenge_window;
    info!("Challenge window open: {}", challenge_window_open);

    if !result && challenge_window_open {
        info!("Submitting challenge. Calling 'submitChallenge'");
        // let required_stake = contract.STAKE().call().await.unwrap();
        let res = contract
            .submitChallenge(compute_res.computeId)
            // .value(required_stake._0) // Challenger stake not required
            .send()
            .await;
        if let Ok(res) = res {
            info!(
                "'submitChallenge' completed. Tx Hash({:#})",
                res.watch().await.unwrap()
            );
        } else {
            let err = res.unwrap_err();
            error!("'submitChallenge' failed. {}", err);
        }
    }
}

async fn handle_meta_compute_result<PH: Provider>(
    contract: &OpenRankManagerInstance<(), PH>,
    provider: &PH,
    s3_client: &Client,
    meta_compute_res: MetaComputeResultEvent,
    log: Log,
    meta_compute_request_map: &HashMap<Uint<256, 4>, MetaComputeRequestEvent>,
    meta_challanged_jobs_map: &HashMap<Uint<256, 4>, Log>,
    meta_finalized_jobs_map: &HashMap<Uint<256, 4>, Log>,
    challenge_window: u64,
) {
    let meta_result: Vec<JobResult> =
        download_meta(s3_client, meta_compute_res.resultsId.encode_hex())
            .await
            .unwrap();

    info!(
        "ComputeResultEvent: ComputeId({}), Commitment({:#}), ResultsId({:#})",
        meta_compute_res.computeId, meta_compute_res.commitment, meta_compute_res.resultsId
    );
    debug!("Log: {:?}", log);

    let already_challenged = meta_challanged_jobs_map.contains_key(&meta_compute_res.computeId);
    let already_finalized = meta_finalized_jobs_map.contains_key(&meta_compute_res.computeId);

    let block = provider
        .get_block(BlockId::Number(BlockNumberOrTag::Latest))
        .await
        .unwrap()
        .unwrap();
    let log_block = provider
        .get_block(BlockId::Number(BlockNumberOrTag::Number(
            log.block_number.unwrap(),
        )))
        .await
        .unwrap()
        .unwrap();
    if already_challenged || already_finalized {
        return;
    }

    let compute_req = meta_compute_request_map
        .get(&meta_compute_res.computeId)
        .unwrap();

    let job_description: Vec<JobDescription> =
        download_meta(s3_client, compute_req.jobDescriptionId.encode_hex())
            .await
            .unwrap();

    let mut global_result = true;
    let mut sub_job_failed = 0;
    let mut commitments = Vec::new();
    for (i, compute_res) in meta_result.iter().enumerate() {
        info!("Downloading data...");

        let mut trust_file =
            File::create(&format!("./trust/{}", job_description[i].trust_id)).unwrap();
        let mut seed_file =
            File::create(&format!("./seed/{}", job_description[i].seed_id)).unwrap();
        let mut scores_file = File::create(&format!("./scores/{}", compute_res.scores_id)).unwrap();

        let mut trust_res = s3_client
            .get_object()
            .bucket(BUCKET_NAME)
            .key(format!("trust/{}", job_description[i].trust_id))
            .send()
            .await
            .unwrap();
        let mut seed_res = s3_client
            .get_object()
            .bucket(BUCKET_NAME)
            .key(format!("seed/{}", job_description[i].seed_id))
            .send()
            .await
            .unwrap();
        let mut scores_res = s3_client
            .get_object()
            .bucket(BUCKET_NAME)
            .key(format!("scores/{}", compute_res.scores_id))
            .send()
            .await
            .unwrap();

        while let Some(bytes) = trust_res.body.next().await {
            trust_file.write(&bytes.unwrap()).unwrap();
        }
        while let Some(bytes) = seed_res.body.next().await {
            seed_file.write(&bytes.unwrap()).unwrap();
        }
        while let Some(bytes) = scores_res.body.next().await {
            scores_file.write(&bytes.unwrap()).unwrap();
        }

        let trust_file = File::open(&format!("./trust/{}", job_description[i].trust_id)).unwrap();
        let seed_file = File::open(&format!("./seed/{}", job_description[i].seed_id)).unwrap();
        let scores_file = File::open(&format!("./scores/{}", compute_res.scores_id)).unwrap();

        let mut trust_rdr = csv::Reader::from_reader(trust_file);
        let mut seed_rdr = csv::Reader::from_reader(seed_file);
        let mut scores_rdr = csv::Reader::from_reader(scores_file);

        let mut trust_entries = Vec::new();
        for result in trust_rdr.records() {
            let record: StringRecord = result.unwrap();
            let (from, to, value): (String, String, f32) = record.deserialize(None).unwrap();
            let trust_entry = TrustEntry::new(from, to, value);
            trust_entries.push(trust_entry);
        }

        let mut seed_entries = Vec::new();
        for result in seed_rdr.records() {
            let record: StringRecord = result.unwrap();
            let (id, value): (String, f32) = record.deserialize(None).unwrap();
            let seed_entry = ScoreEntry::new(id, value);
            seed_entries.push(seed_entry);
        }

        let mut scores_entries = Vec::new();
        for result in scores_rdr.records() {
            let record: StringRecord = result.unwrap();
            let (id, value): (String, f32) = record.deserialize(None).unwrap();
            let score_entry = ScoreEntry::new(id, value);
            scores_entries.push(score_entry);
        }

        info!("Starting core compute...");
        let mock_domain = Domain::default();
        let mut runner = VerificationRunner::new(&[mock_domain.clone()]);
        runner
            .update_trust_map(mock_domain.clone(), trust_entries.to_vec())
            .unwrap();
        runner
            .update_seed_map(mock_domain.clone(), seed_entries.to_vec())
            .unwrap();
        runner.update_commitment(
            Hash::from_slice(i.to_be_bytes().as_slice()),
            Hash::from_slice(
                hex::decode(compute_res.commitment.clone())
                    .unwrap()
                    .as_slice(),
            ),
        );
        runner
            .update_scores(
                mock_domain.clone(),
                Hash::from_slice(i.to_be_bytes().as_slice()),
                scores_entries,
            )
            .unwrap();
        let result = runner
            .verify_job(mock_domain, Hash::from_slice(i.to_be_bytes().as_slice()))
            .unwrap();
        info!("Core Compute verification completed. Result({})", result);

        if !result {
            global_result = false;
            sub_job_failed = i;
            break;
        }
        commitments.push(Hash::from_slice(
            hex::decode(compute_res.commitment.clone())
                .unwrap()
                .as_slice(),
        ));
    }

    let commitment_tree = DenseMerkleTree::<Keccak256>::new(commitments).unwrap();
    let meta_commitment = commitment_tree.root().unwrap();
    let commitment_result = meta_commitment.to_hex() == meta_compute_res.commitment.encode_hex();
    if !commitment_result {
        global_result = false;
    }

    let challenge_window_open =
        (block.header.timestamp - log_block.header.timestamp) < challenge_window;
    info!("Challenge window open: {}", challenge_window_open);

    if !global_result && challenge_window_open {
        info!("Submitting challenge. Calling 'metaSubmitChallenge'");
        let sub_job_failed_uint = Uint::from(sub_job_failed);
        // let required_stake = contract.STAKE().call().await.unwrap();
        let res = contract
            .submitMetaChallenge(meta_compute_res.computeId, sub_job_failed_uint)
            // .value(required_stake._0) // Challenger stake not required
            .send()
            .await;
        if let Ok(res) = res {
            info!(
                "'metaSubmitChallenge' completed. Tx Hash({:#})",
                res.watch().await.unwrap()
            );
        } else {
            let err = res.unwrap_err();
            error!("'metaSubmitChallenge' failed. {}", err);
        }
    }
}

pub async fn run<P: Provider>(
    contract: OpenRankManagerInstance<(), P>,
    provider: P,
    s3_client: Client,
) {
    let challenge_window = contract.CHALLENGE_WINDOW().call().await.unwrap();

    let compute_request_filter = contract
        .ComputeRequestEvent_filter()
        .from_block(BlockNumberOrTag::Latest)
        .watch()
        .await
        .unwrap();
    let compute_result_filter = contract
        .ComputeResultEvent_filter()
        .from_block(BlockNumberOrTag::Latest)
        .watch()
        .await
        .unwrap();
    let challenge_filter = contract
        .ChallengeEvent_filter()
        .from_block(BlockNumberOrTag::Latest)
        .watch()
        .await
        .unwrap();
    let job_finalised_filter = contract
        .JobFinalized_filter()
        .from_block(BlockNumberOrTag::Latest)
        .watch()
        .await
        .unwrap();

    // Meta jobs filters
    let meta_compute_request_filter = contract
        .MetaComputeRequestEvent_filter()
        .from_block(BlockNumberOrTag::Latest)
        .watch()
        .await
        .unwrap();
    let meta_compute_result_filter = contract
        .MetaComputeResultEvent_filter()
        .from_block(BlockNumberOrTag::Latest)
        .watch()
        .await
        .unwrap();
    let meta_challenge_filter = contract
        .MetaChallengeEvent_filter()
        .from_block(BlockNumberOrTag::Latest)
        .watch()
        .await
        .unwrap();
    let meta_job_finalised_filter = contract
        .MetaJobFinalized_filter()
        .from_block(BlockNumberOrTag::Latest)
        .watch()
        .await
        .unwrap();

    let mut compute_request_stream = compute_request_filter.into_stream();
    let mut compute_result_stream = compute_result_filter.into_stream();
    let mut challenge_stream = challenge_filter.into_stream();
    let mut job_finalised_stream = job_finalised_filter.into_stream();

    // Meta streams
    let mut meta_compute_request_stream = meta_compute_request_filter.into_stream();
    let mut meta_compute_result_stream = meta_compute_result_filter.into_stream();
    let mut meta_challenge_stream = meta_challenge_filter.into_stream();
    let mut meta_job_finalised_stream = meta_job_finalised_filter.into_stream();

    let mut compute_request_map = HashMap::new();
    let mut challanged_jobs_map = HashMap::new();
    let mut finalized_jobs_map = HashMap::new();

    let mut meta_compute_request_map = HashMap::new();
    let mut meta_challanged_jobs_map = HashMap::new();
    let mut meta_finalized_jobs_map = HashMap::new();

    info!("Running the challenger node...");

    loop {
        select! {
            compute_request_event = compute_request_stream.next() => {
                if let Some(res) = compute_request_event {
                    let (compute_req, log): (ComputeRequestEvent, Log) = res.unwrap();
                    info!(
                        "ComputeRequestEvent: ComputeId({}), TrustId({:#}), SeedId({:#})",
                        compute_req.computeId, compute_req.trust_id, compute_req.seed_id
                    );
                    debug!("{:?}", log);

                    compute_request_map.insert(compute_req.computeId, compute_req);
                }
            }
            compute_result_event = compute_result_stream.next() => {
                if let Some(res) = compute_result_event {
                    let (compute_res, log): (ComputeResultEvent, Log) = res.unwrap();
                    handle_compute_result(
                        &contract,
                        &provider,
                        &s3_client,
                        compute_res,
                        log,
                        &compute_request_map,
                        &challanged_jobs_map,
                        &finalized_jobs_map,
                        challenge_window._0
                    ).await;
                }
            }
            challenge_event = challenge_stream.next() => {
                if let Some(res) = challenge_event {
                    let (challenge, log): (ChallengeEvent, Log) = res.unwrap();
                    info!("ChallengeEvent: ComputeId({:#})", challenge.computeId);
                    debug!("{:?}", log);

                    challanged_jobs_map.insert(challenge.computeId, log);
                }
            }
            job_finalised_event = job_finalised_stream.next() => {
                if let Some(res) = job_finalised_event {
                    let (job_finalized, log): (JobFinalized, Log) = res.unwrap();
                    info!("JobFinalizedEvent: ComputeId({:#})", job_finalized.computeId);
                    debug!("{:?}", log);

                    finalized_jobs_map.insert(job_finalized.computeId, log);
                }
            }
            meta_compute_request_event = meta_compute_request_stream.next() => {
                if let Some(res) = meta_compute_request_event {
                    let (compute_req, log): (MetaComputeRequestEvent, Log) = res.unwrap();
                    info!(
                        "MetaComputeRequestEvent: ComputeId({}), JobDescriptionId({:#})",
                        compute_req.computeId, compute_req.jobDescriptionId
                    );
                    debug!("{:?}", log);

                    meta_compute_request_map.insert(compute_req.computeId, compute_req);
                }
            }
            meta_compute_result_event = meta_compute_result_stream.next() => {
                if let Some(res) = meta_compute_result_event {
                    let (compute_res, log): (MetaComputeResultEvent, Log) = res.unwrap();
                    handle_meta_compute_result(
                        &contract,
                        &provider,
                        &s3_client,
                        compute_res,
                        log,
                        &meta_compute_request_map,
                        &meta_challanged_jobs_map,
                        &meta_finalized_jobs_map,
                        challenge_window._0,
                    ).await
                }
            }
            meta_challenge_event = meta_challenge_stream.next() => {
                if let Some(res) = meta_challenge_event {
                    let (challenge, log): (MetaChallengeEvent, Log) = res.unwrap();
                    info!(
                        "MetaChallengeEvent: ComputeId({:#}) SubJobID({:#})",
                        challenge.computeId,
                        challenge.subJobId
                    );
                    debug!("{:?}", log);

                    meta_challanged_jobs_map.insert(challenge.computeId, log);
                }
            }
            meta_job_finalised_event = meta_job_finalised_stream.next() => {
                if let Some(res) = meta_job_finalised_event {
                    let (job_finalized, log): (MetaJobFinalized, Log) = res.unwrap();
                    info!("MetaJobFinalizedEvent: ComputeId({:#})", job_finalized.computeId);
                    debug!("{:?}", log);

                    meta_finalized_jobs_map.insert(job_finalized.computeId, log);
                }
            }
        }
    }
}
