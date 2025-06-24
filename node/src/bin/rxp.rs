use alloy::hex::{self, FromHex};
use alloy::primitives::{Address, FixedBytes, Uint};
use alloy::providers::{Provider, ProviderBuilder};
use alloy::rpc::client::RpcClient;
use alloy::signers::local::coins_bip39::English;
use alloy::signers::local::{MnemonicBuilder, PrivateKeySigner};
use alloy::sol_types::sol_data::Uint as SolUint;
use alloy::sol_types::SolType;
use alloy::transports::http::reqwest::Url;
use alloy_rlp::{Encodable, RlpEncodable};
use dotenv::dotenv;
use openrank_common::eigenda::EigenDAProxyClient;
use openrank_common::logs::setup_tracing;
use openrank_common::merkle::fixed::DenseMerkleTree;
use openrank_common::merkle::Hash;
use openrank_common::runners::verification_runner::{self, VerificationRunner};
use openrank_node::{parse_score_entries_from_tuples, parse_trust_entries_from_tuples};

use openrank_common::Domain;
use openrank_node::sol::OpenRankManager;
use openrank_node::{error::Error as NodeError, sol::OpenRankManager::OpenRankManagerInstance};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use sha3::Keccak256;
use tonic::transport::Server;
use tonic::{Request, Response, Status};
use tracing::info;

use proto::performer_service_server::{PerformerService, PerformerServiceServer};
use proto::*;

mod proto {
    tonic::include_proto!("eigenlayer.avs.v1.performer");
    pub(crate) const FILE_DESCRIPTOR_SET: &[u8] =
        tonic::include_file_descriptor_set!("rxp_descriptor");
}

#[macro_use]
extern crate dotenv_codegen;

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

#[derive(Serialize, Deserialize)]
struct EigenDaJobDescription {
    neighbour_commitments: Vec<String>,
    trust_data: Vec<u8>,
    seed_data: Vec<u8>,
    scores_data: Vec<u8>,
}

pub async fn download_meta<T: DeserializeOwned>(
    eigenda_client: &EigenDAProxyClient,
    certificate: Vec<u8>,
) -> Result<T, NodeError> {
    info!(
        "Downloading metadata from EigenDA with certificate length: {}",
        certificate.len()
    );
    let res_bytes = eigenda_client.get_meta(certificate).await.map_err(|e| {
        tracing::error!("Failed to download from EigenDA: {}", e);
        NodeError::EigenDAError(e)
    })?;
    info!("Retrieved {} bytes from EigenDA", res_bytes.len());
    let meta: T = serde_json::from_slice(res_bytes.as_slice()).map_err(|e| {
        tracing::error!("Failed to deserialize metadata from EigenDA: {}", e);
        NodeError::SerdeError(e)
    })?;
    Ok(meta)
}

pub async fn run<P: Provider>(
    contract: OpenRankManagerInstance<(), P>,
    eigenda_client: EigenDAProxyClient,
    input: OpenRankExeInput,
) -> Result<OpenRankExeResult, NodeError> {
    info!("Fetching challenge for compute_id: {}", input.compute_id);
    let challenge = contract
        .metaChallenges(input.compute_id)
        .call()
        .await
        .map_err(|e| {
            let error_msg = format!("Failed to fetch challenge from contract: {}", e);
            tracing::error!("{}", error_msg);
            NodeError::TxError(error_msg)
        })?;
    let meta_result: EigenDaJobDescription =
        download_meta(&eigenda_client, challenge.certificate.to_vec()).await?;

    let trust_entries = parse_trust_entries_from_tuples(&meta_result.trust_data)?;
    let seed_entries = parse_score_entries_from_tuples(&meta_result.seed_data)?;
    let scores_entries = parse_score_entries_from_tuples(&meta_result.scores_data)?;

    info!("Starting core compute...");
    let mock_domain = Domain::default();
    let mut runner = VerificationRunner::new(&[mock_domain.clone()]);
    runner
        .update_trust_map(mock_domain.clone(), trust_entries.to_vec())
        .map_err(NodeError::VerificationRunnerError)?;
    runner
        .update_seed_map(mock_domain.clone(), seed_entries.to_vec())
        .map_err(NodeError::VerificationRunnerError)?;
    runner
        .update_scores(mock_domain.clone(), Hash::default(), scores_entries)
        .map_err(NodeError::VerificationRunnerError)?;
    let result = runner
        .verify_scores(mock_domain.clone(), Hash::default())
        .map_err(NodeError::VerificationRunnerError)?;
    let (sub_job_commitment, _) = runner
        .get_root_hashes(mock_domain, Hash::default())
        .map_err(NodeError::VerificationRunnerError)?;
    info!("Core Compute verification completed. Result({})", result);

    let mut commitments: Vec<Hash> = meta_result
        .neighbour_commitments
        .iter()
        .map(|x| {
            let decoded = hex::decode(x).map_err(|e| NodeError::HexError(e))?;
            Ok(Hash::from_slice(decoded.as_slice()))
        })
        .collect::<Result<Vec<_>, NodeError>>()?;
    commitments.insert(challenge.subJobId as usize, sub_job_commitment.clone());

    let commitment_tree = DenseMerkleTree::<Keccak256>::new(commitments)
        .map_err(|e| NodeError::VerificationRunnerError(verification_runner::Error::Merkle(e)))?;
    let meta_commitment = commitment_tree
        .root()
        .map_err(|e| NodeError::VerificationRunnerError(verification_runner::Error::Merkle(e)))?;

    let exe_res = OpenRankExeResult {
        result,
        sub_job_commitment: FixedBytes::<32>::from_hex(sub_job_commitment.to_hex())
            .map_err(|e| NodeError::HexError(e))?,
        meta_commitment: FixedBytes::<32>::from_hex(meta_commitment.to_hex())
            .map_err(|e| NodeError::HexError(e))?,
    };

    Ok(exe_res)
}

