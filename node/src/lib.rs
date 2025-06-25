pub mod challenger;
pub mod computer;
pub mod error;
pub mod sol;

// Re-export Error type for public API
pub use crate::error::Error;
use alloy::primitives::{FixedBytes, Uint};
use alloy_rlp::RlpEncodable;
use csv::StringRecord;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};

use aws_sdk_s3::Client as S3Client;
use std::fs::File;
use std::io::Write;

/// Common job description used across computer, challenger, and rxp modules
#[derive(Serialize, Deserialize, Clone)]
pub struct JobDescription {
    pub alpha: f32,
    pub trust_id: String,
    pub seed_id: String,
}

/// Common job result used across computer, challenger, and rxp modules
#[derive(Serialize, Deserialize, Clone)]
pub struct JobResult {
    pub scores_id: String,
    pub commitment: String,
}

impl JobResult {
    pub fn new(scores_id: String, commitment: String) -> Self {
        Self {
            scores_id,
            commitment,
        }
    }
}

/// EigenDA job description used in challenger and rxp modules
#[derive(Serialize, Deserialize)]
pub struct EigenDaJobDescription {
    pub neighbour_commitments: Vec<String>,
    pub trust_data: Vec<u8>,
    pub seed_data: Vec<u8>,
    pub scores_data: Vec<u8>,
}

impl EigenDaJobDescription {
    pub fn new(
        neighbour_commitments: Vec<String>,
        trust_data: Vec<u8>,
        seed_data: Vec<u8>,
        scores_data: Vec<u8>,
    ) -> Self {
        Self {
            neighbour_commitments,
            trust_data,
            seed_data,
            scores_data,
        }
    }
}

/// OpenRank execution input used in rxp module
#[derive(Debug, Default)]
pub struct OpenRankExeInput {
    pub compute_id: Uint<256, 4>,
    pub job_id: u32,
}

impl OpenRankExeInput {
    pub fn new(compute_id: Uint<256, 4>, job_id: u32) -> Self {
        Self { compute_id, job_id }
    }
}

/// OpenRank execution result used in rxp module
#[derive(Debug, Default, RlpEncodable)]
pub struct OpenRankExeResult {
    pub result: bool,
    pub meta_commitment: FixedBytes<32>,
    pub sub_job_commitment: FixedBytes<32>,
}

/// Creates CSV data from score entries and computes Keccak256 hash
///
/// This function takes a collection of score entries, converts them to CSV format
/// with headers "i,v" (id, value), and computes a Keccak256 hash of the CSV data.
///
/// # Arguments
/// * `scores` - An iterator over items that implement ScoreEntry-like interface (have id() and value() methods)
///
/// # Returns
/// * `Result<(Vec<u8>, Vec<u8>), Error>` - Tuple of (CSV bytes, hash bytes) or an error
///
/// # Examples
/// ```
/// use openrank_common::tx::trust::ScoreEntry;
/// use openrank_node::create_csv_and_hash_from_scores;
///
/// let scores = vec![
///     ScoreEntry::new("alice".to_string(), 0.95),
///     ScoreEntry::new("bob".to_string(), 0.87),
/// ];
/// let (csv_data, hash) = create_csv_and_hash_from_scores(scores).unwrap();
/// let hash_hex = alloy::hex::encode(hash);
/// ```
pub fn create_csv_and_hash_from_scores<I>(scores: I) -> Result<(Vec<u8>, Vec<u8>), Error>
where
    I: IntoIterator<Item = openrank_common::tx::trust::ScoreEntry>,
{
    use sha3::{Digest, Keccak256};

    let scores_vec = Vec::new();
    let mut wtr = csv::Writer::from_writer(scores_vec);
    wtr.write_record(&["i", "v"]).map_err(Error::CsvError)?;

    for score in scores {
        wtr.write_record(&[score.id(), score.value().to_string().as_str()])
            .map_err(Error::CsvError)?;
    }

    let csv_bytes = wtr
        .into_inner()
        .map_err(|e| Error::FileError(format!("Failed to get CSV writer inner data: {}", e)))?;

    let mut hasher = Keccak256::new();
    hasher
        .write_all(&csv_bytes)
        .map_err(|e| Error::FileError(format!("Failed to write to hasher: {}", e)))?;
    let hash = hasher.finalize().to_vec();

    Ok((csv_bytes, hash))
}

/// Creates CSV file from score entries and computes Keccak256 hash
///
/// This function takes a collection of score entries, converts them to CSV format
/// with headers "i,v" (id, value), saves the CSV data to a file, and computes a Keccak256 hash.
///
/// This is an alternative to `create_csv_and_hash_from_scores` when you want to save
/// the CSV data to disk instead of keeping it in memory.
///
/// # Arguments
/// * `scores` - An iterator over items that implement ScoreEntry-like interface (have id() and value() methods)
/// * `file_path` - The path where the CSV file should be saved
///
/// # Returns
/// * `Result<Vec<u8>, Error>` - The hash bytes or an error
///
/// # Usage Examples
///
/// ## Save scores to file for debugging/verification:
/// ```no_run
/// use openrank_common::tx::trust::ScoreEntry;
/// use openrank_node::create_csv_file_and_hash_from_scores;
///
/// let scores = vec![
///     ScoreEntry::new("alice".to_string(), 0.95),
///     ScoreEntry::new("bob".to_string(), 0.87),
/// ];
/// let hash = create_csv_file_and_hash_from_scores(scores, "./scores.csv").unwrap();
/// let hash_hex = alloy::hex::encode(hash);
/// ```
///
/// ## Use with create_csv_and_hash_from_scores for different workflows:
/// ```no_run
/// use openrank_common::tx::trust::ScoreEntry;
/// use openrank_node::{create_csv_and_hash_from_scores, create_csv_file_and_hash_from_scores};
///
/// let scores = vec![
///     ScoreEntry::new("alice".to_string(), 0.95),
///     ScoreEntry::new("bob".to_string(), 0.87),
/// ];
///
/// // For uploading to S3 (memory-efficient):
/// let (csv_bytes, hash1) = create_csv_and_hash_from_scores(scores.clone()).unwrap();
/// // upload csv_bytes to S3...
///
/// // For local debugging (saves to disk):
/// let hash2 = create_csv_file_and_hash_from_scores(scores, "./debug_scores.csv").unwrap();
///
/// // Both hashes should be identical
/// assert_eq!(hash1, hash2);
/// ```
pub fn create_csv_file_and_hash_from_scores<I>(scores: I, file_path: &str) -> Result<Vec<u8>, Error>
where
    I: IntoIterator<Item = openrank_common::tx::trust::ScoreEntry>,
{
    use sha3::{Digest, Keccak256};
    use std::fs::File;

    let file = File::create(file_path)
        .map_err(|e| Error::FileError(format!("Failed to create file {}: {}", file_path, e)))?;

    let mut wtr = csv::Writer::from_writer(file);
    wtr.write_record(&["i", "v"]).map_err(Error::CsvError)?;

    let mut csv_bytes = Vec::new();
    let mut temp_wtr = csv::Writer::from_writer(&mut csv_bytes);
    temp_wtr
        .write_record(&["i", "v"])
        .map_err(Error::CsvError)?;

    for score in scores {
        let id = score.id();
        let value_str = score.value().to_string();

        // Write to file
        wtr.write_record(&[id, &value_str])
            .map_err(Error::CsvError)?;

        // Write to temp buffer for hashing
        temp_wtr
            .write_record(&[id, &value_str])
            .map_err(Error::CsvError)?;
    }

    // Flush and close file writer
    wtr.flush()
        .map_err(|e| Error::FileError(format!("Failed to flush CSV writer: {}", e)))?;

    // Get bytes for hashing
    let csv_bytes = temp_wtr
        .into_inner()
        .map_err(|e| Error::FileError(format!("Failed to get CSV writer inner data: {}", e)))?;

    let mut hasher = Keccak256::new();
    hasher
        .write_all(&csv_bytes)
        .map_err(|e| Error::FileError(format!("Failed to write to hasher: {}", e)))?;
    let hash = hasher.finalize().to_vec();

    Ok(hash)
}

