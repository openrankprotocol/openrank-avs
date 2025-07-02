use std::env;
use std::fs;
use std::path::Path;

macro_rules! warning {
    ($($tokens: tt)*) => {
        println!("cargo::warning={}", format!($($tokens)*))
    }
}

fn main() {
    // Get the current directory
    let current_dir = env::current_dir().expect("Failed to get current directory");

    // Get the parent directory
    let parent_dir = current_dir
        .parent()
        .expect("Failed to get parent directory");

    if !parent_dir.ends_with("package") {
        return;
    }

    // Source directory: contracts/out/
    let contracts_out_dir = parent_dir
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .join("contracts")
        .join("out");

    // Destination directory: parent directory
    let destination_dir = parent_dir.join("contracts").join("out");

    warning!("{}", contracts_out_dir.display());
    warning!("{}", destination_dir.display());

    // Check if the source directory exists
    if contracts_out_dir.exists() {
        println!("cargo:rerun-if-changed={}", contracts_out_dir.display());

        // Copy the contents of contracts/out/ to the parent directory
        if let Err(e) = copy_dir_contents(&contracts_out_dir, destination_dir.as_path()) {
            println!("cargo:error=Failed to copy contracts/out/ contents: {}", e);
        }
    }
}

fn copy_dir_contents(src: &Path, dst: &Path) -> std::io::Result<()> {
    if !src.exists() {
        return Ok(());
    }

    // Create destination directory if it doesn't exist
    if !dst.exists() {
        fs::create_dir_all(dst)?;
    }

    // Read the source directory
    for entry in fs::read_dir(src)? {
        let entry = entry?;
        let src_path = entry.path();
        let file_name = entry.file_name();
        let dst_path = dst.join(&file_name);

        if src_path.is_dir() {
            // Recursively copy subdirectories
            fs::create_dir_all(&dst_path)?;
            copy_dir_contents(&src_path, &dst_path)?;
        } else {
            // Copy files
            fs::copy(&src_path, &dst_path)?;
        }
    }

    Ok(())
}
