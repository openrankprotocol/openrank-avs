use crate::sol::OpenRankManager::{
    ChallengeEvent, ComputeRequestEvent, ComputeResultEvent, JobFinalized, MetaChallengeEvent,
    MetaComputeRequestEvent, MetaComputeResultEvent, MetaJobFinalized,
};
use crate::BUCKET_NAME;
use alloy::eips::{BlockId, BlockNumberOrTag};
use alloy::hex::{self, ToHexExt};
use alloy::primitives::{FixedBytes, Uint};
use alloy::providers::Provider;
use alloy::rpc::types::Log;
use aws_sdk_s3::primitives::ByteStream;
use aws_sdk_s3::Client;
use aws_sdk_s3::Error as AwsError;
use csv::StringRecord;
use futures_util::StreamExt;
use openrank_common::merkle::fixed::DenseMerkleTree;
use openrank_common::merkle::Hash;
use openrank_common::runners::compute_runner::ComputeRunner;
use openrank_common::tx::trust::{ScoreEntry, TrustEntry};
use openrank_common::Domain;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use sha3::{Digest, Keccak256};
use std::collections::HashMap;
use std::fs::File;
use std::io::Write;
use std::time::{Duration, Instant};
use tokio::{select, time};
use tracing::{debug, error, info};

use crate::sol::OpenRankManager::OpenRankManagerInstance;

const TICK_DURATION: u64 = 30;

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

impl JobResult {
    pub fn new(scores_id: String, commitment: String) -> Self {
        Self {
            scores_id,
            commitment,
        }
    }
}

pub async fn upload_meta<T: Serialize>(client: &Client, meta: T) -> Result<String, AwsError> {
    let mut bytes = serde_json::to_vec(&meta).unwrap();
    let body = ByteStream::from(bytes.clone());

    let mut hasher = Keccak256::new();
    hasher.write_all(&mut bytes).unwrap();
    let hash = hasher.finalize().to_vec();
    client
        .put_object()
        .bucket(BUCKET_NAME)
        .key(format!("meta/{}", hex::encode(hash.clone())))
        .body(body)
        .send()
        .await?;
    Ok(hex::encode(hash))
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

async fn handle_compute_request<PH: Provider>(
    contract: &OpenRankManagerInstance<(), PH>,
    s3_client: &Client,
    compute_req: ComputeRequestEvent,
    log: Log,
) {
    let start = Instant::now();
    info!(
        "ComputeRequestEvent: ComputeId({}), TrustId({:#}), SeedId({:#})",
        compute_req.computeId, compute_req.trust_id, compute_req.seed_id
    );
    debug!("Log: {:?}", log);

    let trust_id_str = hex::encode(compute_req.trust_id.as_slice());
    let seed_id_str = hex::encode(compute_req.seed_id.as_slice());
    let mut trust_file = File::create(&format!("./trust/{}", trust_id_str)).unwrap();
    let mut seed_file = File::create(&format!("./seed/{}", seed_id_str)).unwrap();

    info!("Downloading data...");
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
        let record: StringRecord = result.unwrap();
        let (from, to, value): (String, String, f32) = record.deserialize(None).unwrap();
        let trust_entry = TrustEntry::new(from, to, value);
        trust_entries.push(trust_entry);
    }

    let mut seed_entries = Vec::new();
    for result in seed_rdr.records() {
        let record: StringRecord = result.unwrap();
        let (id, value): (String, f32) = record.deserialize(None).unwrap();
        let trust_entry = ScoreEntry::new(id, value);
        seed_entries.push(trust_entry);
    }

    info!("Starting core compute...");
    let mock_domain = Domain::default();
    let mut runner = ComputeRunner::new(&[mock_domain.clone()]);
    runner
        .update_trust_map(mock_domain.clone(), trust_entries.to_vec())
        .unwrap();
    runner
        .update_seed_map(mock_domain.clone(), seed_entries.to_vec())
        .unwrap();
    runner.compute(mock_domain.clone()).unwrap();
    let scores = runner.get_compute_scores(mock_domain.clone()).unwrap();
    runner.create_compute_tree(mock_domain.clone()).unwrap();
    let (_, compute_root) = runner.get_root_hashes(mock_domain.clone()).unwrap();

    let scores_vec = Vec::new();
    let mut wtr = csv::Writer::from_writer(scores_vec);
    wtr.write_record(&["i", "v"]).unwrap();
    scores.iter().for_each(|x| {
        wtr.write_record(&[x.id(), x.value().to_string().as_str()])
            .unwrap();
    });
    let mut file_bytes = wtr.into_inner().unwrap();
    let mut hasher = Keccak256::new();
    hasher.write_all(&mut file_bytes).unwrap();
    let scores_id = hasher.finalize().to_vec();

    let commitment_bytes = FixedBytes::from_slice(compute_root.inner());
    let scores_id_bytes = FixedBytes::from_slice(scores_id.as_slice());

    info!(
        "Core compute completed: ScoresId({:#}), Commitment({:#})",
        scores_id_bytes, commitment_bytes
    );
    info!("Uploading scores data...");

    let body = ByteStream::from(file_bytes);
    s3_client
        .put_object()
        .bucket(BUCKET_NAME)
        .key(format!("scores/{}", hex::encode(scores_id.clone())))
        .body(body)
        .send()
        .await
        .unwrap();

    info!("Upload scores complete...");

    let elapsed = start.elapsed();
    info!("Total compute time: {:?}", elapsed);

    info!("Posting commitment on-chain. Calling: 'submitComputeResult'");
    let required_stake = contract.STAKE().call().await.unwrap();
    let res = contract
        .submitComputeResult(compute_req.computeId, commitment_bytes, scores_id_bytes)
        .value(required_stake._0)
        .send()
        .await
        .unwrap();
    info!(
        "'submitComputeResult' completed: Tx Hash({:#})",
        res.watch().await.unwrap()
    );
}

