use std::{env, path::PathBuf};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let config = prost_build::Config::new();
    let out_dir = PathBuf::from(env::var("OUT_DIR").unwrap());
    tonic_build::configure()
        .file_descriptor_set_path(out_dir.join("rxp_descriptor.bin"))
        .compile_with_config(config, &["proto/rxp.proto"], &["proto"])?;
    Ok(())
}
