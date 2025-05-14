use alloy::hex::{self, FromHex, ToHexExt};
use alloy::primitives::{Address, FixedBytes, Uint};
use alloy::providers::{Provider, ProviderBuilder};
use alloy::rpc::client::RpcClient;
use alloy::signers::local::coins_bip39::English;
use alloy::signers::local::MnemonicBuilder;
use alloy::transports::http::reqwest::Url;
use aws_config::{from_env, SdkConfig};
use aws_credential_types::Credentials;
use aws_sdk_s3::config::SharedCredentialsProvider;
use aws_sdk_s3::Client;
use csv::StringRecord;
use openrank_common::merkle::fixed::DenseMerkleTree;
use openrank_common::merkle::Hash;
use openrank_common::runners::verification_runner::{self, VerificationRunner};
use openrank_common::tx::trust::{ScoreEntry, TrustEntry};
use openrank_common::Domain;
use openrank_node::{
    error::Error as NodeError,
    sol::OpenRankManager::{self, OpenRankManagerInstance},
};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use sha3::Keccak256;
use std::io::Write;
use tracing::info;

#[macro_use]
extern crate dotenv_codegen;

const BUCKET_NAME: &str = "openrank-data-dev";

#[derive(Serialize, Deserialize, Clone)]
struct JobDescription {
    alpha: f32,
    trust_id: String,
    seed_id: String,
}

#[derive(Serialize, Deserialize, Clone)]
struct JobResult {
    scores_id: String,
    commitment: String,
}

#[derive(Debug, Default)]
pub struct OpenRankExeInput {
    compute_id: Uint<256, 4>,
    job_id: Uint<32, 1>,
}

#[derive(Debug, Default)]
pub struct OpenRankExeResult {
    result: bool,
    meta_commitment: FixedBytes<32>,
    sub_job_commitment: FixedBytes<32>,
}

