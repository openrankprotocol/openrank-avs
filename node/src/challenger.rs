use crate::error::Error as NodeError;
use crate::sol::OpenRankManager::{
    MetaChallengeEvent, MetaComputeRequestEvent, MetaComputeResultEvent, OpenRankManagerInstance,
};
use crate::sol::ReexecutionEndpoint::{
    OperatorResponse, ReexecutionEndpointInstance, ReexecutionRequestCreated,
};
use alloy::eips::{BlockId, BlockNumberOrTag};
use alloy::hex::{self, ToHexExt};
use alloy::primitives::Uint;
use alloy::providers::Provider;
use alloy::rpc::types::Log;
use aws_sdk_s3::Client;
use csv::StringRecord;
use futures_util::StreamExt;
use openrank_common::merkle::fixed::DenseMerkleTree;
use openrank_common::merkle::Hash;
use openrank_common::runners::verification_runner::{self, VerificationRunner};
use openrank_common::tx::trust::{ScoreEntry, TrustEntry};
use openrank_common::Domain;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use sha3::Keccak256;
use std::collections::HashMap;
use std::fs::File;
use std::io::Write;
use tokio::fs::create_dir_all;
use tokio::select;
use tracing::{debug, error, info};

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

async fn handle_meta_compute_result<PH: Provider>(
    contract: &OpenRankManagerInstance<(), PH>,
    provider: &PH,
    s3_client: &Client,
    bucket_name: &str,
    meta_compute_res: MetaComputeResultEvent,
    log: Log,
    meta_compute_request_map: &HashMap<Uint<256, 4>, MetaComputeRequestEvent>,
    meta_challanged_jobs_map: &HashMap<Uint<256, 4>, Log>,
    challenge_window: u64,
) -> Result<(), NodeError> {
    let meta_result: Vec<JobResult> = download_meta(
        s3_client,
        bucket_name,
        meta_compute_res.resultsId.encode_hex(),
    )
    .await?;

    info!(
        "ComputeResultEvent: ComputeId({}), Commitment({:#}), ResultsId({:#})",
        meta_compute_res.computeId, meta_compute_res.commitment, meta_compute_res.resultsId
    );
    debug!("Log: {:?}", log);

    let already_challenged = meta_challanged_jobs_map.contains_key(&meta_compute_res.computeId);

    let block = provider
        .get_block(BlockId::Number(BlockNumberOrTag::Latest))
        .await
        .map_err(|e| NodeError::TxError(format!("{e:}")))?
        .unwrap();
    let log_block = provider
        .get_block(BlockId::Number(BlockNumberOrTag::Number(
            log.block_number.unwrap(),
        )))
        .await
        .map_err(|e| NodeError::TxError(format!("{e:}")))?
        .unwrap();
    if already_challenged {
        return Ok(());
    }

    if !meta_compute_request_map.contains_key(&meta_compute_res.computeId) {
        return Ok(());
    }
    let compute_req = meta_compute_request_map
        .get(&meta_compute_res.computeId)
        .unwrap();

    let job_description: Vec<JobDescription> = download_meta(
        s3_client,
        bucket_name,
        compute_req.jobDescriptionId.encode_hex(),
    )
    .await?;

    let mut global_result = true;
    let mut sub_job_failed = 0;
    let mut commitments = Vec::new();
    for (i, compute_res) in meta_result.iter().enumerate() {
        info!("Downloading data...");

        create_dir_all(&format!("./trust/")).await.unwrap();
        create_dir_all(&format!("./seed/")).await.unwrap();
        create_dir_all(&format!("./scores/")).await.unwrap();
        let mut trust_file = File::create(&format!("./trust/{}", job_description[i].trust_id))
            .map_err(|e| NodeError::FileError(format!("Failed to create file: {e:}")))?;
        let mut seed_file = File::create(&format!("./seed/{}", job_description[i].seed_id))
            .map_err(|e| NodeError::FileError(format!("Failed to create file: {e:}")))?;
        let mut scores_file = File::create(&format!("./scores/{}", compute_res.scores_id))
            .map_err(|e| NodeError::FileError(format!("Failed to create file: {e:}")))?;

        let mut trust_res = s3_client
            .get_object()
            .bucket(bucket_name)
            .key(format!("trust/{}", job_description[i].trust_id))
            .send()
            .await
            .map_err(|e| NodeError::AwsError(e.into()))?;
        let mut seed_res = s3_client
            .get_object()
            .bucket(bucket_name)
            .key(format!("seed/{}", job_description[i].seed_id))
            .send()
            .await
            .map_err(|e| NodeError::AwsError(e.into()))?;
        let mut scores_res = s3_client
            .get_object()
            .bucket(bucket_name)
            .key(format!("scores/{}", compute_res.scores_id))
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
        while let Some(bytes) = scores_res.body.next().await {
            scores_file
                .write(&bytes.unwrap())
                .map_err(|e| NodeError::FileError(format!("Failed to write to file: {e:}")))?;
        }
    }

    for (i, compute_res) in meta_result.iter().enumerate() {
        let trust_file = File::open(&format!("./trust/{}", job_description[i].trust_id))
            .map_err(|e| NodeError::FileError(format!("Failed to open file: {e:}")))?;
        let seed_file = File::open(&format!("./seed/{}", job_description[i].seed_id))
            .map_err(|e| NodeError::FileError(format!("Failed to open file: {e:}")))?;
        let scores_file = File::open(&format!("./scores/{}", compute_res.scores_id))
            .map_err(|e| NodeError::FileError(format!("Failed to open file: {e:}")))?;

        let mut trust_rdr = csv::Reader::from_reader(trust_file);
        let mut seed_rdr = csv::Reader::from_reader(seed_file);
        let mut scores_rdr = csv::Reader::from_reader(scores_file);

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
            let seed_entry = ScoreEntry::new(id, value);
            seed_entries.push(seed_entry);
        }

        let mut scores_entries = Vec::new();
        for result in scores_rdr.records() {
            let record: StringRecord = result.map_err(NodeError::CsvError)?;
            let (id, value): (String, f32) =
                record.deserialize(None).map_err(NodeError::CsvError)?;
            let score_entry = ScoreEntry::new(id, value);
            scores_entries.push(score_entry);
        }

        info!("Starting core compute...");
        let mock_domain = Domain::default();
        let mut runner = VerificationRunner::new(&[mock_domain.clone()]);
        runner
            .update_trust_map(mock_domain.clone(), trust_entries.to_vec())
            .map_err(NodeError::VerificationRunnerError)?;
        runner
            .update_seed_map(mock_domain.clone(), seed_entries.to_vec())
            .map_err(NodeError::VerificationRunnerError)?;
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
            .map_err(NodeError::VerificationRunnerError)?;
        let result = runner
            .verify_job(mock_domain, Hash::from_slice(i.to_be_bytes().as_slice()))
            .map_err(NodeError::VerificationRunnerError)?;
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

    let commitment_tree = DenseMerkleTree::<Keccak256>::new(commitments)
        .map_err(|e| NodeError::VerificationRunnerError(verification_runner::Error::Merkle(e)))?;
    let meta_commitment = commitment_tree
        .root()
        .map_err(|e| NodeError::VerificationRunnerError(verification_runner::Error::Merkle(e)))?;
    let commitment_result = meta_commitment.to_hex() == meta_compute_res.commitment.encode_hex();
    if !commitment_result {
        global_result = false;
    }

    let challenge_window_open =
        (block.header.timestamp - log_block.header.timestamp) < challenge_window;
    info!("Challenge window open: {}", challenge_window_open);

    if !global_result && challenge_window_open {
        info!("Submitting challenge. Calling 'metaSubmitChallenge'");
        let res = contract
            .submitMetaChallenge(meta_compute_res.computeId, sub_job_failed as u32)
            .send()
            .await;
        if let Ok(res) = res {
            let tx_res = res.watch().await.unwrap();
            info!("'metaSubmitChallenge' completed. Tx Hash({:#})", tx_res);
        } else {
            let err = res.unwrap_err();
            error!("'metaSubmitChallenge' failed. {}", err);
        }
    }

    Ok(())
}

