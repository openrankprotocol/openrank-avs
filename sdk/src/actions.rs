use crate::BUCKET_NAME;
use alloy::hex::{self};
use aws_sdk_s3::{primitives::ByteStream, Client, Error as AwsError};
use openrank_common::{
    merkle::Hash,
    runners::{
        compute_runner::{self, ComputeRunner},
        verification_runner::{self, VerificationRunner},
    },
    tx::trust::{ScoreEntry, TrustEntry},
    Domain,
};
use serde::{de::DeserializeOwned, Serialize};
use sha3::{Digest, Keccak256};
use std::{
    fs::File,
    io::{Read, Write},
};

pub async fn upload_trust(client: Client, path: String) -> Result<String, AwsError> {
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

    println!("Uploading trust data: {}", hex::encode(hash.clone()));

    client
        .put_object()
        .bucket(BUCKET_NAME)
        .key(format!("trust/{}", hex::encode(hash.clone())))
        .body(body)
        .send()
        .await?;

    Ok(hex::encode(hash))
}

pub async fn upload_seed(client: Client, path: String) -> Result<String, AwsError> {
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

    println!("Uploading seed data: {}", hex::encode(hash.clone()));

    client
        .put_object()
        .bucket(BUCKET_NAME)
        .key(format!("seed/{}", hex::encode(hash.clone())))
        .body(body)
        .send()
        .await?;

    Ok(hex::encode(hash))
}

pub async fn _download_trust(
    client: Client,
    trust_id: String,
    path: String,
) -> Result<(), AwsError> {
    let mut file = File::create(path).unwrap();
    let mut res = client
        .get_object()
        .bucket(BUCKET_NAME)
        .key(format!("trust/{}", trust_id))
        .send()
        .await?;
    while let Some(bytes) = res.body.next().await {
        file.write(&bytes.unwrap()).unwrap();
    }
    Ok(())
}

pub async fn _download_seed(client: Client, seed_id: String, path: String) -> Result<(), AwsError> {
    let mut file = File::create(path).unwrap();
    let mut res = client
        .get_object()
        .bucket(BUCKET_NAME)
        .key(format!("seed/{}", seed_id))
        .send()
        .await?;
    while let Some(bytes) = res.body.next().await {
        file.write(&bytes.unwrap()).unwrap();
    }
    Ok(())
}

pub async fn download_scores(
    client: Client,
    scores_id: String,
    path: String,
) -> Result<(), AwsError> {
    let mut file = File::create(path).unwrap();
    let mut res = client
        .get_object()
        .bucket(BUCKET_NAME)
        .key(format!("scores/{}", scores_id))
        .send()
        .await?;
    println!("{:?}", res);
    while let Some(bytes) = res.body.next().await {
        file.write(&bytes.unwrap()).unwrap();
    }
    Ok(())
}

pub async fn upload_meta<T: Serialize>(client: Client, meta: T) -> Result<String, AwsError> {
    let mut bytes = serde_json::to_vec(&meta).unwrap();
    let body = ByteStream::from(bytes.clone());

    let mut hasher = Keccak256::new();
    hasher.write_all(&mut bytes).unwrap();
    let hash = hasher.finalize().to_vec();
    client
        .put_object()
        .bucket(BUCKET_NAME)
        .key(format!("meta/{}", hex::encode(hash.clone())))
        .body(body)
        .send()
        .await?;
    Ok(hex::encode(hash))
}

pub async fn download_meta<T: DeserializeOwned>(
    client: Client,
    meta_id: String,
) -> Result<T, AwsError> {
    let res = client
        .get_object()
        .bucket(BUCKET_NAME)
        .key(format!("meta/{}", meta_id))
        .send()
        .await?;
    let res_bytes = res.body.collect().await.unwrap();
    let meta: T = serde_json::from_slice(res_bytes.to_vec().as_slice()).unwrap();
    Ok(meta)
}

pub async fn compute_local(
    trust_entries: &[TrustEntry],
    seed_entries: &[ScoreEntry],
) -> Result<Vec<ScoreEntry>, compute_runner::Error> {
    let mock_domain = Domain::default();
    let mut runner = ComputeRunner::new(&[mock_domain.clone()]);
    runner.update_trust(mock_domain.clone(), trust_entries.to_vec())?;
    runner.update_seed(mock_domain.clone(), seed_entries.to_vec())?;
    runner.compute(mock_domain.clone())?;
    let scores = runner.get_compute_scores(mock_domain.clone())?;
    Ok(scores)
}

pub async fn verify_local(
    trust_entries: &[TrustEntry],
    seed_entries: &[ScoreEntry],
    scores_entries: &[ScoreEntry],
) -> Result<bool, verification_runner::Error> {
    let mock_domain = Domain::default();
    let mut runner = VerificationRunner::new(&[mock_domain.clone()]);
    runner.update_trust_map(mock_domain.clone(), trust_entries.to_vec())?;
    runner.update_seed_map(mock_domain.clone(), seed_entries.to_vec())?;
    runner.update_scores(
        mock_domain.clone(),
        Hash::default(),
        scores_entries.to_vec(),
    )?;
    let result = runner.verify_scores(mock_domain, Hash::default())?;
    Ok(result)
}
