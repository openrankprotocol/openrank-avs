mod actions;
mod sol;

use crate::actions::save_json_to_file;
use crate::sol::OpenRankManager::{
    MetaChallengeEvent, MetaComputeRequestEvent, MetaComputeResultEvent,
};
use actions::{
    compute_local, download_meta, download_scores, upload_meta, upload_seed, upload_trust,
    verify_local,
};
use alloy::eips::BlockNumberOrTag;
use alloy::hex::{FromHex, ToHexExt};
use alloy::primitives::{Address, FixedBytes, TxHash, Uint};
use alloy::providers::{Provider, ProviderBuilder, WsConnect};
use alloy::rpc::client::RpcClient;
use alloy::rpc::types::Log;
use alloy::signers::local::coins_bip39::English;
use alloy::signers::local::MnemonicBuilder;
use alloy::transports::http::reqwest::Url;
use aws_config::from_env;
use aws_sdk_s3::{Client, Error as AwsError};
use clap::{Parser, Subcommand};
use csv::StringRecord;
use dotenv::dotenv;
use futures_util::StreamExt;
use openrank_common::eigenda::EigenDAProxyClient;
use openrank_common::logs::setup_tracing;
use openrank_common::tx::trust::{ScoreEntry, TrustEntry};
use serde::{Deserialize, Serialize};
use sol::OpenRankManager;
use std::collections::HashMap;
use std::fs::{read_dir, File};
use std::io::Write;
use std::path::Path;
use std::str::FromStr;
use tokio::fs::create_dir_all;
use tracing::info;

/// Helper function to parse trust entries from a CSV file
fn parse_trust_entries_from_file(file: File) -> Result<Vec<TrustEntry>, csv::Error> {
    let mut reader = csv::Reader::from_reader(file);
    let mut entries = Vec::new();

    for result in reader.records() {
        let record: StringRecord = result?;
        let (from, to, value): (String, String, f32) = record.deserialize(None)?;
        let trust_entry = TrustEntry::new(from, to, value);
        entries.push(trust_entry);
    }

    Ok(entries)
}

