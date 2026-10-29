//! Loopback native-provider fixture. Tests exercise the actual bundled Nouli engine and transport.
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use serde_json::{Value, json};

pub(crate) struct Provider {
    stop: Arc<AtomicBool>,
    pub(crate) refuse: Arc<AtomicBool>,
    pub(crate) stall: Arc<AtomicBool>,
    pub(crate) received: Arc<Mutex<Vec<Value>>>,
    worker: Option<JoinHandle<()>>,
}

impl Provider {
    pub(crate) fn new(home: &Path) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let address = listener.local_addr().unwrap();
        std::fs::create_dir_all(home.join(".nouli")).unwrap();
        std::fs::write(home.join(".nouli/config.toml"), format!(
            "default_provider = \"fixture\"\ndefault_model = \"offline\"\n[execution]\nmax_attempts = 1\n[providers.fixture]\nprotocol = \"openai-decisions\"\nbase_url = \"http://{address}\"\n[providers.fixture.models.offline]\ncontext_budget_tokens = 100000\nreserved_output_tokens = 128\n"
        )).unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let refuse = Arc::new(AtomicBool::new(false));
        let stall = Arc::new(AtomicBool::new(false));
        let received = Arc::new(Mutex::new(Vec::new()));
        let (flag, refusal, stalled, requests) = (
            Arc::clone(&stop),
            Arc::clone(&refuse),
            Arc::clone(&stall),
            Arc::clone(&received),
        );
        let worker = thread::spawn(move || {
            while !flag.load(Ordering::Relaxed) {
                let Ok((mut stream, _)) = listener.accept() else {
                    thread::sleep(Duration::from_millis(5));
                    continue;
                };
                // Accepted sockets can inherit the listener's nonblocking mode on macOS.
                stream.set_nonblocking(false).unwrap();
                stream
                    .set_read_timeout(Some(Duration::from_secs(2)))
                    .unwrap();
                let Some((headers, body)) = request(&mut stream) else {
                    continue;
                };
                requests
                    .lock()
                    .unwrap()
                    .push(json!({"headers":headers,"body":body}));
                while stalled.load(Ordering::Relaxed) && !flag.load(Ordering::Relaxed) {
                    thread::sleep(Duration::from_millis(5));
                }
                if flag.load(Ordering::Relaxed) {
                    break;
                }
                thread::sleep(Duration::from_millis(30));
                let question = &body["questions"][0];
                let name = question["name"].clone();
                let answer = if refusal.load(Ordering::Relaxed) {
                    json!({"type":"refusal","name":name})
                } else {
                    match question["type"].as_str().unwrap() {
                        "predicate" => json!({"type":"predicate","name":name,"probability":0.94}),
                        "choice" => {
                            let choices = question["choices"].as_array().unwrap();
                            let probabilities: Vec<_> = choices.iter().enumerate().map(|(i, choice)| json!({
                                "value":choice["value"],"probability":if i == 0 {0.8} else {0.2 / f64::from(u16::try_from(choices.len() - 1).unwrap())}
                            })).collect();
                            json!({"type":"choice","name":name,"choice":choices[0]["value"],"probabilities":probabilities})
                        }
                        "score" => {
                            let levels = question["levels"].as_array().unwrap();
                            let probabilities: Vec<_> = levels.iter().enumerate().map(|(i, level)| json!({
                                "value":i,"label":level["label"],"probability":match i {1=>0.57,2=>0.43,_=>0.0}
                            })).collect();
                            json!({"type":"score","name":name,"score":1.43,"probabilities":probabilities})
                        }
                        kind => panic!("unexpected native question {kind}"),
                    }
                };
                let body = json!({"model":"offline","answers":[answer]}).to_string();
                let response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                let _ = stream.write_all(response.as_bytes());
            }
        });
        Self {
            stop,
            refuse,
            stall,
            received,
            worker: Some(worker),
        }
    }

    pub(crate) fn calls(&self) -> usize {
        self.received.lock().unwrap().len()
    }
}

fn request(stream: &mut TcpStream) -> Option<(String, Value)> {
    let mut bytes = Vec::new();
    let mut chunk = [0_u8; 4096];
    loop {
        let count = stream
            .read(&mut chunk)
            .expect("loopback provider could not read request");
        if count == 0 {
            return None;
        }
        bytes.extend_from_slice(&chunk[..count]);
        if bytes.len() > 2 * 1024 * 1024 {
            return None;
        }
        if let Some(split) = bytes.windows(4).position(|part| part == b"\r\n\r\n") {
            let headers = String::from_utf8(bytes[..split].to_vec())
                .expect("loopback headers were not UTF-8");
            let length: usize = headers
                .lines()
                .find_map(|line| {
                    let (name, value) = line.split_once(':')?;
                    name.eq_ignore_ascii_case("content-length")
                        .then(|| value.trim().parse().ok())
                        .flatten()
                })
                .expect("loopback request missing content length");
            if bytes.len() >= split + 4 + length {
                return Some((
                    headers,
                    serde_json::from_slice(&bytes[split + 4..split + 4 + length])
                        .expect("loopback body did not decode"),
                ));
            }
        }
    }
}

impl Drop for Provider {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(worker) = self.worker.take() {
            worker.join().unwrap();
        }
    }
}
