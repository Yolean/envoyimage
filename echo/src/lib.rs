//! Yolean Envoy `/q/envoy/echo` filter.
//!
//! Implements an Envoy dynamic-module HTTP filter that returns a pretty-printed
//! JSON document describing the incoming request, equivalent in spirit to the
//! plain-text response from `registry.k8s.io/echoserver`.
//!
//! Filter name: `echo`. The path is configurable via the filter_config JSON,
//! defaulting to `/q/envoy/echo`. See README.md for a bootstrap snippet.

use envoy_proxy_dynamic_modules_rust_sdk::*;

mod echo;

declare_init_functions!(init, new_http_filter_config_fn);

fn init() -> bool {
    true
}

fn new_http_filter_config_fn<EC: EnvoyHttpFilterConfig, EHF: EnvoyHttpFilter>(
    _envoy_filter_config: &mut EC,
    filter_name: &str,
    filter_config: &[u8],
) -> Option<Box<dyn HttpFilterConfig<EHF>>> {
    let filter_config = std::str::from_utf8(filter_config).unwrap_or("");
    match filter_name {
        "echo" => echo::FilterConfig::new(filter_config)
            .map(|c| Box::new(c) as Box<dyn HttpFilterConfig<EHF>>),
        other => panic!("Unknown filter name: {other}"),
    }
}