async fn handle_meta_compute_request<PH: Provider>(
    contract: &OpenRankManagerInstance<(), PH>,
    s3_client: &Client,
    meta_compute_req: MetaComputeRequestEvent,
    log: Log,
) {
    let start = Instant::now();
    let meta_job: Vec<JobDescription> =
        download_meta(s3_client, meta_compute_req.jobDescriptionId.encode_hex())
            .await
            .unwrap();
    info!(
        "MetaComputeRequestEvent: JobDescriptionId({})",
        meta_compute_req.jobDescriptionId
    );
    debug!("Log: {:?}", log);

    let mut job_results = Vec::new();
    let mut commitments = Vec::new();
    for compute_req in meta_job {
        info!(
            "SubJob: TrustId({}), SeedId({})",
            compute_req.trust_id, compute_req.seed_id
        );

        let mut trust_file = File::create(&format!("./trust/{}", compute_req.trust_id)).unwrap();
        let mut seed_file = File::create(&format!("./seed/{}", compute_req.seed_id)).unwrap();

        info!("Downloading data...");
        let mut trust_res = s3_client
            .get_object()
            .bucket(BUCKET_NAME)
            .key(format!("trust/{}", compute_req.trust_id))
            .send()
            .await
            .unwrap();
        let mut seed_res = s3_client
            .get_object()
            .bucket(BUCKET_NAME)
            .key(format!("seed/{}", compute_req.seed_id))
            .send()
            .await
            .unwrap();

        while let Some(bytes) = trust_res.body.next().await {
            trust_file.write(&bytes.unwrap()).unwrap();
        }

        while let Some(bytes) = seed_res.body.next().await {
            seed_file.write(&bytes.unwrap()).unwrap();
        }

        let trust_file = File::open(&format!("./trust/{}", compute_req.trust_id)).unwrap();
        let seed_file = File::open(&format!("./seed/{}", compute_req.seed_id)).unwrap();

        let mut trust_rdr = csv::Reader::from_reader(trust_file);
        let mut seed_rdr = csv::Reader::from_reader(seed_file);

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
            let trust_entry = ScoreEntry::new(id, value);
            seed_entries.push(trust_entry);
        }

        info!("Starting core compute...");
        let mock_domain = Domain::default();
        let mut runner = ComputeRunner::new(&[mock_domain.clone()]);
        runner
            .update_trust_map(mock_domain.clone(), trust_entries.to_vec())
            .unwrap();
        runner
            .update_seed_map(mock_domain.clone(), seed_entries.to_vec())
            .unwrap();
        runner.compute(mock_domain.clone()).unwrap();
        let scores = runner.get_compute_scores(mock_domain.clone()).unwrap();
        runner.create_compute_tree(mock_domain.clone()).unwrap();
        let (_, compute_root) = runner.get_root_hashes(mock_domain.clone()).unwrap();

        let scores_vec = Vec::new();
        let mut wtr = csv::Writer::from_writer(scores_vec);
        wtr.write_record(&["i", "v"]).unwrap();
        scores.iter().for_each(|x| {
            wtr.write_record(&[x.id(), x.value().to_string().as_str()])
                .unwrap();
        });
        let mut file_bytes = wtr.into_inner().unwrap();
        let mut hasher = Keccak256::new();
        hasher.write_all(&mut file_bytes).unwrap();
        let scores_id = hasher.finalize().to_vec();

        let commitment_bytes = FixedBytes::<32>::from_slice(compute_root.inner());
        let scores_id_bytes = FixedBytes::<32>::from_slice(scores_id.as_slice());
        let commitment = hex::encode(compute_root.inner());
        let scores_id = hex::encode(scores_id.clone());
        let job_result = JobResult::new(scores_id.clone(), commitment);

        info!(
            "Core compute completed: ScoresId({:#}), Commitment({:#})",
            scores_id_bytes, commitment_bytes
        );
        info!("Uploading scores data...");

        let body = ByteStream::from(file_bytes);
        s3_client
            .put_object()
            .bucket(BUCKET_NAME)
            .key(format!("scores/{}", scores_id))
            .body(body)
            .send()
            .await
            .unwrap();

        info!("Upload scores complete...");

        job_results.push(job_result);
        commitments.push(Hash::from_slice(commitment_bytes.as_slice()));
    }

    let commitment_tree = DenseMerkleTree::<Keccak256>::new(commitments).unwrap();
    let meta_commitment = commitment_tree.root().unwrap();

    let meta_id = upload_meta(&s3_client, job_results).await.unwrap();

    let meta_commitment_bytes = FixedBytes::from_slice(meta_commitment.inner());
    let meta_id_bytes = FixedBytes::from_slice(hex::decode(meta_id).unwrap().as_slice());

    info!("Posting commitment on-chain. Calling: 'submitMetaComputeResult'");
    let required_stake = contract.STAKE().call().await.unwrap();
    let res = contract
        .submitMetaComputeResult(
            meta_compute_req.computeId,
            meta_commitment_bytes,
            meta_id_bytes,
        )
        .value(required_stake._0)
        .send()
        .await
        .unwrap();
    info!(
        "'submitMetaComputeResult' completed: Tx Hash({:#})",
        res.watch().await.unwrap()
    );

    let elapsed = start.elapsed();
    info!("Total compute time: {:?}", elapsed);
}