/// Helper function to parse score entries from a CSV file
fn parse_score_entries_from_file(file: File) -> Result<Vec<ScoreEntry>, csv::Error> {
    let mut reader = csv::Reader::from_reader(file);
    let mut entries = Vec::new();

    for result in reader.records() {
        let record: StringRecord = result?;
        let (id, value): (String, f32) = record.deserialize(None)?;
        let score_entry = ScoreEntry::new(id, value);
        entries.push(score_entry);
    }

    Ok(entries)
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct JobMetadata {
    request_tx_hash: Option<TxHash>,
    results_tx_hash: Option<TxHash>,
    challenge_tx_hash: Option<TxHash>,
}

impl JobMetadata {
    pub fn new() -> Self {
        Self {
            request_tx_hash: None,
            results_tx_hash: None,
            challenge_tx_hash: None,
        }
    }

    pub fn set_request_tx_hash(&mut self, request_tx_hash: TxHash) {
        self.request_tx_hash = Some(request_tx_hash);
    }

    pub fn set_results_tx_hash(&mut self, results_tx_hash: TxHash) {
        self.results_tx_hash = Some(results_tx_hash);
    }

    pub fn set_challenge_tx_hash(&mut self, challenge_tx_hash: TxHash) {
        self.challenge_tx_hash = Some(challenge_tx_hash);
    }

    pub fn has_request_tx(&self) -> bool {
        self.request_tx_hash.is_some()
    }

    pub fn has_results_tx(&self) -> bool {
        self.results_tx_hash.is_some()
    }

    pub fn has_challenge_tx(&self) -> bool {
        self.challenge_tx_hash.is_some()
    }
}

#[derive(Debug, Clone, Subcommand)]
/// The method to call.
enum Method {
    MetaDownloadScores {
        compute_id: String,
        #[arg(long)]
        out_dir: Option<String>,
    },
    MetaComputeWatch {
        compute_id: String,
        #[arg(long)]
        out_dir: Option<String>,
    },
    MetaComputeRequest {
        trust_folder_path: String,
        seed_folder_path: String,
    },
    ComputeLocal {
        trust_path: String,
        seed_path: String,
        output_path: Option<String>,
    },
    VerifyLocal {
        trust_path: String,
        seed_path: String,
        scores_path: String,
    },
    UploadTrust {
        path: String,
        certs_path: String,
    },
    DownloadTrust {
        path: String,
        certs_path: String,
    },
}

#[derive(Parser, Debug)]
#[command(version, about, long_about = None)]
struct Args {
    #[command(subcommand)]
    method: Method,
}

const BUCKET_NAME: &str = "openrank-data-dev";

#[derive(Serialize, Deserialize)]
struct JobDescription {
    alpha: f32,
    name: String,
    trust_id: String,
    seed_id: String,
}

impl JobDescription {
    pub fn default_with(trust_id: String, name: String, seed_id: String) -> Self {
        Self {
            alpha: 0.5,
            trust_id,
            name,
            seed_id,
        }
    }
}

#[derive(Serialize, Deserialize)]
struct JobResult {
    scores_id: String,
    commitment: String,
}

#[tokio::main]
async fn main() -> Result<(), AwsError> {
    dotenv().ok();
    setup_tracing();
    let cli = Args::parse();
    rustls::crypto::ring::default_provider()
        .install_default()
        .expect("Failed to install rustls crypto provider");

    let rpc_url = std::env::var("CHAIN_RPC_URL").expect("CHAIN_RPC_URL must be set.");
    let manager_address =
        std::env::var("OPENRANK_MANAGER_ADDRESS").expect("OPENRANK_MANAGER_ADDRESS must be set.");
    let mnemonic = std::env::var("MNEMONIC").expect("MNEMONIC must be set.");
    let config = from_env().region("us-west-2").load().await;
    let client = Client::new(&config);

    let mut wss_url = rpc_url.clone();
    wss_url = wss_url.replace("http", "ws");
    wss_url = wss_url.replace("https", "wss");

    let wallet = MnemonicBuilder::<English>::default()
        .phrase(mnemonic)
        .index(0)
        .unwrap()
        .build()
        .unwrap();

    let ws = WsConnect::new(wss_url);
    let provider_wss = ProviderBuilder::new().on_ws(ws).await.unwrap();

    let manager_address = Address::from_hex(manager_address).unwrap();
    let manager_contract_ws = OpenRankManager::new(manager_address, provider_wss.clone());
    let provider = ProviderBuilder::new()
        .wallet(wallet)
        .on_client(RpcClient::new_http(Url::parse(&rpc_url).unwrap()));
    let current_block = provider.get_block_number().await.unwrap();
    let manager_contract = OpenRankManager::new(manager_address, provider.clone());

    // println!("current block: {}", current_block);
    let starting_block = (current_block - 10).max(0);
    match cli.method {
        Method::MetaDownloadScores {
            compute_id,
            out_dir,
        } => {
            let compute_id_uint = Uint::<256, 4>::from_str(&compute_id).unwrap();
            let compute_request = manager_contract
                .metaComputeRequests(compute_id_uint)
                .call()
                .await
                .unwrap();
            let compute_result = manager_contract
                .metaComputeResults(compute_id_uint)
                .call()
                .await
                .unwrap();
            let job_requests: Vec<JobDescription> = download_meta(
                client.clone(),
                compute_request.jobDescriptionId.encode_hex(),
            )
            .await
            .unwrap();
            let job_results: Vec<JobResult> =
                download_meta(client.clone(), compute_result.resultsId.encode_hex())
                    .await
                    .unwrap();
            let mut out_dir = out_dir.unwrap_or("./scores".to_string());
            if out_dir.ends_with("/") {
                out_dir.pop();
            }
            create_dir_all(&out_dir).await.unwrap();
            for (job_request, job_result) in job_requests.iter().zip(job_results) {
                download_scores(
                    client.clone(),
                    job_result.scores_id.clone(),
                    format!("{}/{}", out_dir, job_request.name),
                )
                .await
                .unwrap();
            }
        }
        Method::MetaComputeWatch {
            compute_id,
            out_dir,
        } => {
            let mut job_metadata = JobMetadata::new();

            let request_logs_filter = manager_contract_ws
                .MetaComputeRequestEvent_filter()
                .from_block(BlockNumberOrTag::Number(starting_block))
                .to_block(BlockNumberOrTag::Latest)
                .topic1(Uint::from_str(&compute_id).unwrap())
                .filter;
            let results_log_filter = manager_contract_ws
                .MetaComputeResultEvent_filter()
                .from_block(BlockNumberOrTag::Number(starting_block))
                .to_block(BlockNumberOrTag::Latest)
                .topic1(Uint::from_str(&compute_id).unwrap())
                .filter;
            let challenge_logs_filter = manager_contract_ws
                .MetaChallengeEvent_filter()
                .from_block(BlockNumberOrTag::Number(starting_block))
                .to_block(BlockNumberOrTag::Latest)
                .topic1(Uint::from_str(&compute_id).unwrap())
                .filter;

            let request_logs = provider.get_logs(&request_logs_filter).await.unwrap();
            let results_logs = provider.get_logs(&results_log_filter).await.unwrap();
            let challenge_logs = provider.get_logs(&challenge_logs_filter).await.unwrap();

            for log in request_logs {
                job_metadata.set_request_tx_hash(log.transaction_hash.unwrap());
            }
            for log in results_logs {
                job_metadata.set_results_tx_hash(log.transaction_hash.unwrap());
            }
            for log in challenge_logs {
                job_metadata.set_challenge_tx_hash(log.transaction_hash.unwrap());
            }

            let mut meta_compute_request_stream = manager_contract_ws
                .MetaComputeRequestEvent_filter()
                .from_block(BlockNumberOrTag::Number(current_block - 1))
                .topic1(Uint::from_str(&compute_id).unwrap())
                .watch()
                .await
                .unwrap()
                .into_stream();
            let mut meta_compute_result_stream = manager_contract_ws
                .MetaComputeResultEvent_filter()
                .from_block(BlockNumberOrTag::Number(current_block - 1))
                .topic1(Uint::from_str(&compute_id).unwrap())
                .watch()
                .await
                .unwrap()
                .into_stream();
            let mut meta_challenge_stream = manager_contract_ws
                .MetaChallengeEvent_filter()
                .from_block(BlockNumberOrTag::Number(current_block - 1))
                .topic1(Uint::from_str(&compute_id).unwrap())
                .watch()
                .await
                .unwrap()
                .into_stream();

            if !job_metadata.has_request_tx() {
                if let Some(res) = meta_compute_request_stream.next().await {
                    let (meta_request_res, log): (MetaComputeRequestEvent, Log) = res.unwrap();
                    assert!(meta_request_res.computeId.to_string() == compute_id);
                    job_metadata.set_request_tx_hash(log.transaction_hash.unwrap());
                }
            }
            if !job_metadata.has_results_tx() {
                if let Some(res) = meta_compute_result_stream.next().await {
                    let (meta_result_res, log): (MetaComputeResultEvent, Log) = res.unwrap();
                    assert!(meta_result_res.computeId.to_string() == compute_id);
                    job_metadata.set_results_tx_hash(log.transaction_hash.unwrap());
                }
            }
            if !job_metadata.has_challenge_tx() {
                if let Some(res) = meta_challenge_stream.next().await {
                    let (meta_challenge_res, log): (MetaChallengeEvent, Log) = res.unwrap();
                    assert!(meta_challenge_res.computeId.to_string() == compute_id);
                    job_metadata.set_challenge_tx_hash(log.transaction_hash.unwrap());
                }
            }

            if let Some(out_dir) = out_dir {
                save_json_to_file(
                    job_metadata,
                    Path::new(&format!("{}/metadata.json", out_dir)),
                )
                .unwrap();
            } else {
                print!("{}", serde_json::to_string(&job_metadata).unwrap())
            }
        }
        Method::MetaComputeRequest {
            trust_folder_path,
            seed_folder_path,
        } => {
            let trust_paths = read_dir(trust_folder_path).unwrap();
            let mut trust_map = HashMap::new();
            for path in trust_paths {
                let path = path.unwrap().path();
                let file_name = path.file_name().unwrap().to_str().unwrap();
                let display = path.display().to_string();
                let res = upload_trust(client.clone(), display).await.unwrap();
                trust_map.insert(file_name.to_string(), res);
            }

            let seed_paths = read_dir(seed_folder_path).unwrap();
            let mut seed_map = HashMap::new();
            for path in seed_paths {
                let path = path.unwrap().path();
                let file_name = path.file_name().unwrap().to_str().unwrap();
                let display = path.display().to_string();
                let res = upload_seed(client.clone(), display).await.unwrap();
                seed_map.insert(file_name.to_string(), res);
            }

            let mut jds = Vec::new();
            for (trust_file, trust_id) in trust_map {
                let seed_id = seed_map.get(&trust_file).unwrap();
                let job_description =
                    JobDescription::default_with(trust_id, trust_file, seed_id.clone());
                jds.push(job_description);
            }

            let meta_id = upload_meta(client, jds).await?;
            let meta_id_bytes = FixedBytes::from_hex(meta_id.clone()).unwrap();

            // Get the return value (computeId) from the transaction
            let compute_id = manager_contract
                .submitMetaComputeRequest(meta_id_bytes)
                .call()
                .await
                .unwrap()
                .computeId;

            let pending_tx = manager_contract
                .submitMetaComputeRequest(meta_id_bytes)
                .send()
                .await
                .unwrap();
            let receipt = pending_tx.get_receipt().await.unwrap();
            let tx_hash = receipt.transaction_hash;

            info!("Meta Job ID: {}", meta_id);
            info!("Tx Hash: {}", tx_hash);
            info!("Compute ID: {}", compute_id);

            println!("{}", compute_id);
        }
        Method::ComputeLocal {
            trust_path,
            seed_path,
            output_path,
        } => {
            let f = File::open(trust_path).unwrap();
            let trust_entries = parse_trust_entries_from_file(f).unwrap();

            // Read CSV, to get a list of `ScoreEntry`
            let f = File::open(seed_path).unwrap();
            let seed_entries = parse_score_entries_from_file(f).unwrap();

            let scores_vec = compute_local(&trust_entries, &seed_entries).await.unwrap();

            if let Some(output_path) = output_path {
                let scores_file = File::create(output_path).unwrap();
                let mut wtr = csv::Writer::from_writer(scores_file);
                wtr.write_record(&["i", "v"]).unwrap();
                for x in scores_vec {
                    wtr.write_record(&[x.id(), x.value().to_string().as_str()])
                        .unwrap();
                }
            } else {
                let scores_wrt = Vec::new();
                let mut wtr = csv::Writer::from_writer(scores_wrt);
                wtr.write_record(&["i", "v"]).unwrap();
                for x in scores_vec {
                    wtr.write_record(&[x.id(), x.value().to_string().as_str()])
                        .unwrap();
                }
                let res = wtr.into_inner().unwrap();
                println!("{:?}", String::from_utf8(res));
            }
        }
        Method::VerifyLocal {
            trust_path,
            seed_path,
            scores_path,
        } => {
            let f = File::open(trust_path).unwrap();
            let trust_entries = parse_trust_entries_from_file(f).unwrap();

            // Read CSV, to get a list of `ScoreEntry`
            let f = File::open(seed_path).unwrap();
            let seed_entries = parse_score_entries_from_file(f).unwrap();

            // Read CSV, to get a list of `ScoreEntry`
            let f = File::open(scores_path).unwrap();
            let scores_entries = parse_score_entries_from_file(f).unwrap();

            let res = verify_local(&trust_entries, &seed_entries, &scores_entries)
                .await
                .unwrap();
            println!("Verification result: {}", res);
        }
        Method::UploadTrust { path, certs_path } => {
            let eigen_da_url = std::env::var("EIGEN_DA_PROXY_URL").unwrap();
            {
                let f = File::open(path.clone()).unwrap();
                let mut rdr = csv::Reader::from_reader(f);
                for result in rdr.records() {
                    let record: StringRecord = result.unwrap();
                    let (_, _, _): (String, String, f32) = record.deserialize(None).unwrap();
                }
            }
            let data = std::fs::read(&path).unwrap(); // Read the contents of the file into a vector of bytes

            let eigenda_client = EigenDAProxyClient::new(eigen_da_url);
            let res = eigenda_client.put_meta(data).await.unwrap();

            let mut file = File::create(certs_path).unwrap();
            file.write(&res).unwrap();
        }
        Method::DownloadTrust { path, certs_path } => {
            let eigen_da_url = std::env::var("EIGEN_DA_PROXY_URL").unwrap();
            let data = std::fs::read(&certs_path).unwrap();

            let eigenda_client = EigenDAProxyClient::new(eigen_da_url);

            let res = eigenda_client.put_meta(data).await.unwrap();
            let mut file = File::create(path).unwrap();
            file.write(&res).unwrap();
        }
    };

    Ok(())
}