/// Downloads data from S3 and saves it to a file
///
/// This function downloads an object from S3 using the provided key and saves it to the specified file path.
///
/// # Arguments
/// * `s3_client` - The AWS S3 client
/// * `bucket_name` - The name of the S3 bucket
/// * `object_key` - The key/path of the object in S3
/// * `file_path` - The local file path where the data should be saved
///
/// # Returns
/// * `Result<(), Error>` - Ok if successful, Error otherwise
///
/// # Examples
/// ```no_run
/// use aws_config;
/// use aws_sdk_s3::Client;
/// use openrank_node::download_s3_object_to_file;
///
/// # async fn example() -> Result<(), Box<dyn std::error::Error>> {
/// let config = aws_config::from_env().region("us-west-2").load().await;
/// let s3_client = Client::new(&config);
/// download_s3_object_to_file(&s3_client, "my-bucket", "data/file.csv", "./local/file.csv").await?;
/// # Ok(())
/// # }
/// ```
pub async fn download_s3_object_to_file(
    s3_client: &S3Client,
    bucket_name: &str,
    object_key: &str,
    file_path: &str,
) -> Result<(), Error> {
    let mut file = File::create(file_path)
        .map_err(|e| Error::FileError(format!("Failed to create file {}: {}", file_path, e)))?;

    let mut response = s3_client
        .get_object()
        .bucket(bucket_name)
        .key(object_key)
        .send()
        .await
        .map_err(|e| Error::AwsError(e.into()))?;

    while let Some(bytes) = response.body.next().await {
        let chunk = bytes.map_err(Error::ByteStreamError)?;
        file.write_all(&chunk).map_err(|e| {
            Error::FileError(format!("Failed to write to file {}: {}", file_path, e))
        })?;
    }

    Ok(())
}

/// Downloads S3 object and returns the data as bytes
///
/// This function downloads an object from S3 and returns the data as a vector of bytes.
///
/// # Arguments
/// * `s3_client` - The AWS S3 client
/// * `bucket_name` - The name of the S3 bucket
/// * `object_key` - The key/path of the object in S3
///
/// # Returns
/// * `Result<Vec<u8>, Error>` - The downloaded data as bytes or an error
///
/// # Examples
/// ```no_run
/// use aws_config;
/// use aws_sdk_s3::Client;
/// use openrank_node::download_s3_object_as_bytes;
///
/// # async fn example() -> Result<(), Box<dyn std::error::Error>> {
/// let config = aws_config::from_env().region("us-west-2").load().await;
/// let s3_client = Client::new(&config);
/// let data = download_s3_object_as_bytes(&s3_client, "my-bucket", "data/file.csv").await?;
/// # Ok(())
/// # }
/// ```
pub async fn download_s3_object_as_bytes(
    s3_client: &S3Client,
    bucket_name: &str,
    object_key: &str,
) -> Result<Vec<u8>, Error> {
    let mut response = s3_client
        .get_object()
        .bucket(bucket_name)
        .key(object_key)
        .send()
        .await
        .map_err(|e| Error::AwsError(e.into()))?;

    let mut data = Vec::new();
    while let Some(bytes) = response.body.next().await {
        let chunk = bytes.map_err(Error::ByteStreamError)?;
        data.extend_from_slice(&chunk);
    }

    Ok(data)
}

/// Downloads CSV data from S3 and parses it into the specified type
///
/// This is a convenience function that combines S3 download with CSV parsing.
///
/// # Type Parameters
/// * `T` - The type to deserialize each CSV record into. Must implement `DeserializeOwned`.
///
/// # Arguments
/// * `s3_client` - The AWS S3 client
/// * `bucket_name` - The name of the S3 bucket
/// * `object_key` - The key/path of the CSV object in S3
///
/// # Returns
/// * `Result<Vec<T>, Error>` - Vector of parsed CSV records or an error
///
/// # Examples
/// ```no_run
/// use aws_config;
/// use aws_sdk_s3::Client;
/// use openrank_common::tx::trust::TrustEntry;
/// use openrank_node::download_and_parse_csv_from_s3;
///
/// # async fn example() -> Result<(), Box<dyn std::error::Error>> {
/// let config = aws_config::from_env().region("us-west-2").load().await;
/// let s3_client = Client::new(&config);
/// let trust_entries: Vec<TrustEntry> = download_and_parse_csv_from_s3(&s3_client, "my-bucket", "trust/data.csv").await?;
/// # Ok(())
/// # }
/// ```
pub async fn download_and_parse_csv_from_s3<T>(
    s3_client: &S3Client,
    bucket_name: &str,
    object_key: &str,
) -> Result<Vec<T>, Error>
where
    T: DeserializeOwned,
{
    let csv_data = download_s3_object_as_bytes(s3_client, bucket_name, object_key).await?;
    parse_csv_bytes(&csv_data)
}