async fn finalize_job<PH: Provider>(
    contract: &OpenRankManagerInstance<(), PH>,
    provider_http: &PH,
    challenge_window: u64,
    compute_result_map: &HashMap<Uint<256, 4>, Log>,
    finalized_job_map: &HashMap<Uint<256, 4>, Log>,
    meta_compute_result_map: &HashMap<Uint<256, 4>, Log>,
    meta_finalized_job_map: &HashMap<Uint<256, 4>, Log>,
) {
    info!("Searching for jobs to be finalised...");
    let block = provider_http
        .get_block(BlockId::Number(BlockNumberOrTag::Latest))
        .await
        .unwrap()
        .unwrap();
    for (compute_id, log) in compute_result_map.iter() {
        let log_block = provider_http
            .get_block(BlockId::Number(BlockNumberOrTag::Number(
                log.block_number.unwrap(),
            )))
            .await
            .unwrap()
            .unwrap();

        let challenge_window_expired =
            block.header.timestamp - log_block.header.timestamp > challenge_window;
        if !finalized_job_map.contains_key(compute_id) && challenge_window_expired {
            info!(
                "Found job to finalize: ComputeId({:#}). Calling 'finalizeJob'",
                compute_id
            );
            let res = contract.finalizeJob(*compute_id).send().await;
            if let Ok(res) = res {
                info!("Job Finalised. Tx Hash: {:#}", res.watch().await.unwrap());
            } else {
                let err = res.unwrap_err();
                error!("'finalizeJob' failed. {}", err);
            }
        }
    }

    for (compute_id, log) in meta_compute_result_map.iter() {
        let log_block = provider_http
            .get_block(BlockId::Number(BlockNumberOrTag::Number(
                log.block_number.unwrap(),
            )))
            .await
            .unwrap()
            .unwrap();

        let challenge_window_expired =
            block.header.timestamp - log_block.header.timestamp > challenge_window;
        if !meta_finalized_job_map.contains_key(compute_id) && challenge_window_expired {
            info!(
                "Found meta job to finalize: ComputeId({:#}). Calling 'finalizeMetaJob'",
                compute_id
            );
            let res = contract.finalizeMetaJob(*compute_id).send().await;
            if let Ok(res) = res {
                info!(
                    "Meta Job Finalised. Tx Hash: {:#}",
                    res.watch().await.unwrap()
                );
            } else {
                let err = res.unwrap_err();
                error!("'finalizeMetaJob' failed. {}", err);
            }
        }
    }
}

