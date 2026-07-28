//! Minimal Axum peer for Viltrum HTTP benches (cleartext, no logging).
//! Same shape as benches/run.sh: GET / → "ok", POST /echo JSON.

use axum::{
    extract::Json,
    http::StatusCode,
    response::IntoResponse,
    routing::{get, post},
    Router,
};
use serde_json::{json, Value};
use std::net::SocketAddr;

#[tokio::main]
async fn main() {
    let app = Router::new()
        .route("/", get(ok))
        .route("/echo", post(echo));

    let addr: SocketAddr = "127.0.0.1:18098".parse().expect("addr");
    let listener = tokio::net::TcpListener::bind(addr).await.expect("bind");
    eprintln!("[axum-bench] listening on http://{addr}");
    axum::serve(listener, app).await.expect("serve");
}

async fn ok() -> impl IntoResponse {
    (StatusCode::OK, "ok")
}

async fn echo(Json(body): Json<Value>) -> impl IntoResponse {
    let title = body
        .get("title")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    (
        StatusCode::OK,
        [("content-type", "application/json")],
        json!({"t": title}).to_string(),
    )
}
