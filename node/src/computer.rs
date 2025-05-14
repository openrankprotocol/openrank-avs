use crate::error::Error as NodeError;
use crate::sol::OpenRankManager::{
    MetaChallengeEvent, MetaComputeRequestEvent, MetaComputeResultEvent, OpenRankManagerInstance,
};
use alloy::eips::BlockNumberOrTag;
use alloy::hex::{self, ToHexExt};
use alloy::primitives::FixedBytes;
use alloy::providers::Provider;
use alloy::rpc::types::Log;
use aws_sdk_s3::primitives::ByteStream;
use aws_sdk_s3::Client;
use csv::StringRecord;
use futures_util::StreamExt;
use openrank_common::merkle::fixed::DenseMerkleTree;
use openrank_common::merkle::Hash;
use openrank_common::runners::compute_runner::{self, ComputeRunner};
use openrank_common::tx::trust::{ScoreEntry, TrustEntry};
use openrank_common::Domain;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use sha3::{Digest, Keccak256};
use std::collections::HashMap;
use std::fs::File;
use std::io::Write;
use std::time::Instant;
use tokio::fs::create_dir_all;
use tokio::select;
use tracing::{debug, info};

#[derive(Serialize, Deserialize, Clone)]
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

pub async fn upload_meta<T: Serialize>(
    client: &Client,
    bucket_name: &str,
    meta: T,
) -> Result<String, NodeError> {
    let mut bytes = serde_json::to_vec(&meta).map_err(NodeError::SerdeError)?;
    let body = ByteStream::from(bytes.clone());

    let mut hasher = Keccak256::new();
    hasher.write_all(&mut bytes).unwrap();
    let hash = hasher.finalize().to_vec();
    client
        .put_object()
        .bucket(bucket_name)
        .key(format!("meta/{}", hex::encode(hash.clone())))
        .body(body)
        .send()
        .await
        .map_err(|e| NodeError::AwsError(e.into()))?;
    Ok(hex::encode(hash))
}

pub async fn download_meta<T: DeserializeOwned>(
    client: &Client,
    bucket_name: &str,
    meta_id: String,
) -> Result<T, NodeError> {
    let res = client
        .get_object()
        .bucket(bucket_name)
        .key(format!("meta/{}", meta_id))
        .send()
        .await
        .map_err(|e| NodeError::AwsError(e.into()))?;
    let res_bytes = res
        .body
        .collect()
        .await
        .map_err(NodeError::ByteStreamError)?;
    let meta: T =
        serde_json::from_slice(res_bytes.to_vec().as_slice()).map_err(NodeError::SerdeError)?;
    Ok(meta)
}