/// Downloads trust entries from S3
///
/// This function downloads and parses trust CSV data from S3 into TrustEntry objects.
///
/// # Arguments
/// * `s3_client` - The AWS S3 client
/// * `bucket_name` - The name of the S3 bucket
/// * `trust_id` - The trust ID (used as part of the S3 key: "trust/{trust_id}")
///
/// # Returns
/// * `Result<Vec<TrustEntry>, Error>` - Vector of trust entries or an error
pub async fn download_trust_entries_from_s3(
    s3_client: &S3Client,
    bucket_name: &str,
    trust_id: &str,
) -> Result<Vec<openrank_common::tx::trust::TrustEntry>, Error> {
    let object_key = format!("trust/{}", trust_id);
    download_and_parse_csv_from_s3(s3_client, bucket_name, &object_key).await
}

/// Downloads score entries from S3
///
/// This function downloads and parses score/seed CSV data from S3 into ScoreEntry objects.
///
/// # Arguments
/// * `s3_client` - The AWS S3 client
/// * `bucket_name` - The name of the S3 bucket
/// * `object_type` - The type of score data ("seed" or "scores")
/// * `score_id` - The score/seed ID (used as part of the S3 key: "{object_type}/{score_id}")
///
/// # Returns
/// * `Result<Vec<ScoreEntry>, Error>` - Vector of score entries or an error
pub async fn download_score_entries_from_s3(
    s3_client: &S3Client,
    bucket_name: &str,
    object_type: &str, // "seed" or "scores"
    score_id: &str,
) -> Result<Vec<openrank_common::tx::trust::ScoreEntry>, Error> {
    let object_key = format!("{}/{}", object_type, score_id);
    download_and_parse_csv_from_s3(s3_client, bucket_name, &object_key).await
}

/// Downloads CSV data from S3 and saves it to a file, then parses it
///
/// This function downloads CSV data from S3, saves it to a local file, and then parses it.
/// Useful when you need both the file and the parsed data.
///
/// # Type Parameters
/// * `T` - The type to deserialize each CSV record into. Must implement `DeserializeOwned`.
///
/// # Arguments
/// * `s3_client` - The AWS S3 client
/// * `bucket_name` - The name of the S3 bucket
/// * `object_key` - The key/path of the CSV object in S3
/// * `file_path` - The local file path where the CSV should be saved
///
/// # Returns
/// * `Result<Vec<T>, Error>` - Vector of parsed CSV records or an error
pub async fn download_csv_from_s3_and_save<T>(
    s3_client: &S3Client,
    bucket_name: &str,
    object_key: &str,
    file_path: &str,
) -> Result<Vec<T>, Error>
where
    T: DeserializeOwned,
{
    // First download and save to file
    download_s3_object_to_file(s3_client, bucket_name, object_key, file_path).await?;

    // Then parse the saved file
    let file = File::open(file_path)
        .map_err(|e| Error::FileError(format!("Failed to open file {}: {}", file_path, e)))?;

    // Use our existing file parsing function
    let mut reader = csv::Reader::from_reader(file);
    let mut entries = Vec::new();

    for result in reader.records() {
        let record: csv::StringRecord = result.map_err(Error::CsvError)?;
        let entry: T = record.deserialize(None).map_err(Error::CsvError)?;
        entries.push(entry);
    }

    Ok(entries)
}

/// Uploads bytes to S3
///
/// This function uploads raw bytes to S3 with the specified key.
///
/// # Arguments
/// * `s3_client` - The AWS S3 client
/// * `bucket_name` - The name of the S3 bucket
/// * `object_key` - The key/path where the object should be stored in S3
/// * `data` - The raw bytes to upload
///
/// # Returns
/// * `Result<(), Error>` - Ok if successful, Error otherwise
///
/// # Examples
/// ```no_run
/// use aws_config;
/// use aws_sdk_s3::Client;
/// use openrank_node::upload_bytes_to_s3;
///
/// # async fn example() -> Result<(), Box<dyn std::error::Error>> {
/// let config = aws_config::from_env().region("us-west-2").load().await;
/// let s3_client = Client::new(&config);
/// let data = b"Hello, world!";
/// upload_bytes_to_s3(&s3_client, "my-bucket", "data/hello.txt", data).await?;
/// # Ok(())
/// # }
/// ```
pub async fn upload_bytes_to_s3(
    s3_client: &S3Client,
    bucket_name: &str,
    object_key: &str,
    data: &[u8],
) -> Result<(), Error> {
    use aws_sdk_s3::primitives::ByteStream;

    let body = ByteStream::from(data.to_vec());

    s3_client
        .put_object()
        .bucket(bucket_name)
        .key(object_key)
        .body(body)
        .send()
        .await
        .map_err(|e| Error::AwsError(e.into()))?;

    Ok(())
}

/// Uploads a file to S3
///
/// This function reads a local file and uploads it to S3.
///
/// # Arguments
/// * `s3_client` - The AWS S3 client
/// * `bucket_name` - The name of the S3 bucket
/// * `object_key` - The key/path where the object should be stored in S3
/// * `file_path` - The local file path to upload
///
/// # Returns
/// * `Result<(), Error>` - Ok if successful, Error otherwise
///
/// # Examples
/// ```no_run
/// use aws_config;
/// use aws_sdk_s3::Client;
/// use openrank_node::upload_file_to_s3;
///
/// # async fn example() -> Result<(), Box<dyn std::error::Error>> {
/// let config = aws_config::from_env().region("us-west-2").load().await;
/// let s3_client = Client::new(&config);
/// upload_file_to_s3(&s3_client, "my-bucket", "data/document.pdf", "./local/document.pdf").await?;
/// # Ok(())
/// # }
/// ```
pub async fn upload_file_to_s3(
    s3_client: &S3Client,
    bucket_name: &str,
    object_key: &str,
    file_path: &str,
) -> Result<(), Error> {
    use std::io::Read;

    let mut file = File::open(file_path)
        .map_err(|e| Error::FileError(format!("Failed to open file {}: {}", file_path, e)))?;

    let mut buffer = Vec::new();
    file.read_to_end(&mut buffer)
        .map_err(|e| Error::FileError(format!("Failed to read file {}: {}", file_path, e)))?;

    upload_bytes_to_s3(s3_client, bucket_name, object_key, &buffer).await
}