struct RxpService {
    wallet: PrivateKeySigner,
    rpc_client: RpcClient,
    eigenda_client: EigenDAProxyClient,
    manager_address: Address,
}

impl RxpService {
    pub fn new(
        wallet: PrivateKeySigner,
        rpc_client: RpcClient,
        eigenda_client: EigenDAProxyClient,
        manager_address: Address,
    ) -> Self {
        Self {
            wallet,
            rpc_client,
            eigenda_client,
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
        Ok(Response::new(HealthCheckResponse {
            status: PerformerStatus::ReadyForTask.into(),
        }))
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
        let task_request = request.into_inner();

        let provider_http = ProviderBuilder::new()
            .wallet(self.wallet.clone())
            .on_client(self.rpc_client.clone());
        let manager_contract = OpenRankManager::new(self.manager_address, provider_http.clone());
        type Input = (SolUint<256>, SolUint<32>);
        let (compute_id, job_id) = Input::abi_decode(task_request.payload.as_slice(), true)
            .map_err(|e| {
                Status::invalid_argument(format!("Failed to decode task payload: {}", e))
            })?;

        let res = run(
            manager_contract,
            self.eigenda_client.clone(),
            OpenRankExeInput::new(compute_id, job_id),
        )
        .await
        .map_err(|e| Status::internal(format!("Task execution failed: {}", e)))?;

        let mut encoded_res = Vec::new();
        res.encode(&mut encoded_res);

        Ok(Response::new(TaskResponse {
            task_id: task_request.task_id,
            result: encoded_res,
        }))
    }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();
    dotenv().ok();
    setup_tracing();

    let eigenda_url = std::env::var("DA_PROXY_URL").expect("DA_PROXY_URL must be set");
    let service_port = std::env::var("SERVICE_PORT").expect("SERVICE_PORT must be set");
    let rpc_url = std::env::var("ETH_RPC_URL").expect("ETH_RPC_URL must be set");
    let manager_address = dotenv!("OPENRANK_MANAGER_ADDRESS");
    let mnemonic = dotenv!("MNEMONIC");
    info!("eigenda_url: {}", eigenda_url);
    info!("service_port: {}", service_port);
    info!("rpc_url: {}", rpc_url);

    let wallet = MnemonicBuilder::<English>::default()
        .phrase(mnemonic)
        .index(0)
        .map_err(|e| format!("Failed to set mnemonic index: {}", e))?
        .build()
        .map_err(|e| format!("Failed to build wallet: {}", e))?;

    let rpc_url_parsed = Url::parse(&rpc_url)
        .map_err(|e| format!("Failed to parse RPC URL '{}': {}", rpc_url, e))?;
    let rpc_client = RpcClient::new_http(rpc_url_parsed.clone());
    let manager_address = Address::from_hex(manager_address)
        .map_err(|e| format!("Failed to parse manager address: {}", e))?;
    let eigenda_client = EigenDAProxyClient::new(eigenda_url.to_string());

    // Test RPC connectivity before starting the service
    info!("Testing RPC connectivity to {}", rpc_url);
    let provider_test = ProviderBuilder::new()
        .wallet(wallet.clone())
        .on_http(rpc_url_parsed);

    // Check if we're running in RXP proxy environment
    let is_rxp_proxy = rpc_url.contains("reex-proxy");

    if is_rxp_proxy {
        info!("Running in RXP proxy environment - skipping block number check");
        info!("RXP proxy detected at {}", rpc_url);
    } else {
        match provider_test.get_block_number().await {
            Ok(block_number) => {
                info!(
                    "RPC connection successful. Current block number: {}",
                    block_number
                );
            }
            Err(e) => {
                tracing::error!("Failed to connect to RPC endpoint {}: {}", rpc_url, e);
                tracing::error!(
                    "Please ensure the Ethereum RPC endpoint is running and accessible"
                );
                std::process::exit(1);
            }
        }
    }

    info!("Running the rxp node on port {}..", service_port);

    let reflection_service = tonic_reflection::server::Builder::configure()
        .register_encoded_file_descriptor_set(proto::FILE_DESCRIPTOR_SET)
        .build()
        .map_err(|e| format!("Failed to build reflection service: {}", e))?;

    let rxp_service = RxpService::new(wallet, rpc_client, eigenda_client, manager_address);
    let addr = format!("0.0.0.0:{}", service_port)
        .parse()
        .map_err(|e| format!("Failed to parse server address: {}", e))?;
    Server::builder()
        .add_service(reflection_service)
        .add_service(PerformerServiceServer::new(rxp_service))
        .serve(addr)
        .await
        .map_err(|e| format!("Server failed: {}", e))?;

    Ok(())
}
