mod sol;

use alloy::primitives::{address, FixedBytes};
use alloy::providers::ProviderBuilder;
use alloy::rpc::client::RpcClient;
use alloy::transports::http::reqwest::Url;
use alloy_rlp::encode;
use aws_config::from_env;
use aws_sdk_s3::primitives::ByteStream;
use aws_sdk_s3::{Client, Error as AwsError};
use clap::{Parser, Subcommand};
use dotenv::dotenv;
use openrank_common::tx::trust::{ScoreEntry, TrustEntry};
use sha3::{Digest, Keccak256};
use sol::OpenRankManager;
use std::fs::File;
use std::io::Write;

const BUCKET_NAME: &str = "openrank-data";

#[derive(Debug, Clone, Subcommand)]
/// The method to call.
enum Method {
    UploadTrust { path: String },
    UploadSeed { path: String },
    DownloadTrust { trust_id: String },
    DownloadSeed { seed_id: String },
    DownloadScores { scores_id: String },
    RequestCompute { trust_id: String, seed_id: String },
}

#[derive(Parser, Debug)]
#[command(version, about, long_about = None)]
struct Args {
    #[command(subcommand)]
    method: Method,
}

#[tokio::main]
async fn main() -> Result<(), AwsError> {
    dotenv().ok();
    let cli = Args::parse();

    let config = from_env().region("eu-north-1").load().await;
    let client = Client::new(&config);

    match cli.method {
        Method::UploadTrust { path } => {
            let f = File::open(path).unwrap();
            let mut rdr = csv::Reader::from_reader(f);

            let mut hasher = Keccak256::new();
            let mut bytes = Vec::new();
            for result in rdr.records() {
                let record: csv::StringRecord = result.unwrap();
                let (from, to, value): (String, String, f32) = record.deserialize(None).unwrap();
                let trust_entry = TrustEntry::new(from, to, value);
                let res = encode(trust_entry);
                hasher.write(res.as_slice()).unwrap();
                bytes.extend(res);
            }
            let hash = hasher.finalize().to_vec();
            let body = ByteStream::from(bytes);

            let res = client
                .put_object()
                .bucket(BUCKET_NAME)
                .key(format!("trust/{}", hex::encode(hash)))
                .body(body)
                .send()
                .await?;
            println!("{:?}", res);
        }
        Method::UploadSeed { path } => {
            let f = File::open(path).unwrap();
            let mut rdr = csv::Reader::from_reader(f);

            let mut hasher = Keccak256::new();
            let mut bytes = Vec::new();
            for result in rdr.records() {
                let record: csv::StringRecord = result.unwrap();
                let (id, value): (String, f32) = record.deserialize(None).unwrap();
                let trust_entry = ScoreEntry::new(id, value);
                let res = encode(trust_entry);
                hasher.write(res.as_slice()).unwrap();
                bytes.extend(res);
            }
            let hash = hasher.finalize().to_vec();
            let body = ByteStream::from(bytes);

            let res = client
                .put_object()
                .bucket(BUCKET_NAME)
                .key(format!("seed/{}", hex::encode(hash)))
                .body(body)
                .send()
                .await?;
            println!("{:?}", res);
        }
        Method::DownloadTrust { trust_id } => {
            let res = client
                .get_object()
                .bucket(BUCKET_NAME)
                .key(format!("trust/{}", trust_id))
                .send()
                .await?;
            println!("{:?}", res);
        }
        Method::DownloadSeed { seed_id } => {
            let res = client
                .get_object()
                .bucket(BUCKET_NAME)
                .key(format!("seed/{}", seed_id))
                .send()
                .await?;
            println!("{:?}", res);
        }
        Method::DownloadScores { scores_id } => {
            let res = client
                .get_object()
                .bucket(BUCKET_NAME)
                .key(format!("scores/{}", scores_id))
                .send()
                .await?;
            println!("{:?}", res);
        }
        Method::RequestCompute { trust_id, seed_id } => {
            let rpc_url = "https://eth.merkle.io";
            let provider =
                ProviderBuilder::new().on_client(RpcClient::new_http(Url::parse(rpc_url).unwrap()));
            let contract = OpenRankManager::new(
                address!("C02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"),
                provider,
            );

            let trust_id_bytes = FixedBytes::from_slice(hex::decode(trust_id).unwrap().as_slice());
            let seed_id_bytes = FixedBytes::from_slice(hex::decode(seed_id).unwrap().as_slice());
            let res = contract
                .submitComputeRequest(trust_id_bytes, seed_id_bytes)
                .call()
                .await;
            println!("Compute ID: {}", res.unwrap().computeId);
        }
    };

    Ok(())
}
