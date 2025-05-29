use alloy::hex;
use reqwest::Client;

const BLOB_SIZE_BYTES: usize = 15777216;

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

    pub async fn health(&self) {
        let resp = reqwest::get("https://httpbin.org/ip").await.unwrap();
        println!("{resp:#?}");
    }

    pub async fn put(&self, data: Vec<u8>) -> Vec<u8> {
        let put_url = format!("{}/put?commitment_mode=standard", self.url);
        let res = self
            .client
            .post(put_url.as_str())
            .body(data)
            .header("Content-Type", "application/octet-stream")
            .send()
            .await
            .unwrap();

        println!("Response Status: {}", res.status());
        res.bytes().await.unwrap().to_vec()
    }

    // Get data from EigenDA given the commitment bytes
    pub async fn get(&self, cert_bytes: Vec<u8>) -> Vec<u8> {
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
            .await
            .unwrap();
        res.bytes().await.unwrap().to_vec()
    }

    pub async fn get_chunks(&self, certs: Vec<Vec<u8>>) -> Vec<u8> {
        let mut data = Vec::new();
        for cert in certs {
            let chunk = self.get(cert).await;
            data.extend(chunk);
        }
        data
    }

    pub async fn put_chunks(&self, data: Vec<u8>) -> Vec<Vec<u8>> {
        let chunks = data.chunks(BLOB_SIZE_BYTES);
        let mut certs = Vec::new();
        for chunk in chunks {
            let cert = self.put(chunk.to_vec()).await;
            println!("cert len: {}", cert.len());
            certs.push(cert);
        }
        certs
    }

    pub async fn put_meta(&self, data: Vec<u8>) -> Vec<u8> {
        let certs = self.put_chunks(data).await;
        let certs_flatten = serde_json::to_vec(&certs).unwrap();
        let meta_cert = self.put(certs_flatten).await;
        meta_cert
    }

    pub async fn get_meta(&self, meta_cert_bytes: Vec<u8>) -> Vec<u8> {
        let certs_json = self.get(meta_cert_bytes).await;
        let certs: Vec<Vec<u8>> = serde_json::from_slice(&certs_json).unwrap();
        let data = self.get_chunks(certs).await;
        data
    }
}
