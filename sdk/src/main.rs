mod sol;

use alloy::hex::{self, FromHex};
use alloy::primitives::{Address, FixedBytes};
use alloy::providers::ProviderBuilder;
use alloy::rpc::client::RpcClient;
use alloy::signers::local::coins_bip39::English;
use alloy::signers::local::MnemonicBuilder;
use alloy::transports::http::reqwest::Url;
use aws_config::from_env;
use aws_sdk_s3::primitives::ByteStream;
use aws_sdk_s3::{Client, Error as AwsError};
use clap::{Parser, Subcommand};
use dotenv::dotenv;
use sha3::{Digest, Keccak256};
use sol::OpenRankManager;
use std::fs::File;
use std::io::{Read, Write};

#[derive(Debug, Clone, Subcommand)]
/// The method to call.
enum Method {
    UploadTrust { path: String },
    UploadSeed { path: String },
    DownloadTrust { trust_id: String, path: String },
    DownloadSeed { seed_id: String, path: String },
    DownloadScores { scores_id: String, path: String },
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

    let bucket_name = std::env::var("BUCKET_NAME").expect("BUCKET_NAME must be set.");
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
            let mut f = File::open(path.clone()).unwrap();
            let mut file_bytes = Vec::new();
            f.read_to_end(&mut file_bytes).unwrap();
            let body = ByteStream::from(file_bytes.clone());

            let mut hasher = Keccak256::new();
            hasher.write_all(&mut file_bytes).unwrap();
            let hash = hasher.finalize().to_vec();

            let mut rdr = csv::Reader::from_reader(f);
            for result in rdr.records() {
                let record: csv::StringRecord = result.unwrap();
                let (_, _, _): (String, String, f32) = record.deserialize(None).unwrap();
            }

            client
                .put_object()
                .bucket(bucket_name)
                .key(format!("trust/{}", hex::encode(hash.clone())))
                .body(body)
                .send()
                .await?;
            println!("Hash:({})", hex::encode(hash.clone()));
        }
        Method::UploadSeed { path } => {
            let mut f = File::open(path.clone()).unwrap();
            let mut file_bytes = Vec::new();
            f.read_to_end(&mut file_bytes).unwrap();
            let body = ByteStream::from(file_bytes.clone());

            let mut hasher = Keccak256::new();
            hasher.write_all(&mut file_bytes).unwrap();
            let hash = hasher.finalize().to_vec();

            let mut rdr = csv::Reader::from_reader(f);
            for result in rdr.records() {
                let record: csv::StringRecord = result.unwrap();
                let (_, _): (String, f32) = record.deserialize(None).unwrap();
            }

            client
                .put_object()
                .bucket(bucket_name)
                .key(format!("seed/{}", hex::encode(hash.clone())))
                .body(body)
                .send()
                .await?;
            println!("Hash:({})", hex::encode(hash.clone()));
        }
        Method::DownloadTrust { trust_id, path } => {
            let mut file = File::create(path).unwrap();
            let mut res = client
                .get_object()
                .bucket(bucket_name)
                .key(format!("trust/{}", trust_id))
                .send()
                .await?;
            while let Some(bytes) = res.body.next().await {
                file.write(&bytes.unwrap()).unwrap();
            }
        }
        Method::DownloadSeed { seed_id, path } => {
            let mut file = File::create(path).unwrap();
            let mut res = client
                .get_object()
                .bucket(bucket_name)
                .key(format!("seed/{}", seed_id))
                .send()
                .await?;
            while let Some(bytes) = res.body.next().await {
                file.write(&bytes.unwrap()).unwrap();
            }
        }
        Method::DownloadScores { scores_id, path } => {
            let mut file = File::create(path).unwrap();
            let mut res = client
                .get_object()
                .bucket(bucket_name)
                .key(format!("scores/{}", scores_id))
                .send()
                .await?;
            println!("{:?}", res);
            while let Some(bytes) = res.body.next().await {
                file.write(&bytes.unwrap()).unwrap();
            }
        }
        Method::RequestCompute { trust_id, seed_id } => {
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
    };

    Ok(())
}
