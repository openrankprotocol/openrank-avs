use crate::error::Error as NodeError;
use crate::sol::OpenRankManager::{MetaComputeRequestEvent, OpenRankManagerInstance};
use crate::{JobDescription, JobResult};
use alloy::eips::BlockNumberOrTag;
use alloy::hex::{self, ToHexExt};
use alloy::primitives::FixedBytes;
use alloy::providers::Provider;
use alloy::rpc::types::Log;
use aws_sdk_s3::Client;

use crate::{
    create_csv_and_hash_from_scores, download_json_metadata_from_s3, download_seed_data_to_file,
    download_trust_data_to_file, parse_score_entries_from_file, parse_trust_entries_from_file,
    upload_bytes_to_s3, upload_file_to_s3_streaming,
};
use futures_util::StreamExt;
use openrank_common::merkle::fixed::DenseMerkleTree;
use openrank_common::merkle::Hash;
use openrank_common::runners::compute_runner::{self, ComputeRunner};
use openrank_common::Domain;

use serde::de::DeserializeOwned;
use serde::Serialize;
use sha3::{Digest, Keccak256};
use std::collections::HashMap;
use std::fs::File;
use std::io::Write;

use std::time::Instant;
use tokio::fs::create_dir_all;
use tokio::select;
use tracing::{debug, error, info};

pub async fn upload_meta<T: Serialize>(
    client: &Client,
    bucket_name: &str,
    meta: T,
) -> Result<String, NodeError> {
    let mut bytes = serde_json::to_vec(&meta).map_err(NodeError::SerdeError)?;

    let mut hasher = Keccak256::new();
    hasher
        .write_all(&mut bytes)
        .map_err(|e| NodeError::FileError(format!("Failed to write to hasher: {}", e)))?;
    let hash = hasher.finalize().to_vec();
    upload_bytes_to_s3(
        client,
        bucket_name,
        &format!("meta/{}", hex::encode(hash.clone())),
        &bytes,
    )
    .await?;
    Ok(hex::encode(hash))
}

pub async fn download_meta<T: DeserializeOwned>(
    client: &Client,
    bucket_name: &str,
    meta_id: String,
) -> Result<T, NodeError> {
    download_json_metadata_from_s3(client, bucket_name, &meta_id).await
}

