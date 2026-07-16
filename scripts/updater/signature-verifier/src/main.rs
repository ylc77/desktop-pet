use minisign_verify::{PublicKey, Signature};
use std::{env, fs, process};

fn main() {
    let arguments: Vec<String> = env::args().collect();
    if arguments.len() != 4 {
        process::exit(64);
    }
    let public_key = PublicKey::from_file(&arguments[1]).unwrap_or_else(|_| process::exit(65));
    let signature = Signature::from_file(&arguments[2]).unwrap_or_else(|_| process::exit(66));
    let payload = fs::read(&arguments[3]).unwrap_or_else(|_| process::exit(67));
    if public_key.verify(&payload, &signature, true).is_err() {
        process::exit(68);
    }
}
