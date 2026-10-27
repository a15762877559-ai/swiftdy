#[tokio::main]
async fn main() {
    if let Err(error) = doustudio_rust::cli::run().await {
        eprintln!(
            "state={} reason={error}",
            if error == doustudio_rust::Error::Cancelled {
                "CANCELLED"
            } else {
                "FAILED"
            }
        );
        std::process::exit(if error == doustudio_rust::Error::Cancelled {
            130
        } else {
            1
        });
    }
}
