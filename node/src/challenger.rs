use crate::sol::OpenRankManager::{
    ChallengeEvent, ComputeRequestEvent, ComputeResultEvent, JobFinalized,
};
use alloy::eips::{BlockId, BlockNumberOrTag};
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

    println!("Running the node");

    // FixedBytes::as_slice(&self)

    loop {
        select! {
            compute_request_event = compute_request_stream.next() => {
                if let Some(res) = compute_request_event {
                    let (compute_req, log): (ComputeRequestEvent, Log) = res.unwrap();
                    println!("({} {} {})", compute_req.computeId, compute_req.trust_id, compute_req.seed_id);
                    println!("{:?}", log);

                    compute_request_map.insert(compute_req.computeId, compute_req);
                }
            }
            compute_result_event = compute_result_stream.next() => {
                if let Some(res) = compute_result_event {
                    let (compute_res, log): (ComputeResultEvent, Log) = res.unwrap();
                    println!("({} {} {})", compute_res.computeId, compute_res.commitment, compute_res.scores_id);
                    println!("{:?}", log);

                    let already_challenged = challanged_jobs_map.contains_key(&compute_res.computeId);
                    let already_finalized = finalized_jobs_map.contains_key(&compute_res.computeId);

                    let block = provider.get_block(BlockId::Number(BlockNumberOrTag::Latest)).await.unwrap().unwrap();
                    let challenge_period_expired = (block.header.timestamp - log.block_timestamp.unwrap()) < challenge_window._0;
                    if already_challenged || already_finalized || challenge_period_expired {
                        continue;
                    }

                    let compute_req = compute_request_map.get(&compute_res.computeId).unwrap();

                    let trust_path = format!("./trust/{:#x}", compute_req.trust_id);
                    let seed_path = format!("./seed/{:#x}", compute_req.seed_id);
                    let scores_path = format!("./scores/{:#x}", compute_res.scores_id);
                    let mut trust_file = File::create(&trust_path).unwrap();
                    let mut seed_file = File::create(&seed_path).unwrap();
                    let mut scores_file = File::create(&scores_path).unwrap();

                    let mut trust_res = s3_client
                        .get_object()
                        .bucket(bucket_name.clone())
                        .key(trust_path)
                        .send()
                        .await.unwrap();
                    let mut seed_res = s3_client
                        .get_object()
                        .bucket(bucket_name.clone())
                        .key(seed_path)
                        .send()
                        .await.unwrap();
                    let mut scores_res = s3_client
                        .get_object()
                        .bucket(bucket_name.clone())
                        .key(scores_path)
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

                    let mock_domain = Domain::default();
                    let mut runner = VerificationRunner::new(&[mock_domain.clone()]);
                    runner
                        .update_trust(mock_domain.clone(), trust_entries.to_vec())
                        .unwrap();
                    runner
                        .update_seed(mock_domain.clone(), seed_entries.to_vec())
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
                    if !result {
                        let required_stake = contract.STAKE().call().await.unwrap();
                        println!("{:?}", required_stake._0);
                        let res = contract
                            .submitChallenge(compute_res.computeId)
                            .value(required_stake._0)
                            .send()
                            .await
                            .unwrap();
                        println!("Tx Hash: {}", res.watch().await.unwrap());
                    }
                }
            }
            challenge_event = challenge_stream.next() => {
                if let Some(res) = challenge_event {
                    let (challenge, log): (ChallengeEvent, Log) = res.unwrap();
                    println!("({})", challenge.computeId);
                    println!("{:?}", log);

                    challanged_jobs_map.insert(challenge.computeId, log);
                }
            }
            job_finalised_event = job_finalised_stream.next() => {
                if let Some(res) = job_finalised_event {
                    let (job_finalized, log): (JobFinalized, Log) = res.unwrap();
                    println!("({})", job_finalized.computeId);
                    println!("{:?}", log);

                    finalized_jobs_map.insert(job_finalized.computeId, log);
                }
            }
        }
    }
}
