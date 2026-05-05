use anyhow::{Context, Result};
use clap::Parser;
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs::{self, File};
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::Command;
use walkdir::WalkDir;

#[derive(Parser, Debug)]
#[command(name = "package-binary")]
#[command(about = "Package Buck targets as precompiled binaries (Rust version for performance)")]
struct Args {
    /// Buck targets to package
    #[arg(required = true)]
    targets: Vec<String>,

    /// Output directory for packages
    #[arg(short, long, default_value = "binaries")]
    output_dir: PathBuf,

    /// Upload packages to mirror after creation
    #[arg(short, long)]
    upload: bool,

    /// Mirror URL for upload
    #[arg(short, long)]
    mirror_url: Option<String>,

    /// Package already-built targets without rebuilding
    #[arg(short, long)]
    skip_build: bool,

    /// Number of parallel packaging jobs (default: number of CPUs)
    #[arg(short, long)]
    jobs: Option<usize>,
}

#[derive(Debug, Serialize)]
struct PackageMetadata {
    target: String,
    name: String,
    version: String,
    config_hash: String,
    content_hash: String,
}

fn main() -> Result<()> {
    let args = Args::parse();

    // Set up rayon thread pool
    if let Some(jobs) = args.jobs {
        rayon::ThreadPoolBuilder::new()
            .num_threads(jobs)
            .build_global()
            .context("Failed to set up thread pool")?;
    }

    println!("BuckOS Binary Packager (Rust)");
    println!("{}", "=".repeat(60));
    println!("Targets: {}", args.targets.len());
    println!("Output: {}", args.output_dir.display());
    if args.skip_build {
        println!("Mode: Package already-built targets");
    }
    if args.upload {
        if let Some(ref mirror) = args.mirror_url {
            println!("Mirror: {}", mirror);
        }
    }
    println!("{}", "=".repeat(60));
    println!();

    // Process targets in parallel
    let results: Vec<_> = args
        .targets
        .par_iter()
        .map(|target| {
            package_target(
                target,
                &args.output_dir,
                args.skip_build,
                args.upload,
                args.mirror_url.as_deref(),
            )
        })
        .collect();

    // Count successes and failures
    let successful: Vec<_> = results.iter().filter_map(|r| r.as_ref().ok()).collect();
    let failed: Vec<_> = results.iter().filter_map(|r| r.as_ref().err()).collect();

    println!();
    println!("{}", "=".repeat(60));
    println!(
        "Packaged {}/{} targets",
        successful.len(),
        args.targets.len()
    );
    println!("{}", "=".repeat(60));

    for pkg_path in &successful {
        println!("  {}", pkg_path.file_name().unwrap().to_string_lossy());
    }

    if !failed.is_empty() {
        println!();
        println!("Failed targets:");
        for err in failed {
            println!("  {}", err);
        }
    }

    Ok(())
}

fn package_target(
    target: &str,
    output_dir: &Path,
    skip_build: bool,
    upload: bool,
    mirror_url: Option<&str>,
) -> Result<PathBuf> {
    println!("Packaging: {}", target);

    // Get target info
    let info = get_target_info(target, skip_build)?;

    // Calculate config hash
    let config_hash = calculate_config_hash(target, skip_build)?;

    // Build or find target
    let output_path = if skip_build {
        find_built_package(target)?
    } else {
        build_target(target)?
    };

    // Calculate file hash
    let file_hash = calculate_file_hash(&output_path)?;

    // Create package
    let package_path = create_package(
        target,
        &output_path,
        &info.name,
        &info.version,
        &config_hash,
        &file_hash,
        output_dir,
    )?;

    // Upload if requested
    if upload {
        if let Some(mirror) = mirror_url {
            upload_package(&package_path, mirror)?;
            // Also upload .sha256 file
            let hash_path = package_path.with_extension("tar.gz.sha256");
            if hash_path.exists() {
                upload_package(&hash_path, mirror)?;
            }
        }
    }

    Ok(package_path)
}

#[derive(Debug)]
struct TargetInfo {
    name: String,
    version: String,
}