/// Uploads a file to S3 using streaming to avoid loading entire file in memory
///
/// This function reads a local file as a stream and uploads it to S3 without
/// loading the entire file into memory, making it more memory-efficient for large files.
///
/// # Arguments
///
/// * `s3_client` - The S3 client
/// * `bucket_name` - The name of the S3 bucket
/// * `object_key` - The key (path) for the object in S3
/// * `file_path` - The path to the local file to upload
///
/// # Returns
///
/// * `Result<(), Error>` - Ok(()) if successful, Error if failed
///
/// # Examples
///
/// ```no_run
/// # use aws_sdk_s3::Client as S3Client;
/// # use openrank_node::Error;
/// # async fn example() -> Result<(), Error> {
/// # let s3_client = S3Client::new(&aws_config::load_from_env().await);
/// # let bucket_name = "my-bucket";
/// use openrank_node::upload_file_to_s3_streaming;
///
/// // Upload a large CSV file without loading it entirely into memory
/// upload_file_to_s3_streaming(&s3_client, bucket_name, "scores/large_file.csv", "./scores/large_file.csv").await?;
/// # Ok(())
/// # }
/// ```
pub async fn upload_file_to_s3_streaming(
    s3_client: &S3Client,
    bucket_name: &str,
    object_key: &str,
    file_path: &str,
) -> Result<(), Error> {
    use aws_sdk_s3::primitives::ByteStream;
    use tokio::fs::File;

    // Open the file asynchronously
    let file = File::open(file_path)
        .await
        .map_err(|e| Error::FileError(format!("Failed to open file {}: {}", file_path, e)))?;

    // Create a ByteStream from the file
    let body = ByteStream::read_from()
        .file(file)
        .build()
        .await
        .map_err(|e| {
            Error::FileError(format!(
                "Failed to create stream from file {}: {}",
                file_path, e
            ))
        })?;

    // Upload using the streaming body
    s3_client
        .put_object()
        .bucket(bucket_name)
        .key(object_key)
        .body(body)
        .send()
        .await
        .map_err(|e| Error::AwsError(e.into()))?;

    Ok(())
}

/// Checks if an object exists in S3
///
/// This function checks whether an object exists in S3 without downloading it.
///
/// # Arguments
/// * `s3_client` - The AWS S3 client
/// * `bucket_name` - The name of the S3 bucket
/// * `object_key` - The key/path of the object to check
///
/// # Returns
/// * `Result<bool, Error>` - true if the object exists, false otherwise, or an error
///
/// # Examples
/// ```no_run
/// use aws_config;
/// use aws_sdk_s3::Client;
/// use openrank_node::s3_object_exists;
///
/// # async fn example() -> Result<(), Box<dyn std::error::Error>> {
/// let config = aws_config::from_env().region("us-west-2").load().await;
/// let s3_client = Client::new(&config);
/// let exists = s3_object_exists(&s3_client, "my-bucket", "data/file.csv").await?;
/// # Ok(())
/// # }
/// ```
pub async fn s3_object_exists(
    s3_client: &S3Client,
    bucket_name: &str,
    object_key: &str,
) -> Result<bool, Error> {
    match s3_client
        .head_object()
        .bucket(bucket_name)
        .key(object_key)
        .send()
        .await
    {
        Ok(_) => Ok(true),
        Err(err) => {
            // Check if it's a "not found" error
            let aws_err: aws_sdk_s3::Error = err.into();
            if let aws_sdk_s3::Error::NoSuchKey(_) = aws_err {
                Ok(false)
            } else {
                Err(Error::AwsError(aws_err))
            }
        }
    }
}

/// Downloads trust data from S3 and saves to file
///
/// This function downloads trust CSV data from S3 and saves it to a local file.
/// It follows the pattern used in the codebase where trust data is stored with "trust/{id}" keys.
///
/// # Arguments
/// * `s3_client` - The AWS S3 client
/// * `bucket_name` - The name of the S3 bucket
/// * `trust_id` - The trust ID (used as part of the S3 key: "trust/{trust_id}")
/// * `file_path` - The local file path where the trust data should be saved
///
/// # Returns
/// * `Result<(), Error>` - Ok if successful, Error otherwise
pub async fn download_trust_data_to_file(
    s3_client: &S3Client,
    bucket_name: &str,
    trust_id: &str,
    file_path: &str,
) -> Result<(), Error> {
    let object_key = format!("trust/{}", trust_id);
    download_s3_object_to_file(s3_client, bucket_name, &object_key, file_path).await
}

/// Downloads seed data from S3 and saves to file
///
/// This function downloads seed CSV data from S3 and saves it to a local file.
/// It follows the pattern used in the codebase where seed data is stored with "seed/{id}" keys.
///
/// # Arguments
/// * `s3_client` - The AWS S3 client
/// * `bucket_name` - The name of the S3 bucket
/// * `seed_id` - The seed ID (used as part of the S3 key: "seed/{seed_id}")
/// * `file_path` - The local file path where the seed data should be saved
///
/// # Returns
/// * `Result<(), Error>` - Ok if successful, Error otherwise
pub async fn download_seed_data_to_file(
    s3_client: &S3Client,
    bucket_name: &str,
    seed_id: &str,
    file_path: &str,
) -> Result<(), Error> {
    let object_key = format!("seed/{}", seed_id);
    download_s3_object_to_file(s3_client, bucket_name, &object_key, file_path).await
}

/// Downloads scores data from S3 and saves to file
///
/// This function downloads scores CSV data from S3 and saves it to a local file.
/// It follows the pattern used in the codebase where scores data is stored with "scores/{id}" keys.
///
/// # Arguments
/// * `s3_client` - The AWS S3 client
/// * `bucket_name` - The name of the S3 bucket
/// * `scores_id` - The scores ID (used as part of the S3 key: "scores/{scores_id}")
/// * `file_path` - The local file path where the scores data should be saved
///
/// # Returns
/// * `Result<(), Error>` - Ok if successful, Error otherwise
pub async fn download_scores_data_to_file(
    s3_client: &S3Client,
    bucket_name: &str,
    scores_id: &str,
    file_path: &str,
) -> Result<(), Error> {
    let object_key = format!("scores/{}", scores_id);
    download_s3_object_to_file(s3_client, bucket_name, &object_key, file_path).await
}