async fn handle_meta_compute_request<PH: Provider>(
    contract: &OpenRankManagerInstance<(), PH>,
    s3_client: Client,
    bucket_name: String,
    meta_compute_req: MetaComputeRequestEvent,
    log: Log,
) -> Result<(), NodeError> {
    let start = Instant::now();
    let meta_job: Vec<JobDescription> = download_meta(
        &s3_client,
        &bucket_name,
        meta_compute_req.jobDescriptionId.encode_hex(),
    )
    .await?;
    info!(
        "MetaComputeRequestEvent: JobDescriptionId({})",
        meta_compute_req.jobDescriptionId
    );
    debug!("Log: {:?}", log);

    // Create directories for data storage
    create_dir_all(&format!("./trust/"))
        .await
        .map_err(|e| NodeError::FileError(format!("Failed to create trust directory: {}", e)))?;
    create_dir_all(&format!("./seed/"))
        .await
        .map_err(|e| NodeError::FileError(format!("Failed to create seed directory: {}", e)))?;
    create_dir_all("./scores/")
        .await
        .map_err(|e| NodeError::FileError(format!("Failed to create scores directory: {}", e)))?;

    // STAGE 1: Download all data files in parallel
    info!("STAGE 1: Downloading all data files in parallel...");

    let download_tasks: Vec<_> = meta_job
        .iter()
        .map(|compute_req| {
            let s3_client = s3_client.clone();
            let bucket_name = bucket_name.clone();
            let trust_id = compute_req.trust_id.clone();
            let seed_id = compute_req.seed_id.clone();

            tokio::spawn(async move {
                let trust_file_path = format!("./trust/{}", trust_id);
                let seed_file_path = format!("./seed/{}", seed_id);

                // Check if trust file already exists
                let (trust_result, trust_downloaded) =
                    if tokio::fs::metadata(&trust_file_path).await.is_ok() {
                        info!("Trust file already exists, skipping download: {}", trust_id);
                        (Ok(()), false)
                    } else {
                        info!("Downloading trust data for SubJob: TrustId({})", trust_id);
                        (
                            download_trust_data_to_file(
                                &s3_client,
                                &bucket_name,
                                &trust_id,
                                &trust_file_path,
                            )
                            .await,
                            true,
                        )
                    };

                // Check if seed file already exists
                let (seed_result, seed_downloaded) =
                    if tokio::fs::metadata(&seed_file_path).await.is_ok() {
                        info!("Seed file already exists, skipping download: {}", seed_id);
                        (Ok(()), false)
                    } else {
                        info!("Downloading seed data for SubJob: SeedId({})", seed_id);
                        (
                            download_seed_data_to_file(
                                &s3_client,
                                &bucket_name,
                                &seed_id,
                                &seed_file_path,
                            )
                            .await,
                            true,
                        )
                    };

                // Return results with download status
                (
                    trust_result,
                    seed_result,
                    trust_downloaded,
                    seed_downloaded,
                    trust_id,
                    seed_id,
                )
            })
        })
        .collect();

    // Wait for all downloads to complete
    let download_results = futures_util::future::join_all(download_tasks).await;

    // Check for errors and count downloads vs skips
    let mut trust_downloads = 0;
    let mut seed_downloads = 0;

    for result in download_results {
        let (trust_result, seed_result, trust_downloaded, seed_downloaded, trust_id, seed_id) =
            result.map_err(|e| NodeError::TxError(format!("Download task failed: {}", e)))?;

        trust_result.map_err(|e| {
            NodeError::FileError(format!(
                "Failed to download trust data for {}: {}",
                trust_id, e
            ))
        })?;
        seed_result.map_err(|e| {
            NodeError::FileError(format!(
                "Failed to download seed data for {}: {}",
                seed_id, e
            ))
        })?;

        if trust_downloaded {
            trust_downloads += 1;
        }
        if seed_downloaded {
            seed_downloads += 1;
        }
    }

    let trust_skips = meta_job.len() - trust_downloads;
    let seed_skips = meta_job.len() - seed_downloads;

    info!(
        "STAGE 1 complete: Trust files (downloaded: {}, skipped: {}), Seed files (downloaded: {}, skipped: {})",
        trust_downloads, trust_skips, seed_downloads, seed_skips
    );

    // STAGE 2: Compute scores and save to CSV files in parallel
    info!("STAGE 2: Computing scores and saving to CSV files in parallel...");

    let mut job_results = Vec::new();
    let mut commitments = Vec::new();
    for compute_req in meta_job {
        let trust_id = compute_req.trust_id.clone();
        let seed_id = compute_req.seed_id.clone();

        info!(
            "Computing scores for SubJob: TrustId({}), SeedId({})",
            trust_id, seed_id
        );

        let trust_file = File::open(&format!("./trust/{}", trust_id))
            .map_err(|e| NodeError::FileError(format!("Failed to open trust file: {e:}")))?;
        let seed_file = File::open(&format!("./seed/{}", seed_id))
            .map_err(|e| NodeError::FileError(format!("Failed to open seed file: {e:}")))?;

        let trust_entries = parse_trust_entries_from_file(trust_file)?;
        let seed_entries = parse_score_entries_from_file(seed_file)?;

        // Core compute operations
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

        // Create CSV file and compute hash
        let (file_bytes, scores_id) = create_csv_and_hash_from_scores(scores)?;

        // Save CSV to local file
        let scores_file_path = format!("./scores/{}.csv", hex::encode(&scores_id));
        let mut scores_file = File::create(&scores_file_path)
            .map_err(|e| NodeError::FileError(format!("Failed to create scores file: {}", e)))?;
        scores_file
            .write_all(&file_bytes)
            .map_err(|e| NodeError::FileError(format!("Failed to write scores file: {}", e)))?;

        let commitment_bytes = FixedBytes::<32>::from_slice(compute_root.inner());
        let scores_id_bytes = FixedBytes::<32>::from_slice(scores_id.as_slice());
        let commitment = hex::encode(compute_root.inner());
        let scores_id_hex = hex::encode(scores_id.clone());
        let job_result = JobResult::new(scores_id_hex.clone(), commitment);

        info!(
            "Core compute completed: ScoresId({:#}), Commitment({:#})",
            scores_id_bytes, commitment_bytes
        );

        job_results.push(job_result);
        commitments.push(Hash::from_slice(commitment_bytes.as_slice()));
    }

    info!("STAGE 2 complete: All scores computed and saved to CSV files in parallel");

    // STAGE 3: Upload all scores files to S3 in parallel
    info!("STAGE 3: Uploading all scores files to S3 in parallel...");

    let upload_tasks: Vec<_> = job_results
        .iter()
        .map(|job_result| {
            let s3_client = s3_client.clone();
            let bucket_name = bucket_name.clone();
            let scores_id = job_result.scores_id.clone();

            tokio::spawn(async move {
                info!("Uploading scores data for ScoresId({})", scores_id);

                let scores_file_path = format!("./scores/{}.csv", scores_id);
                let upload_result = upload_file_to_s3_streaming(
                    &s3_client,
                    &bucket_name,
                    &format!("scores/{}", scores_id),
                    &scores_file_path,
                )
                .await
                .map_err(|e| NodeError::FileError(format!("Failed to upload scores file: {}", e)));

                if upload_result.is_ok() {
                    info!("Upload complete for ScoresId({})", scores_id);
                }

                upload_result.map(|_| scores_id.clone())
            })
        })
        .collect();

    // Wait for all uploads to complete
    let upload_results = futures_util::future::join_all(upload_tasks).await;

    // Check for errors
    for result in upload_results {
        let upload_result =
            result.map_err(|e| NodeError::TxError(format!("Upload task failed: {}", e)))?;
        upload_result
            .map_err(|e| NodeError::FileError(format!("Failed to upload scores file: {}", e)))?;
    }

    info!("STAGE 3 complete: All scores files uploaded to S3 in parallel");

    let commitment_tree = DenseMerkleTree::<Keccak256>::new(commitments)
        .map_err(|e| NodeError::ComputeRunnerError(compute_runner::Error::Merkle(e)))?;
    let meta_commitment = commitment_tree
        .root()
        .map_err(|e| NodeError::ComputeRunnerError(compute_runner::Error::Merkle(e)))?;

    let meta_id = upload_meta(&s3_client, &bucket_name, job_results).await?;

    let meta_commitment_bytes = FixedBytes::from_slice(meta_commitment.inner());
    let meta_id_bytes = FixedBytes::from_slice(
        hex::decode(meta_id)
            .map_err(|e| NodeError::HexError(e))?
            .as_slice(),
    );

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
) -> Result<(), NodeError> {
    // Metaed jobs events
    let meta_compute_request_filter = contract_ws
        .MetaComputeRequestEvent_filter()
        .watch()
        .await
        .map_err(|e| {
            error!("Failed to create meta compute request filter: {}", e);
            NodeError::TxError(format!("Filter creation failed: {}", e))
        })?;
    let meta_compute_result_filter = contract_ws
        .MetaComputeResultEvent_filter()
        .from_block(BlockNumberOrTag::Latest)
        .watch()
        .await
        .map_err(|e| {
            error!("Failed to create meta compute result filter: {}", e);
            NodeError::TxError(format!("Filter creation failed: {}", e))
        })?;
    let meta_challenge_filter = contract_ws
        .MetaChallengeEvent_filter()
        .from_block(BlockNumberOrTag::Latest)
        .watch()
        .await
        .map_err(|e| {
            error!("Failed to create meta challenge filter: {}", e);
            NodeError::TxError(format!("Filter creation failed: {}", e))
        })?;

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
                    match res {
                        Ok((compute_req, log)) => {
                            if let Err(e) = handle_meta_compute_request(
                                &contract,
                                s3_client.clone(),
                                bucket_name.to_string(),
                                compute_req,
                                log
                            ).await {
                                error!("Error handling meta compute request: {}", e);
                            }
                        }
                        Err(e) => {
                            error!("Error processing meta compute request event: {}", e);
                        }
                    }
                }
            }
            meta_compute_result_event = meta_compute_result_stream.next() => {
                if let Some(res) = meta_compute_result_event {
                    match res {
                        Ok((meta_compute_res, log)) => {
                            info!(
                                "MetaComputeResultEvent: ComputeId({}), Commitment({:#}), ResultsId({:#})",
                                meta_compute_res.computeId, meta_compute_res.commitment, meta_compute_res.resultsId
                            );
                            debug!("Log: {:?}", log);

                            meta_compute_result_map.insert(meta_compute_res.computeId, log);
                        }
                        Err(e) => {
                            error!("Error processing meta compute result event: {}", e);
                        }
                    }
                }
            }
            meta_challenge_event = meta_challenge_stream.next() => {
                if let Some(res) = meta_challenge_event {
                    match res {
                        Ok((meta_challenge, log)) => {
                            info!("MetaChallengeEvent: ComputeId({:#})", meta_challenge.computeId);
                            debug!("{:?}", log);
                        }
                        Err(e) => {
                            error!("Error processing meta challenge event: {}", e);
                        }
                    }
                }
            }
        }
    }
}
