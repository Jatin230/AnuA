use std::io::Write;

/// Append one NDJSON debug line for agent debug mode (session 50082e).
pub fn agent_debug_log(
    hypothesis_id: &str,
    location: &str,
    message: &str,
    data: serde_json::Value,
) {
    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    let line = match serde_json::to_string(&serde_json::json!({
        "sessionId": "50082e",
        "hypothesisId": hypothesis_id,
        "location": location,
        "message": message,
        "data": data,
        "timestamp": ts,
    })) {
        Ok(l) => l,
        Err(_) => return,
    };
    let path = std::env::var("AGENT_DEBUG_LOG")
        .unwrap_or_else(|_| r"c:\Users\jatin\Downloads\rustdesk\debug-50082e.log".to_string());
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
    {
        let _ = writeln!(f, "{}", line);
    }
}