/// Downloads JSON metadata from S3 and parses it into the specified type
///
/// This function downloads JSON metadata from S3 and deserializes it into the specified type.
/// It follows the pattern used in the codebase where metadata is stored with "meta/{id}" keys.
///
/// # Type Parameters
/// * `T` - The type to deserialize the JSON into. Must implement `DeserializeOwned`.
///
/// # Arguments
/// * `s3_client` - The AWS S3 client
/// * `bucket_name` - The name of the S3 bucket
/// * `meta_id` - The metadata ID (used as part of the S3 key: "meta/{meta_id}")
///
/// # Returns
/// * `Result<T, Error>` - The deserialized metadata object or an error
///
/// # Examples
/// ```no_run
/// use aws_config;
/// use aws_sdk_s3::Client;
/// use openrank_node::download_json_metadata_from_s3;
/// use serde::Deserialize;
///
/// #[derive(Deserialize)]
/// struct MyMetadata {
///     name: String,
///     value: i32,
/// }
///
/// # async fn example() -> Result<(), Box<dyn std::error::Error>> {
/// let config = aws_config::from_env().region("us-west-2").load().await;
/// let s3_client = Client::new(&config);
/// let metadata: MyMetadata = download_json_metadata_from_s3(&s3_client, "my-bucket", "abc123").await?;
/// # Ok(())
/// # }
/// ```
pub async fn download_json_metadata_from_s3<T>(
    s3_client: &S3Client,
    bucket_name: &str,
    meta_id: &str,
) -> Result<T, Error>
where
    T: DeserializeOwned,
{
    let object_key = format!("meta/{}", meta_id);
    let mut response = s3_client
        .get_object()
        .bucket(bucket_name)
        .key(&object_key)
        .send()
        .await
        .map_err(|e| Error::AwsError(e.into()))?;

    let mut data = Vec::new();
    while let Some(bytes) = response.body.next().await {
        let chunk = bytes.map_err(Error::ByteStreamError)?;
        data.extend_from_slice(&chunk);
    }

    let metadata: T = serde_json::from_slice(&data).map_err(Error::SerdeError)?;
    Ok(metadata)
}

/// # S3 Helper Functions Usage Examples
///
/// The S3 helper functions provide a comprehensive set of utilities for downloading, uploading,
/// and managing CSV and JSON data in S3. Here are practical examples of how to use them:
///
/// ## Example 1: Download and Parse Trust Data
/// ```no_run
/// use aws_config::from_env;
/// use aws_sdk_s3::Client;
/// use openrank_node::{download_trust_entries_from_s3, download_trust_data_to_file};
///
/// async fn example_download_trust_data() -> Result<(), Box<dyn std::error::Error>> {
///     let config = from_env().region("us-west-2").load().await;
///     let s3_client = Client::new(&config);
///     let bucket_name = "openrank-data";
///     let trust_id = "abc123";
///
///     // Option 1: Download and parse directly into TrustEntry objects
///     let trust_entries = download_trust_entries_from_s3(&s3_client, bucket_name, trust_id).await?;
///     println!("Downloaded {} trust entries", trust_entries.len());
///
///     // Option 2: Download to file for later processing
///     download_trust_data_to_file(&s3_client, bucket_name, trust_id, "./trust_data.csv").await?;
///     println!("Trust data saved to ./trust_data.csv");
///
///     Ok(())
/// }
/// ```
///
/// ## Example 2: Download Multiple Data Types
/// ```no_run
/// use aws_config::from_env;
/// use aws_sdk_s3::Client;
/// use openrank_node::{download_trust_entries_from_s3, download_score_entries_from_s3};
///
/// async fn example_download_compute_data() -> Result<(), Box<dyn std::error::Error>> {
///     let config = from_env().region("us-west-2").load().await;
///     let s3_client = Client::new(&config);
///     let bucket_name = "openrank-data";
///
///     // Download trust, seed, and scores data in parallel
///     let (trust_entries, seed_entries, scores_entries) = tokio::try_join!(
///         download_trust_entries_from_s3(&s3_client, bucket_name, "trust_123"),
///         download_score_entries_from_s3(&s3_client, bucket_name, "seed", "seed_123"),
///         download_score_entries_from_s3(&s3_client, bucket_name, "scores", "scores_123")
///     )?;
///
///     println!("Downloaded {} trust, {} seed, {} score entries",
///              trust_entries.len(), seed_entries.len(), scores_entries.len());
///
///     Ok(())
/// }
/// ```
///
/// ## Example 3: Upload and Verify Data
/// ```no_run
/// use aws_config::from_env;
/// use aws_sdk_s3::Client;
/// use openrank_node::{upload_file_to_s3, s3_object_exists, download_and_parse_csv_from_s3};
///
/// async fn example_upload_and_verify() -> Result<(), Box<dyn std::error::Error>> {
///     let config = from_env().region("us-west-2").load().await;
///     let s3_client = Client::new(&config);
///     let bucket_name = "openrank-data";
///
///     // Upload a CSV file
///     upload_file_to_s3(&s3_client, bucket_name, "trust/new_data", "./local_trust.csv").await?;
///
///     // Verify the upload was successful
///     let exists = s3_object_exists(&s3_client, bucket_name, "trust/new_data").await?;
///     assert!(exists, "Upload verification failed");
///
///     // Download and parse to verify data integrity
///     let entries: Vec<(String, String, f32)> = download_and_parse_csv_from_s3(
///         &s3_client, bucket_name, "trust/new_data"
///     ).await?;
///     println!("Verified {} entries after upload", entries.len());
///
///     Ok(())
/// }
/// ```
///
/// ## Example 4: Replace Existing Patterns
/// This shows how the new functions can replace existing code patterns in the codebase:
///
/// ```text
/// OLD PATTERN (from challenger.rs and computer.rs):
/// let mut trust_res = s3_client
///     .get_object()
///     .bucket(bucket_name)
///     .key(format!("trust/{}", trust_id))
///     .send()
///     .await
///     .map_err(|e| NodeError::AwsError(e.into()))?;
///
/// let mut trust_file = File::create(format!("./trust/{}", trust_id))
///     .map_err(|e| NodeError::FileError(format!("Failed to create file: {e:}")))?;
///
/// while let Some(bytes) = trust_res.body.next().await {
///     trust_file
///         .write(&bytes.unwrap())
///         .map_err(|e| NodeError::FileError(format!("Failed to write to file: {e:}")))?;
/// }
///
/// NEW PATTERN:
/// download_trust_data_to_file(&s3_client, bucket_name, &trust_id, &format!("./trust/{}", trust_id)).await?;
/// ```
pub struct S3UsageExamples;

