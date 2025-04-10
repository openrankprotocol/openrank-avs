mod actions;
mod sol;

use std::collections::HashMap;
use std::fs::read_dir;

use actions::{
    download_meta, download_scores, download_seed, download_trust, upload_meta, upload_seed,
    upload_trust,
};
use alloy::hex::FromHex;
use alloy::primitives::{Address, FixedBytes};
use alloy::providers::ProviderBuilder;
use alloy::rpc::client::RpcClient;
use alloy::signers::local::coins_bip39::English;
use alloy::signers::local::MnemonicBuilder;
use alloy::transports::http::reqwest::Url;
use aws_config::from_env;
use aws_sdk_s3::{Client, Error as AwsError};
use clap::{Parser, Subcommand};
use dotenv::dotenv;
use serde::{Deserialize, Serialize};
use sol::OpenRankManager;

#[derive(Debug, Clone, Subcommand)]
/// The method to call.
enum Method {
    UploadTrust {
        path: String,
    },
    UploadSeed {
        path: String,
    },
    DownloadTrust {
        trust_id: String,
        path: String,
    },
    DownloadSeed {
        seed_id: String,
        path: String,
    },
    DownloadScores {
        scores_id: String,
        path: String,
    },
    ComputeRequest {
        trust_id: String,
        seed_id: String,
    },

    // Meta jobs
    MetaDownloadScores {
        results_id: String,
    },
    MetaComputeRequest {
        trust_folder_path: String,
        seed_folder_path: String,
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
    trust_id: String,
    seed_id: String,
}

impl JobDescription {
    pub fn default_with(trust_id: String, seed_id: String) -> Self {
        Self {
            alpha: 0.5,
            trust_id,
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
    let cli = Args::parse();

    let rpc_url = std::env::var("CHAIN_RPC_URL").expect("CHAIN_RPC_URL must be set.");
    let manager_address =
        std::env::var("OPENRANK_MANAGER_ADDRESS").expect("OPENRANK_MANAGER_ADDRESS must be set.");
    let mnemonic = std::env::var("MNEMONIC").expect("MNEMONIC must be set.");
    let config = from_env().region("us-west-2").load().await;
    let client = Client::new(&config);

    let wallet = MnemonicBuilder::<English>::default()
        .phrase(mnemonic)
        .index(0)
        .unwrap()
        .build()
        .unwrap();

    match cli.method {
        Method::UploadTrust { path } => {
            let hash = upload_trust(client.clone(), path).await?;
            println!("Hash:({})", hash);
        }
        Method::UploadSeed { path } => {
            let hash = upload_seed(client.clone(), path).await?;
            println!("Hash:({})", hash);
        }
        Method::DownloadTrust { trust_id, path } => download_trust(client, trust_id, path).await?,
        Method::DownloadSeed { seed_id, path } => download_seed(client, seed_id, path).await?,
        Method::DownloadScores { scores_id, path } => {
            download_scores(client, scores_id, path).await?
        }
        Method::ComputeRequest { trust_id, seed_id } => {
            let provider = ProviderBuilder::new()
                .wallet(wallet)
                .on_client(RpcClient::new_http(Url::parse(&rpc_url).unwrap()));

            let contract =
                OpenRankManager::new(Address::from_hex(manager_address).unwrap(), provider);

            let trust_id_bytes = FixedBytes::from_hex(trust_id).unwrap();
            let seed_id_bytes = FixedBytes::from_hex(seed_id).unwrap();

            let required_fee = contract.FEE().call().await.unwrap();
            let res = contract
                .submitComputeRequest(trust_id_bytes, seed_id_bytes)
                .value(required_fee._0)
                .send()
                .await
                .unwrap();
            println!("Tx Hash: {}", res.watch().await.unwrap());
        }
        Method::MetaDownloadScores { results_id } => {
            let job_results: Vec<JobResult> =
                download_meta(client.clone(), results_id).await.unwrap();
            for job_result in job_results {
                download_scores(
                    client.clone(),
                    job_result.scores_id.clone(),
                    format!("./scores/{}", job_result.scores_id),
                )
                .await
                .unwrap();
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
                let job_description = JobDescription::default_with(trust_id, seed_id.clone());
                jds.push(job_description);
            }

            let meta_id = upload_meta(client, jds).await?;

            let provider = ProviderBuilder::new()
                .wallet(wallet)
                .on_client(RpcClient::new_http(Url::parse(&rpc_url).unwrap()));

            let contract =
                OpenRankManager::new(Address::from_hex(manager_address).unwrap(), provider);

            let meta_id_bytes = FixedBytes::from_hex(meta_id.clone()).unwrap();

            let required_fee = contract.FEE().call().await.unwrap();
            let res = contract
                .submitMetaComputeRequest(meta_id_bytes)
                .value(required_fee._0)
                .send()
                .await
                .unwrap();
            println!("Meta Job ID: {}", meta_id);
            println!("Tx Hash: {}", res.watch().await.unwrap());
        }
    };

    Ok(())
}
