use alloy::hex::FromHex;
use alloy::primitives::Address;
use alloy::providers::{ProviderBuilder, WsConnect};
use alloy::rpc::client::RpcClient;
use alloy::signers::local::coins_bip39::English;
use alloy::signers::local::MnemonicBuilder;
use alloy::transports::http::reqwest::Url;
use aws_config::from_env;
use aws_sdk_s3::Client;
use clap::Parser;
use dotenv::dotenv;
use openrank_common::eigenda::EigenDAProxyClient;
use openrank_common::logs::setup_tracing;
use openrank_node::sol::{OpenRankManager, ReexecutionEndpoint};
use openrank_node::{challenger, computer};

const BUCKET_NAME: &str = "openrank-data-dev";

#[derive(Parser, Debug)]
#[command(version, about, long_about = None)]
struct Args {
    #[arg(long)]
    challenger: bool,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();
    dotenv().ok();
    setup_tracing();

    let cli = Args::parse();

    let eigenda_url = std::env::var("EIGEN_DA_PROXY_URL").expect("EIGEN_DA_PROXY_URL must be set.");
    let rpc_url = std::env::var("CHAIN_RPC_URL").expect("CHAIN_RPC_URL must be set.");
    let wss_url = std::env::var("CHAIN_WSS_URL").expect("CHAIN_WSS_URL must be set.");
    let manager_address =
        std::env::var("OPENRANK_MANAGER_ADDRESS").expect("OPENRANK_MANAGER_ADDRESS must be set.");
    let rxp_address = std::env::var("REEXECUTION_ENDPOINT_ADDRESS")
        .expect("REEXECUTION_ENDPOINT_ADDRESS must be set.");
    let mnemonic = std::env::var("MNEMONIC").expect("MNEMONIC must be set.");
    let config = from_env().region("us-west-2").load().await;
    let client = Client::new(&config);

    println!("rpc_url: {}", rpc_url);
    println!("wss_url: {}", wss_url);
    println!("eigenda_url: {}", eigenda_url);

    let wallet = MnemonicBuilder::<English>::default()
        .phrase(mnemonic)
        .index(0)
        .map_err(|e| format!("Failed to set mnemonic index: {}", e))?
        .build()
        .map_err(|e| format!("Failed to build wallet: {}", e))?;

    let rpc_url_parsed = Url::parse(&rpc_url)
        .map_err(|e| format!("Failed to parse RPC URL '{}': {}", rpc_url, e))?;
    let provider_http = ProviderBuilder::new()
        .wallet(wallet.clone())
        .on_client(RpcClient::new_http(rpc_url_parsed));

    let ws = WsConnect::new(wss_url);
    let provider_wss = ProviderBuilder::new()
        .on_ws(ws)
        .await
        .map_err(|e| format!("Failed to connect to WebSocket: {}", e))?;

    let manager_address = Address::from_hex(manager_address)
        .map_err(|e| format!("Failed to parse manager address: {}", e))?;
    let manager_contract = OpenRankManager::new(manager_address, provider_http.clone());
    let manager_contract_ws = OpenRankManager::new(manager_address, provider_wss.clone());

    let rxp_address = Address::from_hex(rxp_address)
        .map_err(|e| format!("Failed to parse RXP address: {}", e))?;
    let rxp_contract = ReexecutionEndpoint::new(rxp_address, provider_wss);

    let eigenda_client = EigenDAProxyClient::new(eigenda_url);

    if cli.challenger {
        if let Err(e) = challenger::run(
            manager_contract,
            rxp_contract,
            provider_http,
            client,
            eigenda_client,
            BUCKET_NAME,
        )
        .await
        {
            eprintln!("Challenger failed: {}", e);
            std::process::exit(1);
        }
    } else {
        if let Err(e) =
            computer::run(manager_contract, manager_contract_ws, client, BUCKET_NAME).await
        {
            eprintln!("Computer failed: {}", e);
            std::process::exit(1);
        }
    }
    Ok(())
}