/// Parses CSV bytes into a vector of the specified type.
///
/// This function accepts CSV file bytes and returns a vector of values
/// with the provided type. It's designed to replace repetitive CSV parsing
/// functionality found in rxp.rs and other similar use-cases.
///
/// By default, the CSV reader treats the first line as headers. Use
/// `parse_csv_bytes_no_headers` if your CSV data doesn't have headers.
///
/// # Type Parameters
/// * `T` - The type to deserialize each CSV record into. Must implement `DeserializeOwned`.
///
/// # Arguments
/// * `csv_bytes` - Raw bytes of the CSV file to parse
///
/// # Returns
/// * `Result<Vec<T>, Error>` - Vector of parsed values or an error
///
/// # Examples
/// ```
/// use openrank_common::tx::trust::{TrustEntry, ScoreEntry};
/// use openrank_node::parse_csv_bytes;
///
/// // Parse trust entries (with headers)
/// let trust_csv = b"from,to,value\nalice,bob,0.8\nbob,charlie,0.9";
/// let trust_entries: Vec<TrustEntry> = parse_csv_bytes(trust_csv).unwrap();
///
/// // Parse score entries (with headers)
/// let score_csv = b"id,value\nalice,0.95\nbob,0.87";
/// let score_entries: Vec<ScoreEntry> = parse_csv_bytes(score_csv).unwrap();
/// ```
pub fn parse_csv_bytes<T>(csv_bytes: &[u8]) -> Result<Vec<T>, Error>
where
    T: DeserializeOwned,
{
    let mut reader = csv::Reader::from_reader(csv_bytes);
    let mut entries = Vec::new();

    for result in reader.records() {
        let record: StringRecord = result.map_err(Error::CsvError)?;
        let entry: T = record.deserialize(None).map_err(Error::CsvError)?;
        entries.push(entry);
    }

    Ok(entries)
}

/// Parses CSV bytes into a vector of the specified type, treating all rows as data (no headers).
///
/// This function is useful when your CSV data doesn't have headers and you want to parse
/// all rows as data records.
///
/// # Type Parameters
/// * `T` - The type to deserialize each CSV record into. Must implement `DeserializeOwned`.
///
/// # Arguments
/// * `csv_bytes` - Raw bytes of the CSV file to parse
///
/// # Returns
/// * `Result<Vec<T>, Error>` - Vector of parsed values or an error
///
/// # Examples
/// ```
/// use openrank_node::parse_csv_bytes_no_headers;
///
/// let csv_data = b"alice,bob,0.8\nbob,charlie,0.9";
/// let tuples: Vec<(String, String, f32)> = parse_csv_bytes_no_headers(csv_data).unwrap();
/// ```
pub fn parse_csv_bytes_no_headers<T>(csv_bytes: &[u8]) -> Result<Vec<T>, Error>
where
    T: DeserializeOwned,
{
    let mut reader = csv::ReaderBuilder::new()
        .has_headers(false)
        .from_reader(csv_bytes);
    let mut entries = Vec::new();

    for result in reader.records() {
        let record: StringRecord = result.map_err(Error::CsvError)?;
        let entry: T = record.deserialize(None).map_err(Error::CsvError)?;
        entries.push(entry);
    }

    Ok(entries)
}

/// Parses CSV bytes into a vector of tuples for simple cases.
///
/// This is a convenience function for parsing CSV data into simple tuple types
/// when you don't need a full struct representation.
///
/// # Type Parameters
/// * `T` - The tuple type to deserialize each CSV record into. Must implement `DeserializeOwned`.
///
/// # Arguments
/// * `csv_bytes` - Raw bytes of the CSV file to parse
///
/// # Returns
/// * `Result<Vec<T>, Error>` - Vector of parsed tuples or an error
///
/// # Examples
/// ```
/// use openrank_node::parse_csv_tuples;
///
/// // Parse into (String, String, f32) tuples
/// let csv_data = b"alice,bob,0.8\nbob,charlie,0.9";
/// let tuples: Vec<(String, String, f32)> = parse_csv_tuples(csv_data).unwrap();
/// ```
pub fn parse_csv_tuples<T>(csv_bytes: &[u8]) -> Result<Vec<T>, Error>
where
    T: DeserializeOwned,
{
    parse_csv_bytes(csv_bytes)
}

/// Helper functions for specific common types used in the codebase

/// Parses CSV bytes into TrustEntry vectors
///
/// This is a convenience wrapper around `parse_csv_bytes` specifically for TrustEntry.
/// Expects CSV format: from,to,value
pub fn parse_trust_entries(
    csv_bytes: &[u8],
) -> Result<Vec<openrank_common::tx::trust::TrustEntry>, Error> {
    parse_csv_bytes(csv_bytes)
}

/// Parses CSV bytes into ScoreEntry vectors
///
/// This is a convenience wrapper around `parse_csv_bytes` specifically for ScoreEntry.
/// Expects CSV format: id,value
pub fn parse_score_entries(
    csv_bytes: &[u8],
) -> Result<Vec<openrank_common::tx::trust::ScoreEntry>, Error> {
    parse_csv_bytes(csv_bytes)
}

/// Parses CSV bytes into TrustEntry vectors from tuple format (matching rxp.rs pattern)
///
/// This function directly replaces the rxp.rs pattern of parsing CSV into tuples
/// and then creating TrustEntry objects. It handles the conversion internally.
pub fn parse_trust_entries_from_tuples(
    csv_bytes: &[u8],
) -> Result<Vec<openrank_common::tx::trust::TrustEntry>, Error> {
    let tuples: Vec<(String, String, f32)> = parse_csv_bytes(csv_bytes)?;
    let entries = tuples
        .into_iter()
        .map(|(from, to, value)| openrank_common::tx::trust::TrustEntry::new(from, to, value))
        .collect();
    Ok(entries)
}

/// Parses CSV bytes into ScoreEntry vectors from tuple format (matching rxp.rs pattern)
///
/// This function directly replaces the rxp.rs pattern of parsing CSV into tuples
/// and then creating ScoreEntry objects. It handles the conversion internally.
pub fn parse_score_entries_from_tuples(
    csv_bytes: &[u8],
) -> Result<Vec<openrank_common::tx::trust::ScoreEntry>, Error> {
    let tuples: Vec<(String, f32)> = parse_csv_bytes(csv_bytes)?;
    let entries = tuples
        .into_iter()
        .map(|(id, value)| openrank_common::tx::trust::ScoreEntry::new(id, value))
        .collect();
    Ok(entries)
}

