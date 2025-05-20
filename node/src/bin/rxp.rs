use alloy::hex::{self, FromHex, ToHexExt};
use alloy::primitives::{Address, FixedBytes, Uint};
use alloy::providers::{Provider, ProviderBuilder};
use alloy::rpc::client::RpcClient;
use alloy::signers::local::coins_bip39::English;
use alloy::signers::local::{MnemonicBuilder, PrivateKeySigner};
use alloy::transports::http::reqwest::Url;
use alloy_rlp::{Encodable, RlpEncodable};
use alloy_sol_types::{sol_data::Uint as SolUint, SolType};
use aws_config::{BehaviorVersion, SdkConfig};
use aws_credential_types::Credentials;
use aws_sdk_s3::config::SharedCredentialsProvider;
use aws_sdk_s3::Client;
use csv::StringRecord;
use dotenv::dotenv;
use openrank_common::logs::setup_tracing;
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
use tonic::transport::Server;
use tonic::{Request, Response, Status};
use tracing::info;

use performer_service_server::{PerformerService, PerformerServiceServer};

tonic::include_proto!("rxp");

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
    job_id: u32,
}

impl OpenRankExeInput {
    pub fn new(compute_id: Uint<256, 4>, job_id: u32) -> Self {
        Self { compute_id, job_id }
    }
}

#[derive(Debug, Default, RlpEncodable)]
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
    let sub_job_result = meta_result[input.job_id as usize].clone();

    let compute_request = contract
        .metaComputeRequests(input.compute_id)
        .call()
        .await
        .map_err(|e| NodeError::TxError(format!("{e:}")))?;

    let meta_request: Vec<JobDescription> =
        download_meta(&s3_client, compute_request.jobDescriptionId.encode_hex()).await?;
    let sub_job_description = meta_request[input.job_id as usize].clone();

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

struct RxpService {
    wallet: PrivateKeySigner,
    rpc_client: RpcClient,
    s3_client: Client,
    manager_address: Address,
}

impl RxpService {
    pub fn new(
        wallet: PrivateKeySigner,
        rpc_client: RpcClient,
        s3_client: Client,
        manager_address: Address,
    ) -> Self {
        Self {
            wallet,
            rpc_client,
            s3_client,
            manager_address,
        }
    }
}

#[tonic::async_trait]
impl PerformerService for RxpService {
    async fn health_check(
        &self,
        _: Request<HealthCheckRequest>,
    ) -> Result<Response<HealthCheckResponse>, Status> {
        Ok(Response::new(HealthCheckResponse { status: 1 }))
    }

    async fn start_sync(
        &self,
        _: Request<StartSyncRequest>,
    ) -> Result<Response<StartSyncResponse>, Status> {
        Ok(Response::new(StartSyncResponse {}))
    }

    async fn execute_task(
        &self,
        request: Request<TaskRequest>,
    ) -> Result<Response<TaskResponse>, Status> {
        let provider_http = ProviderBuilder::new()
            .wallet(self.wallet.clone())
            .on_client(self.rpc_client.clone());
        let manager_contract = OpenRankManager::new(self.manager_address, provider_http.clone());
        let task_request = request.into_inner();
        type Input = (SolUint<256>, SolUint<32>);
        let (compute_id, job_id) = Input::abi_decode(task_request.payload.as_slice()).unwrap();
        let res = run(
            manager_contract,
            self.s3_client.clone(),
            OpenRankExeInput::new(compute_id, job_id),
        )
        .await
        .unwrap();

        let mut encoded_res = Vec::new();
        res.encode(&mut encoded_res);
        Ok(Response::new(TaskResponse {
            task_id: task_request.task_id,
            result: encoded_res,
        }))
    }
}

#[tokio::main]
async fn main() {
    let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();
    dotenv().ok();
    setup_tracing();

    let service_port = dotenv!("SERVICE_PORT");
    let rpc_url = dotenv!("CHAIN_RPC_URL");
    let manager_address = dotenv!("OPENRANK_MANAGER_ADDRESS");
    let mnemonic = dotenv!("MNEMONIC");
    let creds = Credentials::new(
        dotenv!("AWS_ACCESS_KEY_ID"),
        dotenv!("AWS_SECRET_ACCESS_KEY"),
        None,
        None,
        "openrank-rxp",
    );
    let provider = SharedCredentialsProvider::new(creds);
    let config = SdkConfig::builder()
        .credentials_provider(provider)
        .behavior_version(BehaviorVersion::latest())
        .build();
    let s3_client = Client::new(&config);

    let wallet = MnemonicBuilder::<English>::default()
        .phrase(mnemonic)
        .index(0)
        .unwrap()
        .build()
        .unwrap();

    let rpc_client = RpcClient::new_http(Url::parse(&rpc_url).unwrap());
    let manager_address = Address::from_hex(manager_address).unwrap();

    info!("Running the rxp node on port {}..", service_port);

    let service = RxpService::new(wallet, rpc_client, s3_client, manager_address);
    let addr = format!("[::1]:{}", service_port).parse().unwrap();
    Server::builder()
        .add_service(PerformerServiceServer::new(service))
        .serve(addr)
        .await
        .unwrap();
}
