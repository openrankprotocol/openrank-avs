mod sol;

use std::fs::File;
use std::io::Write;

use alloy::eips::BlockNumberOrTag;
use alloy::primitives::{Address, FixedBytes};
use alloy::providers::{Provider, ProviderBuilder};
use alloy::rpc::client::RpcClient;
use alloy::signers::local::coins_bip39::English;
use alloy::signers::local::MnemonicBuilder;
use alloy::transports::http::reqwest::Url;
use alloy::{hex::FromHex, rpc::types::Log};
use aws_config::from_env;
use aws_sdk_s3::primitives::ByteStream;
use aws_sdk_s3::Client;
use clap::Parser;
use csv::StringRecord;
use dotenv::dotenv;
use futures_util::StreamExt;
use openrank_common::runners::compute_runner::ComputeRunner;
use openrank_common::tx::trust::{ScoreEntry, TrustEntry};
use openrank_common::Domain;
use sha3::{Digest, Keccak256};
use sol::OpenRankManager::{
    self, ChallengeEvent, ComputeRequestEvent, ComputeResultEvent, JobFinalized,
};
use tokio::select;

const BLOCK_HISTORY_NUMBER: u64 = 10000;

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
    let latest_block = provider.get_block_number().await.unwrap();

    let contract = OpenRankManager::new(Address::from_hex(manager_address).unwrap(), provider);

    // Create filters for each event.
    let compute_request_filter = contract
        .ComputeRequestEvent_filter()
        .from_block(BlockNumberOrTag::Number(
            latest_block - BLOCK_HISTORY_NUMBER,
        ))
        .watch()
        .await
        .unwrap();
    let compute_result_filter = contract
        .ComputeResultEvent_filter()
        .from_block(BlockNumberOrTag::Number(
            latest_block - BLOCK_HISTORY_NUMBER,
        ))
        .watch()
        .await
        .unwrap();
    let challenge_filter = contract
        .ChallengeEvent_filter()
        .from_block(BlockNumberOrTag::Number(
            latest_block - BLOCK_HISTORY_NUMBER,
        ))
        .watch()
        .await
        .unwrap();
    let job_finalised_filter = contract
        .JobFinalized_filter()
        .from_block(BlockNumberOrTag::Number(
            latest_block - BLOCK_HISTORY_NUMBER,
        ))
        .watch()
        .await
        .unwrap();

    let mut compute_request_stream = compute_request_filter.into_stream();
    let mut compute_result_stream = compute_result_filter.into_stream();
    let mut challenge_stream = challenge_filter.into_stream();
    let mut job_finalised_stream = job_finalised_filter.into_stream();

    println!("Running the node");

    loop {
        select! {
            compute_request_event = compute_request_stream.next() => {
                if let Some(res) = compute_request_event {
                    let (compute_req, log): (ComputeRequestEvent, Log) = res.unwrap();
                    println!("({} {} {})", compute_req.computeId, compute_req.trust_id, compute_req.seed_id);
                    println!("{:?}", log);

                    let trust_id_str = hex::encode(compute_req.trust_id.as_slice());
                    let seed_id_str = hex::encode(compute_req.seed_id.as_slice());
                    let mut trust_file = File::create(&format!("./trust/{}", trust_id_str)).unwrap();
                    let mut seed_file = File::create(&format!("./seed/{}", seed_id_str)).unwrap();

                    let mut trust_res = client
                        .get_object()
                        .bucket(bucket_name.clone())
                        .key(format!("trust/{}", trust_id_str))
                        .send()
                        .await.unwrap();
                    let mut seed_res = client
                        .get_object()
                        .bucket(bucket_name.clone())
                        .key(format!("seed/{}", seed_id_str))
                        .send()
                        .await.unwrap();


                    while let Some(bytes) = trust_res.body.next().await {
                        trust_file.write(&bytes.unwrap()).unwrap();
                    }

                    while let Some(bytes) = seed_res.body.next().await {
                        seed_file.write(&bytes.unwrap()).unwrap();
                    }

                    let mut trust_rdr = csv::Reader::from_reader(trust_file);
                    let mut seed_rdr = csv::Reader::from_reader(seed_file);

                    let mut trust_entries = Vec::new();
                    for result in trust_rdr.records() {
                        let record: StringRecord = result.unwrap();
                        let (from, to, value): (String, String, f32) =
                            record.deserialize(None).unwrap();
                        let trust_entry = TrustEntry::new(from, to, value);
                        trust_entries.push(trust_entry);
                    }

                    let mut seed_entries = Vec::new();
                    for result in seed_rdr.records() {
                        let record: StringRecord = result.unwrap();
                        let (id, value): (String, f32) =
                            record.deserialize(None).unwrap();
                        let trust_entry = ScoreEntry::new(id, value);
                        seed_entries.push(trust_entry);
                    }

                    let mock_domain = Domain::default();
                    let mut runner = ComputeRunner::new(&[mock_domain.clone()]);
                    runner
                        .update_trust(mock_domain.clone(), trust_entries.to_vec())
                        .unwrap();
                    runner
                        .update_seed(mock_domain.clone(), seed_entries.to_vec())
                        .unwrap();
                    runner.compute(mock_domain.clone()).unwrap();
                    let scores = runner.get_compute_scores(mock_domain.clone()).unwrap();
                    runner.create_compute_tree(mock_domain.clone()).unwrap();
                    let score_entries: Vec<ScoreEntry> = scores.iter().flat_map(|x| x.clone().inner()).collect();
                    let (_, compute_root) = runner.get_root_hashes(mock_domain.clone()).unwrap();

                    let scores_vec = Vec::new();
                    let mut wtr = csv::Writer::from_writer(scores_vec);
                    score_entries.iter().for_each(|x| {
                        wtr.write_record(&[x.id(), x.value().to_string().as_str()]).unwrap();
                    });
                    let mut file_bytes = wtr.into_inner().unwrap();
                    let mut hasher = Keccak256::new();
                    hasher.write_all(&mut file_bytes).unwrap();
                    let scores_id = hasher.finalize().to_vec();

                    let body = ByteStream::from(file_bytes);
                    let res = client
                        .put_object()
                        .bucket(bucket_name.clone())
                        .key(format!("./scores/{}", hex::encode(scores_id.clone())))
                        .body(body)
                        .send()
                        .await.unwrap();

                    println!("{:?}", res);

                    let commitment_bytes = FixedBytes::from_slice(compute_root.inner());
                    let scores_id_bytes = FixedBytes::from_slice(scores_id.as_slice());

                    let required_stake = contract.STAKE().call().await.unwrap();
                    println!("{:?}", required_stake._0);
                    let res = contract
                        .submitComputeResult(compute_req.computeId, commitment_bytes, scores_id_bytes)
                        .value(required_stake._0)
                        .send()
                        .await
                        .unwrap();
                    println!("Tx Hash: {}", res.watch().await.unwrap());
                }
            }
            compute_result_event = compute_result_stream.next() => {
                if let Some(res) = compute_result_event {
                    let (compute_req, log): (ComputeResultEvent, Log) = res.unwrap();
                    println!("({} {} {})", compute_req.computeId, compute_req.commitment, compute_req.scores_id);
                    println!("{:?}", log);
                }
            }
            challenge_event = challenge_stream.next() => {
                if let Some(res) = challenge_event {
                    let (challenge, log): (ChallengeEvent, Log) = res.unwrap();
                    println!("({})", challenge.computeId);
                    println!("{:?}", log);
                }
            }
            job_finalised_event = job_finalised_stream.next() => {
                if let Some(res) = job_finalised_event {
                    let (challenge, log): (JobFinalized, Log) = res.unwrap();
                    println!("({})", challenge.computeId);
                    println!("{:?}", log);
                }
            }
        }
    }
}
