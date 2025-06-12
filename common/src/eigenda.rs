use alloy::hex;
use reqwest::Client;
use thiserror::Error;

const BLOB_SIZE_BYTES: usize = 15777216;

#[derive(Error, Debug)]
pub enum EigenDAError {
    #[error("HTTP request failed: {0}")]
    RequestError(#[from] reqwest::Error),
    #[error("JSON serialization failed: {0}")]
    SerializationError(#[from] serde_json::Error),
    #[error("Invalid response from EigenDA proxy: {message}")]
    InvalidResponse { message: String },
    #[error("Health check failed: status {status}")]
    HealthCheckFailed { status: u16 },
}

#[derive(Clone)]
pub struct EigenDAProxyClient {
    url: String,
    client: Client,
}

impl EigenDAProxyClient {
    pub fn new(url: String) -> Self {
        Self {
            url,
            client: Client::new(),
        }
    }

    pub async fn health(&self) -> Result<(), EigenDAError> {
        let health_url = format!("{}/health", self.url);
        let resp = self.client.get(&health_url).send().await?;
        
        if resp.status().is_success() {
            println!("EigenDA proxy health check passed: {}", resp.status());
            Ok(())
        } else {
            Err(EigenDAError::HealthCheckFailed {
                status: resp.status().as_u16(),
            })
        }
    }

    pub async fn put(&self, data: Vec<u8>) -> Result<Vec<u8>, EigenDAError> {
        let put_url = format!("{}/put?commitment_mode=standard", self.url);
        let res = self
            .client
            .post(put_url.as_str())
            .body(data)
            .header("Content-Type", "application/octet-stream")
            .send()
            .await?;

        if !res.status().is_success() {
            return Err(EigenDAError::InvalidResponse {
                message: format!("PUT request failed with status: {}", res.status()),
            });
        }

        println!("Response Status: {}", res.status());
        Ok(res.bytes().await?.to_vec())
    }

    // Get data from EigenDA given the commitment bytes
    pub async fn get(&self, cert_bytes: Vec<u8>) -> Result<Vec<u8>, EigenDAError> {
        let get_url = format!(
            "{}/get/0x{}?commitment_mode=standard",
            self.url,
            hex::encode(cert_bytes)
        );
        let res = self
            .client
            .get(get_url.as_str())
            .header("Content-Type", "application/octet-stream")
            .send()
            .await?;

        if !res.status().is_success() {
            return Err(EigenDAError::InvalidResponse {
                message: format!("GET request failed with status: {}", res.status()),
            });
        }

        Ok(res.bytes().await?.to_vec())
    }

    pub async fn get_chunks(&self, certs: Vec<Vec<u8>>) -> Result<Vec<u8>, EigenDAError> {
        let mut data = Vec::new();
        for cert in certs {
            let chunk = self.get(cert).await?;
            data.extend(chunk);
        }
        Ok(data)
    }

    pub async fn put_chunks(&self, data: Vec<u8>) -> Result<Vec<Vec<u8>>, EigenDAError> {
        let chunks = data.chunks(BLOB_SIZE_BYTES);
        let mut certs = Vec::new();
        for chunk in chunks {
            let cert = self.put(chunk.to_vec()).await?;
            println!("cert len: {}", cert.len());
            certs.push(cert);
        }
        Ok(certs)
    }

    pub async fn put_meta(&self, data: Vec<u8>) -> Result<Vec<u8>, EigenDAError> {
        let certs = self.put_chunks(data).await?;
        let certs_flatten = serde_json::to_vec(&certs)?;
        let meta_cert = self.put(certs_flatten).await?;
        Ok(meta_cert)
    }

    pub async fn get_meta(&self, meta_cert_bytes: Vec<u8>) -> Result<Vec<u8>, EigenDAError> {
        let certs_json = self.get(meta_cert_bytes).await?;
        let certs: Vec<Vec<u8>> = serde_json::from_slice(&certs_json)?;
        let data = self.get_chunks(certs).await?;
        Ok(data)
    }
}