async fn handle_meta_compute_request<PH: Provider>(
    contract: &OpenRankManagerInstance<(), PH>,
    s3_client: &Client,
    bucket_name: &str,
    meta_compute_req: MetaComputeRequestEvent,
    log: Log,
) -> Result<(), NodeError> {
    let start = Instant::now();
    let meta_job: Vec<JobDescription> = download_meta(
        s3_client,
        bucket_name,
        meta_compute_req.jobDescriptionId.encode_hex(),
    )
    .await?;
    info!(
        "MetaComputeRequestEvent: JobDescriptionId({})",
        meta_compute_req.jobDescriptionId
    );
    debug!("Log: {:?}", log);

    let mut job_results = Vec::new();
    let mut commitments = Vec::new();
    for compute_req in meta_job.clone() {
        info!(
            "SubJob: TrustId({}), SeedId({})",
            compute_req.trust_id, compute_req.seed_id
        );

        create_dir_all(&format!("./trust/")).await.unwrap();
        create_dir_all(&format!("./seed/")).await.unwrap();
        let mut trust_file = File::create(&format!("./trust/{}", compute_req.trust_id))
            .map_err(|e| NodeError::FileError(format!("Failed to create file: {e:}")))?;
        let mut seed_file = File::create(&format!("./seed/{}", compute_req.seed_id))
            .map_err(|e| NodeError::FileError(format!("Failed to create file: {e:}")))?;

        info!("Downloading data...");
        let mut trust_res = s3_client
            .get_object()
            .bucket(bucket_name)
            .key(format!("trust/{}", compute_req.trust_id))
            .send()
            .await
            .map_err(|e| NodeError::AwsError(e.into()))?;
        let mut seed_res = s3_client
            .get_object()
            .bucket(bucket_name)
            .key(format!("seed/{}", compute_req.seed_id))
            .send()
            .await
            .map_err(|e| NodeError::AwsError(e.into()))?;

        while let Some(bytes) = trust_res.body.next().await {
            trust_file
                .write(&bytes.unwrap())
                .map_err(|e| NodeError::FileError(format!("Failed to write to file: {e:}")))?;
        }

        while let Some(bytes) = seed_res.body.next().await {
            seed_file
                .write(&bytes.unwrap())
                .map_err(|e| NodeError::FileError(format!("Failed to write to file: {e:}")))?;
        }
    }

    for compute_req in meta_job {
        let trust_file = File::open(&format!("./trust/{}", compute_req.trust_id))
            .map_err(|e| NodeError::FileError(format!("Failed to open file: {e:}")))?;
        let seed_file = File::open(&format!("./seed/{}", compute_req.seed_id))
            .map_err(|e| NodeError::FileError(format!("Failed to open file: {e:}")))?;

        let mut trust_rdr = csv::Reader::from_reader(trust_file);
        let mut seed_rdr = csv::Reader::from_reader(seed_file);

        let mut trust_entries = Vec::new();
        for result in trust_rdr.records() {
            let record: StringRecord = result.map_err(NodeError::CsvError)?;
            let (from, to, value): (String, String, f32) =
                record.deserialize(None).map_err(NodeError::CsvError)?;
            let trust_entry = TrustEntry::new(from, to, value);
            trust_entries.push(trust_entry);
        }

        let mut seed_entries = Vec::new();
        for result in seed_rdr.records() {
            let record: StringRecord = result.map_err(NodeError::CsvError)?;
            let (id, value): (String, f32) =
                record.deserialize(None).map_err(NodeError::CsvError)?;
            let trust_entry = ScoreEntry::new(id, value);
            seed_entries.push(trust_entry);
        }

        info!("Starting core compute...");
        let mock_domain = Domain::default();
        let mut runner = ComputeRunner::new(&[mock_domain.clone()]);
        runner
            .update_trust_map(mock_domain.clone(), trust_entries.to_vec())
            .map_err(NodeError::ComputeRunnerError)?;
        runner
            .update_seed_map(mock_domain.clone(), seed_entries.to_vec())
            .map_err(NodeError::ComputeRunnerError)?;
        runner
            .compute(mock_domain.clone())
            .map_err(NodeError::ComputeRunnerError)?;
        let scores = runner
            .get_compute_scores(mock_domain.clone())
            .map_err(NodeError::ComputeRunnerError)?;
        runner
            .create_compute_tree(mock_domain.clone())
            .map_err(NodeError::ComputeRunnerError)?;
        let (_, compute_root) = runner
            .get_root_hashes(mock_domain.clone())
            .map_err(NodeError::ComputeRunnerError)?;

        let scores_vec = Vec::new();
        let mut wtr = csv::Writer::from_writer(scores_vec);
        wtr.write_record(&["i", "v"]).map_err(NodeError::CsvError)?;
        for x in scores {
            wtr.write_record(&[x.id(), x.value().to_string().as_str()])
                .map_err(NodeError::CsvError)?;
        }
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
            .bucket(bucket_name)
            .key(format!("scores/{}", scores_id))
            .body(body)
            .send()
            .await
            .map_err(|e| NodeError::AwsError(e.into()))?;

        info!("Upload scores complete...");

        job_results.push(job_result);
        commitments.push(Hash::from_slice(commitment_bytes.as_slice()));
    }

    let commitment_tree = DenseMerkleTree::<Keccak256>::new(commitments)
        .map_err(|e| NodeError::ComputeRunnerError(compute_runner::Error::Merkle(e)))?;
    let meta_commitment = commitment_tree
        .root()
        .map_err(|e| NodeError::ComputeRunnerError(compute_runner::Error::Merkle(e)))?;

    let meta_id = upload_meta(&s3_client, bucket_name, job_results).await?;

    let meta_commitment_bytes = FixedBytes::from_slice(meta_commitment.inner());
    let meta_id_bytes = FixedBytes::from_slice(hex::decode(meta_id).unwrap().as_slice());

    info!("Posting commitment on-chain. Calling: 'submitMetaComputeResult'");
    let res = contract
        .submitMetaComputeResult(
            meta_compute_req.computeId,
            meta_commitment_bytes,
            meta_id_bytes,
        )
        .send()
        .await
        .map_err(|e| NodeError::TxError(format!("{e:}")))?;
    let tx_hash = res
        .watch()
        .await
        .map_err(|e| NodeError::TxError(format!("{e:}")))?;
    info!(
        "'submitMetaComputeResult' completed: Tx Hash({:#})",
        tx_hash
    );

    let elapsed = start.elapsed();
    info!("Total compute time: {:?}", elapsed);

    Ok(())
}

pub async fn run<PH: Provider, PW: Provider>(
    contract: OpenRankManagerInstance<(), PH>,
    contract_ws: OpenRankManagerInstance<(), PW>,
    s3_client: Client,
    bucket_name: &str,
) {
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

    // Meta jobs event streams
    let mut meta_compute_request_stream = meta_compute_request_filter.into_stream();
    let mut meta_compute_result_stream = meta_compute_result_filter.into_stream();
    let mut meta_challenge_stream = meta_challenge_filter.into_stream();

    let mut meta_compute_result_map = HashMap::new();
    info!("Running the computer node...");

    loop {
        select! {
            meta_compute_request_event = meta_compute_request_stream.next() => {
                if let Some(res) = meta_compute_request_event {
                    let (compute_req, log): (MetaComputeRequestEvent, Log) = res.unwrap();
                    handle_meta_compute_request(
                        &contract,
                        &s3_client,
                        bucket_name,
                        compute_req,
                        log
                    ).await.unwrap();
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
        }
    }
}