/// Example usage demonstrating how to replace rxp.rs functionality:
///
/// ```rust
/// // Old way (from rxp.rs):
/// // let mut trust_rdr = csv::Reader::from_reader(meta_result.trust_data.as_slice());
/// // let mut trust_entries = Vec::new();
/// // for result in trust_rdr.records() {
/// //     let record: StringRecord = result.map_err(NodeError::CsvError)?;
/// //     let (from, to, value): (String, String, f32) =
/// //         record.deserialize(None).map_err(NodeError::CsvError)?;
/// //     let trust_entry = TrustEntry::new(from, to, value);
/// //     trust_entries.push(trust_entry);
/// // }
///
/// // New way (direct replacement):
/// // let trust_entries = parse_trust_entries_from_tuples(&meta_result.trust_data)?;
///
/// // Similarly for scores:
/// // Old way:
/// // let mut scores_rdr = csv::Reader::from_reader(meta_result.scores_data.as_slice());
/// // let mut scores_entries = Vec::new();
/// // for result in scores_rdr.records() {
/// //     let record: StringRecord = result.map_err(NodeError::CsvError)?;
/// //     let (id, value): (String, f32) = record.deserialize(None).map_err(NodeError::CsvError)?;
/// //     let score_entry = ScoreEntry::new(id, value);
/// //     scores_entries.push(score_entry);
/// // }
///
/// // New way (direct replacement):
/// // let scores_entries = parse_score_entries_from_tuples(&meta_result.scores_data)?;
/// ```
///
/// Parses CSV data from a File handle into TrustEntry vectors
///
/// This function reads CSV data from a file and parses it into TrustEntry objects.
/// Useful for reading trust data from files on disk.
pub fn parse_trust_entries_from_file(
    file: std::fs::File,
) -> Result<Vec<openrank_common::tx::trust::TrustEntry>, Error> {
    let mut reader = csv::Reader::from_reader(file);
    let mut entries = Vec::new();

    for result in reader.records() {
        let record: csv::StringRecord = result.map_err(Error::CsvError)?;
        let (from, to, value): (String, String, f32) =
            record.deserialize(None).map_err(Error::CsvError)?;
        let trust_entry = openrank_common::tx::trust::TrustEntry::new(from, to, value);
        entries.push(trust_entry);
    }

    Ok(entries)
}

/// Parses CSV data from a File handle into ScoreEntry vectors
///
/// This function reads CSV data from a file and parses it into ScoreEntry objects.
/// Useful for reading seed or score data from files on disk.
pub fn parse_score_entries_from_file(
    file: std::fs::File,
) -> Result<Vec<openrank_common::tx::trust::ScoreEntry>, Error> {
    let mut reader = csv::Reader::from_reader(file);
    let mut entries = Vec::new();

    for result in reader.records() {
        let record: csv::StringRecord = result.map_err(Error::CsvError)?;
        let (id, value): (String, f32) = record.deserialize(None).map_err(Error::CsvError)?;
        let score_entry = openrank_common::tx::trust::ScoreEntry::new(id, value);
        entries.push(score_entry);
    }

    Ok(entries)
}

/// Validates CSV format for trust entries without parsing into objects
///
/// This function checks if the CSV data contains valid trust entries with the correct format.
/// Useful for validation before uploading or processing.
pub fn validate_trust_csv(csv_bytes: &[u8]) -> Result<(), Error> {
    let _tuples: Vec<(String, String, f32)> = parse_csv_bytes(csv_bytes)?;
    // If parsing succeeds, the format is valid
    Ok(())
}

/// Validates CSV format for trust entries from a file without parsing into objects
///
/// This function checks if the CSV file contains valid trust entries with the correct format.
/// Useful for validation before uploading or processing.
pub fn validate_trust_csv_file(file: std::fs::File) -> Result<(), Error> {
    let mut reader = csv::Reader::from_reader(file);

    for result in reader.records() {
        let record: csv::StringRecord = result.map_err(Error::CsvError)?;
        let _: (String, String, f32) = record.deserialize(None).map_err(Error::CsvError)?;
    }

    Ok(())
}

/// Validates CSV format for score entries without parsing into objects
///
/// This function checks if the CSV data contains valid score entries with the correct format.
/// Useful for validation before uploading or processing.
pub fn validate_score_csv(csv_bytes: &[u8]) -> Result<(), Error> {
    let _tuples: Vec<(String, f32)> = parse_csv_bytes(csv_bytes)?;
    // If parsing succeeds, the format is valid
    Ok(())
}

/// Validates CSV format for score entries from a file without parsing into objects
///
/// This function checks if the CSV file contains valid score entries with the correct format.
/// Useful for validation before uploading or processing.
pub fn validate_score_csv_file(file: std::fs::File) -> Result<(), Error> {
    let mut reader = csv::Reader::from_reader(file);

    for result in reader.records() {
        let record: csv::StringRecord = result.map_err(Error::CsvError)?;
        let _: (String, f32) = record.deserialize(None).map_err(Error::CsvError)?;
    }

    Ok(())
}

/// # Migration Guide
///
/// The functions in this module are designed to replace the repetitive CSV parsing
/// functionality found in rxp.rs and other similar use-cases throughout the codebase.
pub struct CsvParsingExamples;

#[cfg(test)]
mod tests {
    use super::*;
    use openrank_common::tx::trust::{ScoreEntry, TrustEntry};

    #[test]
    fn test_parse_csv_tuples() {
        let csv_data = b"alice,bob,0.8\nbob,charlie,0.9";
        let tuples: Vec<(String, String, f32)> = parse_csv_tuples(csv_data).unwrap();

        // CSV reader treats first line as header by default, so we only get 1 record
        assert_eq!(tuples.len(), 1);
        assert_eq!(tuples[0], ("bob".to_string(), "charlie".to_string(), 0.9));
    }

    #[test]
    fn test_parse_csv_with_headers() {
        let csv_data = b"from,to,value\nalice,bob,0.8\nbob,charlie,0.9";
        let tuples: Vec<(String, String, f32)> = parse_csv_tuples(csv_data).unwrap();

        assert_eq!(tuples.len(), 2);
        assert_eq!(tuples[0], ("alice".to_string(), "bob".to_string(), 0.8));
        assert_eq!(tuples[1], ("bob".to_string(), "charlie".to_string(), 0.9));
    }

    #[test]
    fn test_parse_score_tuples() {
        let csv_data = b"id,value\nalice,0.95\nbob,0.87";
        let tuples: Vec<(String, f32)> = parse_csv_tuples(csv_data).unwrap();

        assert_eq!(tuples.len(), 2);
        assert_eq!(tuples[0], ("alice".to_string(), 0.95));
        assert_eq!(tuples[1], ("bob".to_string(), 0.87));
    }

    #[test]
    fn test_empty_csv() {
        let csv_data = b"";
        let tuples: Vec<(String, String, f32)> = parse_csv_tuples(csv_data).unwrap();
        assert_eq!(tuples.len(), 0);
    }

    #[test]
    fn test_headers_only() {
        let csv_data = b"from,to,value";
        let tuples: Vec<(String, String, f32)> = parse_csv_tuples(csv_data).unwrap();
        assert_eq!(tuples.len(), 0);
    }

