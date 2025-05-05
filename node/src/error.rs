use alloy::{hex::FromHexError, signers::local::LocalSignerError, transports::TransportError};
use aws_sdk_s3::{primitives::ByteStreamError, Error as AwsError};
use csv::Error as CsvError;
use openrank_common::runners::compute_runner::Error as ComputeRunnerError;
use openrank_common::runners::verification_runner::Error as VerificationRunnerError;
use serde_json::Error as SerdeError;

#[derive(thiserror::Error, Debug)]
pub enum Error {
    #[error("LocalSignerError: {0}")]
    LocalSignerError(LocalSignerError),
    #[error("TransportError: {0}")]
    TransportError(TransportError),
    #[error("Hex error: {0}")]
    HexError(FromHexError),
    #[error("Serde error: {0}")]
    SerdeError(SerdeError),
    #[error("Aws error: {0}")]
    AwsError(AwsError),
    #[error("File error: {0}")]
    FileError(String),
    #[error("Csv error: {0}")]
    CsvError(CsvError),
    #[error("ComputeRunnerError: {0}")]
    ComputeRunnerError(ComputeRunnerError),
    #[error("VerificationRunnerError: {0}")]
    VerificationRunnerError(VerificationRunnerError),
    #[error("Tx Error: {0}")]
    TxError(String),
    #[error("ByteStreamError: {0}")]
    ByteStreamError(ByteStreamError),
}