fn get_target_info(target: &str, skip_build: bool) -> Result<TargetInfo> {
    let query_cmd = if skip_build { "uquery" } else { "query" };

    let output = Command::new("buck2")
        .args([
            query_cmd,
            target,
            "--output-attribute",
            "name",
            "--output-attribute",
            "version",
            "--json",
        ])
        .output()
        .context("Failed to run buck2 query")?;

    if !output.status.success() {
        // Fallback: extract from target
        let name = target.split(':').last().unwrap_or("unknown").to_string();
        return Ok(TargetInfo {
            name,
            version: "unknown".to_string(),
        });
    }

    let stdout = String::from_utf8_lossy(&output.stdout);

    // Buck2 may output logging lines before JSON, find the JSON part
    let json_str = if let Some(json_start) = stdout.find('{') {
        &stdout[json_start..]
    } else {
        &stdout
    };

    let json: serde_json::Value =
        serde_json::from_str(json_str).context("Failed to parse buck2 query output")?;

    // Target may have "buckos//" prefix in output
    let target_key = if json.get(target).is_some() {
        target
    } else {
        &format!("buckos//{}", target.trim_start_matches("//"))
    };

    let target_data = json
        .get(target_key)
        .context("Target not found in query output")?;
    let name = target_data
        .get("name")
        .and_then(|v| v.as_str())
        .unwrap_or_else(|| target.split(':').last().unwrap_or("unknown"))
        .to_string();
    let version = target_data
        .get("version")
        .and_then(|v| v.as_str())
        .unwrap_or("unknown")
        .to_string();

    Ok(TargetInfo { name, version })
}

