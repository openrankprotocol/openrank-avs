use crate::sol::OpenRankManager::{
    ChallengeEvent, ComputeRequestEvent, ComputeResultEvent, JobFinalized,
};
use alloy::eips::{BlockId, BlockNumberOrTag};
use alloy::hex;
use alloy::providers::Provider;
use alloy::rpc::types::Log;
use aws_sdk_s3::Client;
use csv::StringRecord;
use futures_util::StreamExt;
use openrank_common::merkle::Hash;
use openrank_common::runners::verification_runner::VerificationRunner;
use openrank_common::tx::trust::{ScoreEntry, TrustEntry};
use openrank_common::Domain;
use std::collections::HashMap;
use std::fs::File;
use std::io::Write;
use tokio::select;
use tracing::{debug, error, info};

use crate::sol::OpenRankManager::OpenRankManagerInstance;

pub async fn run<P: Provider>(
    contract: OpenRankManagerInstance<(), P>,
    provider: P,
    s3_client: Client,
    bucket_name: String,
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

    let mut compute_request_stream = compute_request_filter.into_stream();
    let mut compute_result_stream = compute_result_filter.into_stream();
    let mut challenge_stream = challenge_filter.into_stream();
    let mut job_finalised_stream = job_finalised_filter.into_stream();

    let mut compute_request_map = HashMap::new();
    let mut challanged_jobs_map = HashMap::new();
    let mut finalized_jobs_map = HashMap::new();

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
                    info!(
                        "ComputeResultEvent: ComputeId({}), Commitment({:#}), ScoresId({:#})",
                        compute_res.computeId, compute_res.commitment, compute_res.scores_id
                    );
                    debug!("Log: {:?}", log);

                    let already_challenged = challanged_jobs_map.contains_key(&compute_res.computeId);
                    let already_finalized = finalized_jobs_map.contains_key(&compute_res.computeId);

                    let block = provider.get_block(BlockId::Number(BlockNumberOrTag::Latest)).await.unwrap().unwrap();
                    let log_block = provider.get_block(
                        BlockId::Number(BlockNumberOrTag::Number(log.block_number.unwrap()))
                    ).await.unwrap().unwrap();
                    if already_challenged || already_finalized {
                        continue;
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
                        .bucket(bucket_name.clone())
                        .key(format!("trust/{}", trust_id_str))
                        .send()
                        .await.unwrap();
                    let mut seed_res = s3_client
                        .get_object()
                        .bucket(bucket_name.clone())
                        .key(format!("seed/{}", seed_id_str))
                        .send()
                        .await.unwrap();
                    let mut scores_res = s3_client
                        .get_object()
                        .bucket(bucket_name.clone())
                        .key(format!("scores/{}", scores_id_str))
                        .send()
                        .await.unwrap();


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
                        let (from, to, value): (String, String, f32) =
                            record.deserialize(None).unwrap();
                        let trust_entry = TrustEntry::new(from, to, value);
                        trust_entries.push(trust_entry);
                    }

                    let mut seed_entries = Vec::new();
                    for result in seed_rdr.records() {
                        let record: StringRecord = result.unwrap();
                        let (id, value): (String, f32) =
                            record.deserialize(None).unwrap();
                        let seed_entry = ScoreEntry::new(id, value);
                        seed_entries.push(seed_entry);
                    }

                    let mut scores_entries = Vec::new();
                    for result in scores_rdr.records() {
                        let record: StringRecord = result.unwrap();
                        let (id, value): (String, f32) =
                            record.deserialize(None).unwrap();
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
                        Hash::from_slice(compute_res.commitment.as_slice())
                    );
                    runner.update_scores(
                        mock_domain.clone(),
                        Hash::from_bytes(compute_res.computeId.to_be_bytes()),
                        scores_entries
                    ).unwrap();
                    let result = runner.verify_job(mock_domain, Hash::from_bytes(compute_res.computeId.to_be_bytes())).unwrap();
                    info!("Core Compute verification completed. Result({})", result);

                    let challenge_window_open = (block.header.timestamp - log_block.header.timestamp) < challenge_window._0;
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
                            info!("'submitChallenge' completed. Tx Hash({:#})", res.watch().await.unwrap());
                        } else {
                            let err = res.unwrap_err();
                            error!("'submitChallenge' failed. {}", err);
                        }
                    }
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
        }
    }
}
