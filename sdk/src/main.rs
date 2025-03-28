use aws_config::{load_defaults, BehaviorVersion};
use aws_sdk_s3::primitives::ByteStream;
use aws_sdk_s3::{Client, Error as AwsError};
use clap::{Parser, Subcommand};
use dotenv::dotenv;

const BUCKET_NAME: &str = "openrank-data";

#[derive(Debug, Clone, Subcommand)]
/// The method to call.
enum Method {
    UploadTrust { path: String },
    UploadSeed { path: String },
}

#[derive(Parser, Debug)]
#[command(version, about, long_about = None)]
struct Args {
    #[command(subcommand)]
    method: Method,
}

async fn upload_local_trust() {}

#[tokio::main]
async fn main() -> Result<(), AwsError> {
    dotenv().ok();
    let cli = Args::parse();

    let config = load_defaults(BehaviorVersion::latest()).await;
    let client = Client::new(&config);

    match cli.method {
        Method::UploadTrust { path } => {
            let body = ByteStream::from_path(std::path::Path::new(&path)).await;
            let res = client
                .put_object()
                .bucket(BUCKET_NAME)
                .key("some-key")
                .body(body.unwrap())
                .send()
                .await?;
            println!("{:?}", res);
        }
        Method::UploadSeed { path } => {}
    };

    Ok(())
}