fn calculate_config_hash(target: &str, skip_build: bool) -> Result<String> {
    let mut config_parts = Vec::new();

    // Get package compatibility
    let compat = fs::read_to_string("config/package_config.bzl")
        .ok()
        .and_then(|content| {
            regex::Regex::new(r#"PACKAGE_COMPAT\s*=\s*["'](\w+)["']"#)
                .ok()?
                .captures(&content)?
                .get(1)
                .map(|m| m.as_str().to_string())
        })
        .unwrap_or_else(|| "buckos".to_string());
    config_parts.push(format!("compat:{}", compat));

    // Get platform
    let platform = Command::new("uname")
        .arg("-m")
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_else(|| "unknown".to_string());
    config_parts.push(format!("platform:{}", platform));

    // Get USE flags from .buckconfig [use] section
    if let Ok(content) = fs::read_to_string(".buckconfig") {
        let mut flags = Vec::new();
        let mut in_use_section = false;
        for line in content.lines() {
            let trimmed = line.trim();
            if trimmed == "[use]" {
                in_use_section = true;
            } else if trimmed.starts_with('[') {
                in_use_section = false;
            } else if in_use_section {
                if let Some((key, val)) = trimmed.split_once('=') {
                    let val = val.trim().to_lowercase();
                    if val == "true" || val == "1" || val == "yes" {
                        flags.push(key.trim().to_string());
                    }
                }
            }
        }
        if !flags.is_empty() {
            flags.sort();
            config_parts.push(format!("use:{}", flags.join(",")));
        }
    }

    // Get compiler version
    if let Ok(output) = Command::new("gcc").arg("--version").output() {
        let version = String::from_utf8_lossy(&output.stdout);
        if let Some(first_line) = version.lines().next() {
            config_parts.push(format!("gcc:{}", first_line));
        }
    }

    // Get dependencies (skip if skip_build)
    if !skip_build {
        if let Ok(output) = Command::new("buck2")
            .args(["query", &format!("deps({})", target), "--output-attribute", "name"])
            .output()
        {
            if output.status.success() {
                let deps_hash = format!("{:x}", Sha256::digest(&output.stdout));
                config_parts.push(format!("deps:{}", &deps_hash[..16]));
            }
        }
    }

    // Hash all config parts
    let config_string = config_parts.join("|");
    let hash = format!("{:x}", Sha256::digest(config_string.as_bytes()));

    Ok(hash[..16].to_string())
}

fn find_built_package(target: &str) -> Result<PathBuf> {
    // Extract package path and name
    let target_path = target.trim_start_matches("//").split(':').next().unwrap();
    let package_name = target.split(':').last().unwrap();

    // Search in buck-out
    let buck_out = PathBuf::from("buck-out/v2/gen/root");

    for entry in fs::read_dir(&buck_out).context("Failed to read buck-out directory")? {
        let entry = entry?;
        if !entry.file_type()?.is_dir() {
            continue;
        }

        let pkg_dir = entry
            .path()
            .join(target_path)
            .join(format!("__{}__", package_name))
            .join(package_name);

        if pkg_dir.exists() && pkg_dir.join("usr").exists() {
            println!("Found built package at: {}", pkg_dir.display());
            return Ok(pkg_dir);
        }
    }

    anyhow::bail!("No built package found for {}", target)
}

fn build_target(target: &str) -> Result<PathBuf> {
    println!("Building {}...", target);

    // Build the target
    let status = Command::new("buck2")
        .args(["build", target])
        .status()
        .context("Failed to run buck2 build")?;

    if !status.success() {
        anyhow::bail!("Build failed for {}", target);
    }

    // Get output path
    let output = Command::new("buck2")
        .args(["build", target, "--show-output"])
        .output()
        .context("Failed to get build output")?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    let output_path = stdout
        .lines()
        .last()
        .and_then(|line| line.split_whitespace().last())
        .context("Failed to parse build output")?;

    Ok(PathBuf::from(output_path))
}

fn calculate_file_hash(path: &Path) -> Result<String> {
    println!("Calculating file hash for {}...", path.display());

    let mut hasher = Sha256::new();

    if path.is_dir() {
        // Hash all files in directory (sorted for reproducibility)
        let mut entries: Vec<_> = WalkDir::new(path)
            .into_iter()
            .filter_map(|e| e.ok())
            .filter(|e| e.file_type().is_file())
            .collect();
        entries.sort_by_key(|e| e.path().to_path_buf());

        for entry in entries {
            let mut file = File::open(entry.path())?;
            let mut buffer = [0u8; 8192];
            loop {
                let n = file.read(&mut buffer)?;
                if n == 0 {
                    break;
                }
                hasher.update(&buffer[..n]);
            }
        }
    } else {
        // Hash single file
        let mut file = File::open(path)?;
        let mut buffer = [0u8; 8192];
        loop {
            let n = file.read(&mut buffer)?;
            if n == 0 {
                break;
            }
            hasher.update(&buffer[..n]);
        }
    }

    let hash = format!("{:x}", hasher.finalize());
    Ok(hash[..16].to_string())
}

fn create_package(
    target: &str,
    output_path: &Path,
    package_name: &str,
    version: &str,
    config_hash: &str,
    file_hash: &str,
    output_dir: &Path,
) -> Result<PathBuf> {
    let package_filename = format!("{}-{}-{}-bin.tar.gz", package_name, version, config_hash);
    let package_path = output_dir.join(&package_filename);

    println!("Creating package: {}", package_filename);

    fs::create_dir_all(output_dir)?;

    // Create tarball
    let tar_gz = File::create(&package_path)?;
    let enc = flate2::write::GzEncoder::new(tar_gz, flate2::Compression::default());
    let mut tar = tar::Builder::new(enc);

    if output_path.is_dir() {
        tar.append_dir_all(package_name, output_path)?;
    } else {
        let file_name = output_path.file_name().unwrap();
        tar.append_path_with_name(output_path, file_name)?;
    }

    // Add metadata
    let metadata = PackageMetadata {
        target: target.to_string(),
        name: package_name.to_string(),
        version: version.to_string(),
        config_hash: config_hash.to_string(),
        content_hash: file_hash.to_string(),
    };

    let metadata_json = serde_json::to_string_pretty(&metadata)?;
    let mut header = tar::Header::new_gnu();
    header.set_size(metadata_json.len() as u64);
    header.set_mode(0o644);
    header.set_cksum();
    tar.append_data(&mut header, "METADATA.json", metadata_json.as_bytes())?;

    tar.finish()?;

    // Calculate SHA256 of tarball
    let mut file = File::open(&package_path)?;
    let mut hasher = Sha256::new();
    let mut buffer = [0u8; 8192];
    loop {
        let n = file.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        hasher.update(&buffer[..n]);
    }
    let tarball_hash = format!("{:x}", hasher.finalize());

    // Create .sha256 file
    let hash_filename = format!("{}.sha256", package_filename);
    let hash_path = output_dir.join(&hash_filename);

    let mut hash_file = File::create(&hash_path)?;
    writeln!(hash_file, "{}  {}", tarball_hash, package_filename)?;
    writeln!(hash_file, "# Config Hash: {}", config_hash)?;
    writeln!(hash_file, "# Content Hash: {}", file_hash)?;
    writeln!(hash_file, "# Package: {}", package_name)?;
    writeln!(hash_file, "# Version: {}", version)?;
    writeln!(hash_file, "# Target: {}", target)?;

    let size = fs::metadata(&package_path)?.len();
    println!("✓ Created: {}", package_path.display());
    println!("  Size: {:.2} MB", size as f64 / 1024.0 / 1024.0);
    println!("✓ Created: {}", hash_path.display());
    println!("  Tarball SHA256: {}...", &tarball_hash[..16]);
    println!("  Config Hash: {}", config_hash);
    println!("  Content Hash: {}", file_hash);

    Ok(package_path)
}

fn upload_package(package_path: &Path, mirror_url: &str) -> Result<()> {
    println!("Uploading {} to {}...", package_path.display(), mirror_url);

    if mirror_url.starts_with('/') {
        // Local path
        let dest = PathBuf::from(mirror_url).join(package_path.file_name().unwrap());
        fs::create_dir_all(dest.parent().unwrap())?;
        fs::copy(package_path, &dest)?;
        println!("✓ Copied to {}", dest.display());
    } else {
        // Remote SCP
        let status = Command::new("scp")
            .arg(package_path)
            .arg(mirror_url)
            .status()?;

        if !status.success() {
            anyhow::bail!("Upload failed");
        }
        println!("✓ Uploaded: {}", package_path.file_name().unwrap().to_string_lossy());
    }

    Ok(())
}
