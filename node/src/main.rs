mod computer;
mod sol;

use alloy::hex::FromHex;
use alloy::primitives::Address;
use alloy::providers::ProviderBuilder;
use alloy::rpc::client::RpcClient;
use alloy::signers::local::coins_bip39::English;
use alloy::signers::local::MnemonicBuilder;
use alloy::transports::http::reqwest::Url;
use aws_config::from_env;
use aws_sdk_s3::Client;
use clap::Parser;
use dotenv::dotenv;
use sol::OpenRankManager;

#[derive(Parser, Debug)]
#[command(version, about, long_about = None)]
struct Args {
    #[arg(long)]
    challenger: bool,
}

#[tokio::main]
async fn main() {
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

    let provider = ProviderBuilder::new()
        .wallet(wallet)
        .on_client(RpcClient::new_http(Url::parse(&rpc_url).unwrap()));

    let contract = OpenRankManager::new(
        Address::from_hex(manager_address).unwrap(),
        provider.clone(),
    );

    if cli.challenger {
    } else {
        computer::run(contract, provider, client, bucket_name).await;
    }
}
