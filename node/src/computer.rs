use crate::sol::OpenRankManager::{
    ChallengeEvent, ComputeRequestEvent, ComputeResultEvent, JobFinalized,
};
use alloy::eips::{BlockId, BlockNumberOrTag};
use alloy::hex;
use alloy::primitives::FixedBytes;
use alloy::providers::Provider;
use alloy::rpc::types::Log;
use aws_sdk_s3::primitives::ByteStream;
use aws_sdk_s3::Client;
use csv::StringRecord;
use futures_util::StreamExt;
use openrank_common::runners::compute_runner::ComputeRunner;
use openrank_common::tx::trust::{ScoreEntry, TrustEntry};
use openrank_common::Domain;
use sha3::{Digest, Keccak256};
use std::collections::HashMap;
use std::fs::File;
use std::io::Write;
use std::time::Duration;
use tokio::{select, time};

use crate::sol::OpenRankManager::OpenRankManagerInstance;

const TICK_DURATION: u64 = 30;

pub async fn run<PH: Provider, PW: Provider>(
    contract: OpenRankManagerInstance<(), PH>,
    contract_ws: OpenRankManagerInstance<(), PW>,
    provider_http: PH,
    s3_client: Client,
    bucket_name: String,
) {
    // Create filters for each event.
    let compute_request_filter = contract_ws
        .ComputeRequestEvent_filter()
        .watch()
        .await
        .unwrap();
    let compute_result_filter = contract_ws
        .ComputeResultEvent_filter()
        .from_block(BlockNumberOrTag::Latest)
        .watch()
        .await
        .unwrap();
    let challenge_filter = contract_ws
        .ChallengeEvent_filter()
        .from_block(BlockNumberOrTag::Latest)
        .watch()
        .await
        .unwrap();
    let job_finalised_filter = contract_ws
        .JobFinalized_filter()
        .from_block(BlockNumberOrTag::Latest)
        .watch()
        .await
        .unwrap();

    let mut compute_request_stream = compute_request_filter.into_stream();
    let mut compute_result_stream = compute_result_filter.into_stream();
    let mut challenge_stream = challenge_filter.into_stream();
    let mut job_finalised_stream = job_finalised_filter.into_stream();

    let mut interval = time::interval(Duration::from_secs(TICK_DURATION));
    let mut compute_result_map = HashMap::new();
    let mut finalized_jobs_map = HashMap::new();

    let challenge_window = contract.CHALLENGE_WINDOW().call().await.unwrap();

    println!("Running the computer node");

    loop {
        println!("loop");
        select! {
            compute_request_event = compute_request_stream.next() => {
                if let Some(res) = compute_request_event {
                    let (compute_req, log): (ComputeRequestEvent, Log) = res.unwrap();
                    println!("({} {} {})", compute_req.computeId, compute_req.trust_id, compute_req.seed_id);
                    println!("{:?}", log);

                    let trust_id_str = hex::encode(compute_req.trust_id.as_slice());
                    let seed_id_str = hex::encode(compute_req.seed_id.as_slice());
                    let mut trust_file = File::create(&format!("./trust/{}", trust_id_str)).unwrap();
                    let mut seed_file = File::create(&format!("./seed/{}", seed_id_str)).unwrap();

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


                    while let Some(bytes) = trust_res.body.next().await {
                        trust_file.write(&bytes.unwrap()).unwrap();
                    }

                    while let Some(bytes) = seed_res.body.next().await {
                        seed_file.write(&bytes.unwrap()).unwrap();
                    }

                    let trust_file = File::open(&format!("./trust/{}", trust_id_str)).unwrap();
                    let seed_file = File::open(&format!("./seed/{}", seed_id_str)).unwrap();

                    let mut trust_rdr = csv::Reader::from_reader(trust_file);
                    let mut seed_rdr = csv::Reader::from_reader(seed_file);

                    let mut trust_entries = Vec::new();
                    for result in trust_rdr.records() {
                        println!("{:?}", result);
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
                        let trust_entry = ScoreEntry::new(id, value);
                        seed_entries.push(trust_entry);
                    }

                    let mock_domain = Domain::default();
                    let mut runner = ComputeRunner::new(&[mock_domain.clone()]);
                    runner
                        .update_trust(mock_domain.clone(), trust_entries.to_vec())
                        .unwrap();
                    runner
                        .update_seed(mock_domain.clone(), seed_entries.to_vec())
                        .unwrap();
                    runner.compute(mock_domain.clone()).unwrap();
                    let scores = runner.get_compute_scores(mock_domain.clone()).unwrap();
                    runner.create_compute_tree(mock_domain.clone()).unwrap();
                    let score_entries: Vec<ScoreEntry> = scores.iter().flat_map(|x| x.clone().inner()).collect();
                    let (_, compute_root) = runner.get_root_hashes(mock_domain.clone()).unwrap();

                    let scores_vec = Vec::new();
                    let mut wtr = csv::Writer::from_writer(scores_vec);
                    score_entries.iter().for_each(|x| {
                        wtr.write_record(&[x.id(), x.value().to_string().as_str()]).unwrap();
                    });
                    let mut file_bytes = wtr.into_inner().unwrap();
                    let mut hasher = Keccak256::new();
                    hasher.write_all(&mut file_bytes).unwrap();
                    let scores_id = hasher.finalize().to_vec();

                    let body = ByteStream::from(file_bytes);
                    let res = s3_client
                        .put_object()
                        .bucket(bucket_name.clone())
                        .key(format!("scores/{}", hex::encode(scores_id.clone())))
                        .body(body)
                        .send()
                        .await.unwrap();

                    println!("{:?}", res);

                    let commitment_bytes = FixedBytes::from_slice(compute_root.inner());
                    let scores_id_bytes = FixedBytes::from_slice(scores_id.as_slice());

                    let required_stake = contract.STAKE().call().await.unwrap();
                    println!("{:?}", required_stake._0);
                    let res = contract
                        .submitComputeResult(compute_req.computeId, commitment_bytes, scores_id_bytes)
                        .value(required_stake._0)
                        .send()
                        .await
                        .unwrap();
                    println!("Tx Hash: {}", res.watch().await.unwrap());
                }
            }
            compute_result_event = compute_result_stream.next() => {
                if let Some(res) = compute_result_event {
                    let (compute_req, log): (ComputeResultEvent, Log) = res.unwrap();
                    println!("({} {} {})", compute_req.computeId, compute_req.commitment, compute_req.scores_id);
                    println!("{:?}", log);

                    compute_result_map.insert(compute_req.computeId, log);
                }
            }
            challenge_event = challenge_stream.next() => {
                if let Some(res) = challenge_event {
                    let (challenge, log): (ChallengeEvent, Log) = res.unwrap();
                    println!("({})", challenge.computeId);
                    println!("{:?}", log);
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
            _ = interval.tick() => {
                let block = provider_http.get_block(BlockId::Number(BlockNumberOrTag::Latest)).await.unwrap().unwrap();
                for (compute_id, log) in compute_result_map.iter() {
                    let log_block = provider_http.get_block(
                        BlockId::Number(BlockNumberOrTag::Number(log.block_number.unwrap()))
                    ).await.unwrap().unwrap();

                    let challenge_window_expired = block.header.timestamp - log_block.header.timestamp > challenge_window._0;
                    if !finalized_jobs_map.contains_key(compute_id) && challenge_window_expired {
                        let res = contract
                            .finalizeJob(*compute_id)
                            .send()
                            .await
                            .unwrap();
                        println!("Tx Hash: {}", res.watch().await.unwrap());
                    }
                }
            }
        }
    }
}
