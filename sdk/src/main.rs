mod actions;
mod sol;

use actions::{
    compute_local, download_meta, download_scores, upload_meta, upload_seed, upload_trust,
    verify_local,
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
use csv::StringRecord;
use dotenv::dotenv;
use openrank_common::eigenda::EigenDAProxyClient;
use openrank_common::tx::trust::{ScoreEntry, TrustEntry};
use serde::{Deserialize, Serialize};
use sol::OpenRankManager;
use std::collections::HashMap;
use std::fs::{read_dir, File};
use std::io::Write;

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

/// Helper function to validate trust CSV format
fn validate_trust_csv(path: &str) -> Result<(), csv::Error> {
    let file = File::open(path).unwrap();
    let mut reader = csv::Reader::from_reader(file);
    for result in reader.records() {
        let record: StringRecord = result?;
        let (_, _, _): (String, String, f32) = record.deserialize(None)?;
    }
    Ok(())
}

#[derive(Debug, Clone, Subcommand)]
/// The method to call.
enum Method {
    // Meta jobs
    MetaDownloadScores {
        results_id: String,
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

    let eigen_da_url = std::env::var("DA_PROXY_URL").expect("DA_PROXY_URL must be set.");
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

            let res = contract
                .submitMetaComputeRequest(meta_id_bytes)
                .send()
                .await
                .unwrap();
            println!("Meta Job ID: {}", meta_id);
            println!("Tx Hash: {}", res.watch().await.unwrap());
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
            // Validate CSV format
            validate_trust_csv(&path).unwrap();
            let data = std::fs::read(&path).unwrap(); // Read the contents of the file into a vector of bytes

            let eigenda_client = EigenDAProxyClient::new(eigen_da_url);
            let res = eigenda_client.put_meta(data).await.unwrap();

            let mut file = File::create(certs_path).unwrap();
            file.write(&res).unwrap();
        }
        Method::DownloadTrust { path, certs_path } => {
            let data = std::fs::read(&certs_path).unwrap();

            let eigenda_client = EigenDAProxyClient::new(eigen_da_url);

            let res = eigenda_client.get_meta(data).await.unwrap();
            let mut file = File::create(path).unwrap();
            file.write(&res).unwrap();
        }
    };

    Ok(())
}
