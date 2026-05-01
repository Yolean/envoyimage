use envoy_proxy_dynamic_modules_rust_sdk::*;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::sync::Arc;

const ENVOY_VERSION: &str = match option_env!("ENVOY_VERSION") {
    Some(v) => v,
    None => "unknown",
};

#[derive(Deserialize, Default)]
#[serde(deny_unknown_fields)]
struct ConfigJson {
    #[serde(default)]
    path: Option<String>,
}

pub struct FilterConfig {
    inner: Arc<Inner>,
}

struct Inner {
    path: String,
    hostname: String,
}

impl FilterConfig {
    pub fn new(filter_config: &str) -> Option<Self> {
        let parsed: ConfigJson = if filter_config.trim().is_empty() {
            ConfigJson::default()
        } else {
            match serde_json::from_str(filter_config) {
                Ok(c) => c,
                Err(err) => {
                    eprintln!("echo: invalid filter_config JSON: {err}");
                    return None;
                }
            }
        };
        let path = parsed.path.unwrap_or_else(|| "/q/envoy/echo".to_string());
        Some(Self {
            inner: Arc::new(Inner {
                path,
                hostname: read_hostname(),
            }),
        })
    }
}

fn read_hostname() -> String {
    if let Ok(h) = std::env::var("HOSTNAME") {
        if !h.is_empty() {
            return h;
        }
    }
    if let Ok(h) = std::fs::read_to_string("/etc/hostname") {
        let trimmed = h.trim();
        if !trimmed.is_empty() {
            return trimmed.to_string();
        }
    }
    "envoy".to_string()
}

impl<EHF: EnvoyHttpFilter> HttpFilterConfig<EHF> for FilterConfig {
    fn new_http_filter(&self, _envoy: &mut EHF) -> Box<dyn HttpFilter<EHF>> {
        Box::new(EchoFilter {
            inner: Arc::clone(&self.inner),
        })
    }
}

pub struct EchoFilter {
    inner: Arc<Inner>,
}

#[derive(Serialize)]
struct EchoBody<'a> {
    hostname: &'a str,
    server: Server<'a>,
    request: RequestInfo<'a>,
    headers: BTreeMap<String, Vec<String>>,
}

#[derive(Serialize)]
struct Server<'a> {
    name: &'a str,
    version: &'a str,
}

#[derive(Serialize)]
struct RequestInfo<'a> {
    method: String,
    path: String,
    real_path: String,
    query: String,
    scheme: String,
    authority: String,
    request_uri: String,
    client_address: String,
    protocol: &'a str,
}

impl<EHF: EnvoyHttpFilter> HttpFilter<EHF> for EchoFilter {
    fn on_request_headers(
        &mut self,
        envoy_filter: &mut EHF,
        _end_of_stream: bool,
    ) -> abi::envoy_dynamic_module_type_on_http_filter_request_headers_status {
        let raw_headers = envoy_filter.get_request_headers();

        let mut method = String::new();
        let mut path_full = String::new();
        let mut scheme = String::new();
        let mut authority = String::new();
        let mut headers: BTreeMap<String, Vec<String>> = BTreeMap::new();

        for (k, v) in &raw_headers {
            let Ok(key) = std::str::from_utf8(k.as_slice()) else {
                continue;
            };
            let Ok(val) = std::str::from_utf8(v.as_slice()) else {
                continue;
            };
            match key {
                ":method" => method = val.to_string(),
                ":path" => path_full = val.to_string(),
                ":scheme" => scheme = val.to_string(),
                ":authority" => authority = val.to_string(),
                k if k.starts_with(':') => {}
                _ => headers
                    .entry(key.to_ascii_lowercase())
                    .or_default()
                    .push(val.to_string()),
            }
        }

        let (real_path, query) = match path_full.find('?') {
            Some(i) => (path_full[..i].to_string(), path_full[i + 1..].to_string()),
            None => (path_full.clone(), String::new()),
        };

        if real_path != self.inner.path {
            return abi::envoy_dynamic_module_type_on_http_filter_request_headers_status::Continue;
        }

        let client_address = envoy_filter
            .get_attribute_string(abi::envoy_dynamic_module_type_attribute_id::SourceAddress)
            .map(|b| String::from_utf8_lossy(b.as_slice()).to_string())
            .unwrap_or_default();

        let request_uri = if !scheme.is_empty() && !authority.is_empty() {
            format!("{scheme}://{authority}{path_full}")
        } else {
            path_full.clone()
        };

        let body = EchoBody {
            hostname: &self.inner.hostname,
            server: Server {
                name: "envoy",
                version: ENVOY_VERSION,
            },
            request: RequestInfo {
                method,
                path: path_full,
                real_path,
                query,
                scheme,
                authority,
                request_uri,
                client_address,
                protocol: "HTTP/1.1",
            },
            headers,
        };

        let json = serde_json::to_vec_pretty(&body).unwrap_or_else(|_| b"{}".to_vec());
        // Belt-and-braces against caches/browsers that ignore the lack of
        // explicit freshness — every echo response must reflect *this*
        // request, never a stored copy.
        let response_headers: [(&str, &[u8]); 3] = [
            ("content-type", b"application/json; charset=utf-8"),
            (
                "cache-control",
                b"no-store, no-cache, must-revalidate, max-age=0",
            ),
            ("pragma", b"no-cache"),
        ];
        envoy_filter.send_response(200, &response_headers, Some(&json), None);
        abi::envoy_dynamic_module_type_on_http_filter_request_headers_status::StopIteration
    }
}