pub async fn run<PH: Provider, PW: Provider>(
    contract: OpenRankManagerInstance<(), PH>,
    contract_ws: OpenRankManagerInstance<(), PW>,
    provider_http: PH,
    s3_client: Client,
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

    // Metaed jobs events
    let meta_compute_request_filter = contract_ws
        .MetaComputeRequestEvent_filter()
        .watch()
        .await
        .unwrap();
    let meta_compute_result_filter = contract_ws
        .MetaComputeResultEvent_filter()
        .from_block(BlockNumberOrTag::Latest)
        .watch()
        .await
        .unwrap();
    let meta_challenge_filter = contract_ws
        .MetaChallengeEvent_filter()
        .from_block(BlockNumberOrTag::Latest)
        .watch()
        .await
        .unwrap();
    let meta_job_finalised_filter = contract_ws
        .MetaJobFinalized_filter()
        .from_block(BlockNumberOrTag::Latest)
        .watch()
        .await
        .unwrap();

    let mut compute_request_stream = compute_request_filter.into_stream();
    let mut compute_result_stream = compute_result_filter.into_stream();
    let mut challenge_stream = challenge_filter.into_stream();
    let mut job_finalised_stream = job_finalised_filter.into_stream();

    // Meta jobs event streams
    let mut meta_compute_request_stream = meta_compute_request_filter.into_stream();
    let mut meta_compute_result_stream = meta_compute_result_filter.into_stream();
    let mut meta_challenge_stream = meta_challenge_filter.into_stream();
    let mut meta_job_finalised_stream = meta_job_finalised_filter.into_stream();

    let mut interval = time::interval(Duration::from_secs(TICK_DURATION));
    let mut compute_result_map = HashMap::new();
    let mut finalized_job_map = HashMap::new();

    let mut meta_compute_result_map = HashMap::new();
    let mut meta_finalized_job_map = HashMap::new();

    let challenge_window = contract.CHALLENGE_WINDOW().call().await.unwrap();

    info!("Running the computer node...");

    loop {
        select! {
            compute_request_event = compute_request_stream.next() => {
                if let Some(res) = compute_request_event {
                    let (compute_req, log): (ComputeRequestEvent, Log) = res.unwrap();
                    handle_compute_request(
                        &contract,
                        &s3_client,
                        compute_req,
                        log
                    ).await;
                }
            }
            compute_result_event = compute_result_stream.next() => {
                if let Some(res) = compute_result_event {
                    let (compute_req, log): (ComputeResultEvent, Log) = res.unwrap();
                    info!(
                        "ComputeResultEvent: ComputeId({}), Commitment({:#}), ScoresId({:#})",
                        compute_req.computeId, compute_req.commitment, compute_req.scores_id
                    );
                    debug!("Log: {:?}", log);

                    compute_result_map.insert(compute_req.computeId, log);
                }
            }
            challenge_event = challenge_stream.next() => {
                if let Some(res) = challenge_event {
                    let (challenge, log): (ChallengeEvent, Log) = res.unwrap();
                    info!("ChallengeEvent: ComputeId({:#})", challenge.computeId);
                    debug!("{:?}", log);
                }
            }
            job_finalised_event = job_finalised_stream.next() => {
                if let Some(res) = job_finalised_event {
                    let (job_finalized, log): (JobFinalized, Log) = res.unwrap();
                    info!("JobFinalizedEvent: ComputeId({:#})", job_finalized.computeId);
                    debug!("{:?}", log);

                    finalized_job_map.insert(job_finalized.computeId, log);
                }
            }
            meta_compute_request_event = meta_compute_request_stream.next() => {
                if let Some(res) = meta_compute_request_event {
                    let (compute_req, log): (MetaComputeRequestEvent, Log) = res.unwrap();
                    handle_meta_compute_request(
                        &contract,
                        &s3_client,
                        compute_req,
                        log
                    ).await;
                }
            }
            meta_compute_result_event = meta_compute_result_stream.next() => {
                if let Some(res) = meta_compute_result_event {
                    let (meta_compute_res, log): (MetaComputeResultEvent, Log) = res.unwrap();
                    info!(
                        "MetaComputeResultEvent: ComputeId({}), Commitment({:#}), ResultsId({:#})",
                        meta_compute_res.computeId, meta_compute_res.commitment, meta_compute_res.resultsId
                    );
                    debug!("Log: {:?}", log);

                    meta_compute_result_map.insert(meta_compute_res.computeId, log);
                }
            }
            meta_challenge_event = meta_challenge_stream.next() => {
                if let Some(res) = meta_challenge_event {
                    let (meta_challenge, log): (MetaChallengeEvent, Log) = res.unwrap();
                    info!("MetaChallengeEvent: ComputeId({:#})", meta_challenge.computeId);
                    debug!("{:?}", log);
                }
            }
            meta_job_finalised_event = meta_job_finalised_stream.next() => {
                if let Some(res) = meta_job_finalised_event {
                    let (meta_job_finalized, log): (MetaJobFinalized, Log) = res.unwrap();
                    info!("MetaJobFinalizedEvent: ComputeId({:#})", meta_job_finalized.computeId);
                    debug!("{:?}", log);

                    meta_finalized_job_map.insert(meta_job_finalized.computeId, log);
                }
            }
            _ = interval.tick() => {
                finalize_job(
                    &contract,
                    &provider_http,
                    challenge_window._0,
                    &compute_result_map,
                    &finalized_job_map,
                    &meta_compute_result_map,
                    &meta_finalized_job_map
                ).await;
            }
        }
    }
}