    #[test]
    fn test_malformed_csv() {
        let csv_data = b"alice,bob\nbob,charlie,0.9,extra";
        let result: Result<Vec<(String, String, f32)>, _> = parse_csv_tuples(csv_data);
        assert!(result.is_err());
    }

    #[test]
    fn test_convert_tuples_to_trust_entries() {
        let csv_data = b"from,to,value\nalice,bob,0.8\nbob,charlie,0.9";
        let tuples: Vec<(String, String, f32)> = parse_csv_tuples(csv_data).unwrap();

        let trust_entries: Vec<TrustEntry> = tuples
            .into_iter()
            .map(|(from, to, value)| TrustEntry::new(from, to, value))
            .collect();

        assert_eq!(trust_entries.len(), 2);
        assert_eq!(*trust_entries[0].from(), "alice");
        assert_eq!(*trust_entries[0].to(), "bob");
        assert_eq!(*trust_entries[0].value(), 0.8);
    }

    #[test]
    fn test_parse_csv_no_headers() {
        let csv_data = b"alice,bob,0.8\nbob,charlie,0.9";
        let tuples: Vec<(String, String, f32)> = parse_csv_bytes_no_headers(csv_data).unwrap();

        assert_eq!(tuples.len(), 2);
        assert_eq!(tuples[0], ("alice".to_string(), "bob".to_string(), 0.8));
        assert_eq!(tuples[1], ("bob".to_string(), "charlie".to_string(), 0.9));
    }

    #[test]
    fn test_convert_tuples_to_score_entries() {
        let csv_data = b"id,value\nalice,0.95\nbob,0.87";
        let tuples: Vec<(String, f32)> = parse_csv_tuples(csv_data).unwrap();

        let score_entries: Vec<ScoreEntry> = tuples
            .into_iter()
            .map(|(id, value)| ScoreEntry::new(id, value))
            .collect();

        assert_eq!(score_entries.len(), 2);
        assert_eq!(*score_entries[0].id(), "alice");
        assert_eq!(*score_entries[0].value(), 0.95);
    }

    #[test]
    fn test_parse_trust_entries_from_tuples() {
        let csv_data = b"from,to,value\nalice,bob,0.8\nbob,charlie,0.9";
        let trust_entries = parse_trust_entries_from_tuples(csv_data).unwrap();

        assert_eq!(trust_entries.len(), 2);
        assert_eq!(*trust_entries[0].from(), "alice");
        assert_eq!(*trust_entries[0].to(), "bob");
        assert_eq!(*trust_entries[0].value(), 0.8);
        assert_eq!(*trust_entries[1].from(), "bob");
        assert_eq!(*trust_entries[1].to(), "charlie");
        assert_eq!(*trust_entries[1].value(), 0.9);
    }

    #[test]
    fn test_parse_score_entries_from_tuples() {
        let csv_data = b"id,value\nalice,0.95\nbob,0.87";
        let score_entries = parse_score_entries_from_tuples(csv_data).unwrap();

        assert_eq!(score_entries.len(), 2);
        assert_eq!(*score_entries[0].id(), "alice");
        assert_eq!(*score_entries[0].value(), 0.95);
        assert_eq!(*score_entries[1].id(), "bob");
        assert_eq!(*score_entries[1].value(), 0.87);
    }

    #[test]
    fn test_validate_trust_csv() {
        let csv_data = b"from,to,value\nalice,bob,0.8\nbob,charlie,0.9";
        assert!(validate_trust_csv(csv_data).is_ok());

        let invalid_csv = b"from,to\nalice,bob\nbob,charlie";
        assert!(validate_trust_csv(invalid_csv).is_err());
    }

    #[test]
    fn test_validate_score_csv() {
        let csv_data = b"id,value\nalice,0.95\nbob,0.87";
        assert!(validate_score_csv(csv_data).is_ok());

        let invalid_csv = b"id\nalice\nbob";
        assert!(validate_score_csv(invalid_csv).is_err());
    }

    #[test]
    fn test_create_csv_and_hash_from_scores() {
        let scores = vec![
            ScoreEntry::new("alice".to_string(), 0.95),
            ScoreEntry::new("bob".to_string(), 0.87),
        ];

        let result = create_csv_and_hash_from_scores(scores);
        assert!(result.is_ok());

        let (csv_data, hash) = result.unwrap();

        // Check that CSV data is not empty
        assert!(!csv_data.is_empty());

        // Check that hash is 32 bytes (Keccak256)
        assert_eq!(hash.len(), 32);

        // Check that CSV contains expected content
        let csv_string = String::from_utf8(csv_data).unwrap();
        assert!(csv_string.contains("i,v"));
        assert!(csv_string.contains("alice,0.95"));
        assert!(csv_string.contains("bob,0.87"));

        // Hash should be deterministic
        let scores2 = vec![
            ScoreEntry::new("alice".to_string(), 0.95),
            ScoreEntry::new("bob".to_string(), 0.87),
        ];
        let (_, hash2) = create_csv_and_hash_from_scores(scores2).unwrap();
        assert_eq!(hash, hash2);
    }

    #[test]
    fn test_create_csv_file_and_hash_from_scores() {
        use std::fs;
        use std::path::Path;

        let scores = vec![
            ScoreEntry::new("alice".to_string(), 0.95),
            ScoreEntry::new("bob".to_string(), 0.87),
        ];

        let file_path = "./test_scores.csv";

        // Clean up any existing test file
        if Path::new(file_path).exists() {
            fs::remove_file(file_path).ok();
        }

        let result = create_csv_file_and_hash_from_scores(scores, file_path);
        assert!(result.is_ok());

        let hash = result.unwrap();

        // Check that hash is 32 bytes (Keccak256)
        assert_eq!(hash.len(), 32);

        // Check that file was created and contains expected content
        assert!(Path::new(file_path).exists());
        let file_content = fs::read_to_string(file_path).unwrap();
        assert!(file_content.contains("i,v"));
        assert!(file_content.contains("alice,0.95"));
        assert!(file_content.contains("bob,0.87"));

        // Hash should be deterministic - test with same data
        let scores2 = vec![
            ScoreEntry::new("alice".to_string(), 0.95),
            ScoreEntry::new("bob".to_string(), 0.87),
        ];
        let file_path2 = "./test_scores2.csv";
        let hash2 = create_csv_file_and_hash_from_scores(scores2, file_path2).unwrap();
        assert_eq!(hash, hash2);

        // Clean up test files
        fs::remove_file(file_path).ok();
        fs::remove_file(file_path2).ok();
    }
}