pub async fn run<P: Provider, PW: Provider>(
    manager_contract: OpenRankManagerInstance<(), P>,
    rxp_contract: ReexecutionEndpointInstance<(), PW>,
    provider: P,
    s3_client: Client,
    bucket_name: &str,
) {
    let challenge_window = manager_contract.CHALLENGE_WINDOW().call().await.unwrap();

    // Meta jobs filters
    let meta_compute_request_filter = manager_contract
        .MetaComputeRequestEvent_filter()
        .from_block(BlockNumberOrTag::Latest)
        .watch()
        .await
        .unwrap();
    let meta_compute_result_filter = manager_contract
        .MetaComputeResultEvent_filter()
        .from_block(BlockNumberOrTag::Latest)
        .watch()
        .await
        .unwrap();
    let meta_challenge_filter = manager_contract
        .MetaChallengeEvent_filter()
        .from_block(BlockNumberOrTag::Latest)
        .watch()
        .await
        .unwrap();
    let reexecution_request_filter = rxp_contract
        .ReexecutionRequestCreated_filter()
        .from_block(BlockNumberOrTag::Latest)
        .watch()
        .await
        .unwrap();
    let operator_response_filter = rxp_contract
        .OperatorResponse_filter()
        .from_block(BlockNumberOrTag::Latest)
        .watch()
        .await
        .unwrap();

    // Meta streams
    let mut meta_compute_request_stream = meta_compute_request_filter.into_stream();
    let mut meta_compute_result_stream = meta_compute_result_filter.into_stream();
    let mut meta_challenge_stream = meta_challenge_filter.into_stream();
    let mut reexecution_request_stream = reexecution_request_filter.into_stream();
    let mut operator_response_stream = operator_response_filter.into_stream();

    let mut meta_compute_request_map = HashMap::new();
    let mut meta_challanged_jobs_map = HashMap::new();

    info!("Running the challenger node...");

    loop {
        select! {
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
                        &manager_contract,
                        &provider,
                        &s3_client,
                        bucket_name,
                        compute_res,
                        log,
                        &meta_compute_request_map,
                        &meta_challanged_jobs_map,
                        challenge_window._0,
                    ).await.unwrap();
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
            reexecution_request_event = reexecution_request_stream.next() => {
                if let Some(res) = reexecution_request_event {
                    let (request, log): (ReexecutionRequestCreated, Log) = res.unwrap();
                    info!(
                        "ReexecutionRequestCreated: requestIndex({:#}) avs({:#}), reservationID({:#})",
                        request.requestIndex,
                        request.avs,
                        request.reservationID,
                    );
                    debug!("{:?}", log);
                }
            }
            operator_response_event = operator_response_stream.next() => {
                if let Some(res) = operator_response_event {
                    let (response, log): (OperatorResponse, Log) = res.unwrap();
                    info!(
                        "OperatorResponse: operator({:#}) response({:#})",
                        response.operator,
                        response.response
                    );
                    debug!("{:?}", log);
                }
            }
        }
    }
}