pub async fn download_meta<T: DeserializeOwned>(
    client: &Client,
    meta_id: String,
) -> Result<T, NodeError> {
    let res = client
        .get_object()
        .bucket(BUCKET_NAME)
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

pub async fn run<P: Provider>(
    contract: OpenRankManagerInstance<(), P>,
    s3_client: Client,
    input: OpenRankExeInput,
) -> Result<OpenRankExeResult, NodeError> {
    let res = contract
        .metaComputeResults(input.compute_id)
        .call()
        .await
        .map_err(|e| NodeError::TxError(format!("{e:}")))?;
    let meta_result: Vec<JobResult> = download_meta(&s3_client, res.resultsId.encode_hex()).await?;
    let sub_job_result = meta_result[input.job_id.into_limbs()[0] as usize].clone();

    let compute_request = contract
        .metaComputeRequests(input.compute_id)
        .call()
        .await
        .map_err(|e| NodeError::TxError(format!("{e:}")))?;

    let meta_request: Vec<JobDescription> =
        download_meta(&s3_client, compute_request.jobDescriptionId.encode_hex()).await?;
    let sub_job_description = meta_request[input.job_id.into_limbs()[0] as usize].clone();

    let mut trust_res = s3_client
        .get_object()
        .bucket(BUCKET_NAME)
        .key(format!("trust/{}", sub_job_description.trust_id))
        .send()
        .await
        .map_err(|e| NodeError::AwsError(e.into()))?;
    let mut seed_res = s3_client
        .get_object()
        .bucket(BUCKET_NAME)
        .key(format!("seed/{}", sub_job_description.seed_id))
        .send()
        .await
        .map_err(|e| NodeError::AwsError(e.into()))?;
    let mut scores_res = s3_client
        .get_object()
        .bucket(BUCKET_NAME)
        .key(format!("scores/{}", sub_job_result.scores_id))
        .send()
        .await
        .map_err(|e| NodeError::AwsError(e.into()))?;

    let mut trust_vec = Vec::new();
    let mut seed_vec = Vec::new();
    let mut scores_vec = Vec::new();

    while let Some(bytes) = trust_res.body.next().await {
        trust_vec
            .write(&bytes.unwrap())
            .map_err(|e| NodeError::FileError(format!("Failed to write to vec: {e:}")))?;
    }
    while let Some(bytes) = seed_res.body.next().await {
        seed_vec
            .write(&bytes.unwrap())
            .map_err(|e| NodeError::FileError(format!("Failed to write to vec: {e:}")))?;
    }
    while let Some(bytes) = scores_res.body.next().await {
        scores_vec
            .write(&bytes.unwrap())
            .map_err(|e| NodeError::FileError(format!("Failed to write to vec: {e:}")))?;
    }

    let mut trust_rdr = csv::Reader::from_reader(trust_vec.as_slice());
    let mut seed_rdr = csv::Reader::from_reader(seed_vec.as_slice());
    let mut scores_rdr = csv::Reader::from_reader(scores_vec.as_slice());

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
        let (id, value): (String, f32) = record.deserialize(None).map_err(NodeError::CsvError)?;
        let seed_entry = ScoreEntry::new(id, value);
        seed_entries.push(seed_entry);
    }

    let mut scores_entries = Vec::new();
    for result in scores_rdr.records() {
        let record: StringRecord = result.map_err(NodeError::CsvError)?;
        let (id, value): (String, f32) = record.deserialize(None).map_err(NodeError::CsvError)?;
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
        Hash::default(),
        Hash::from_slice(
            hex::decode(sub_job_result.commitment.clone())
                .unwrap()
                .as_slice(),
        ),
    );
    runner
        .update_scores(mock_domain.clone(), Hash::default(), scores_entries)
        .map_err(NodeError::VerificationRunnerError)?;
    let result = runner
        .verify_job(mock_domain.clone(), Hash::default())
        .map_err(NodeError::VerificationRunnerError)?;
    let (sub_job_commitment, _) = runner
        .get_root_hashes(mock_domain, Hash::default())
        .map_err(NodeError::VerificationRunnerError)?;
    info!("Core Compute verification completed. Result({})", result);

    let commitments: Vec<Hash> = meta_result
        .iter()
        .map(|x| Hash::from_slice(hex::decode(x.commitment.clone()).unwrap().as_slice()))
        .collect();

    let commitment_tree = DenseMerkleTree::<Keccak256>::new(commitments)
        .map_err(|e| NodeError::VerificationRunnerError(verification_runner::Error::Merkle(e)))?;
    let meta_commitment = commitment_tree
        .root()
        .map_err(|e| NodeError::VerificationRunnerError(verification_runner::Error::Merkle(e)))?;

    let exe_res = OpenRankExeResult {
        result,
        sub_job_commitment: FixedBytes::<32>::from_hex(sub_job_commitment.to_hex()).unwrap(),
        meta_commitment: FixedBytes::<32>::from_hex(meta_commitment.to_hex()).unwrap(),
    };

    Ok(exe_res)
}

#[tokio::main]
async fn main() {
    let rpc_url = dotenv!("CHAIN_RPC_URL");
    let manager_address = dotenv!("OPENRANK_MANAGER_ADDRESS");
    let mnemonic = dotenv!("MNEMONIC");
    let creds = Credentials::new(
        dotenv!("AWS_ACCESS_KEY_ID"),
        dotenv!("AWS_SECRET_ACCESS_KEY"),
        None,
        None,
        "rxp",
    );
    let provider = SharedCredentialsProvider::new(creds);
    let config = SdkConfig::builder().credentials_provider(provider).build();
    let client = Client::new(&config);

    let wallet = MnemonicBuilder::<English>::default()
        .phrase(mnemonic)
        .index(0)
        .unwrap()
        .build()
        .unwrap();

    let provider_http = ProviderBuilder::new()
        .wallet(wallet.clone())
        .on_client(RpcClient::new_http(Url::parse(&rpc_url).unwrap()));

    let manager_address = Address::from_hex(manager_address).unwrap();
    let manager_contract = OpenRankManager::new(manager_address, provider_http.clone());

    run(manager_contract, client, OpenRankExeInput::default())
        .await
        .unwrap();
}
