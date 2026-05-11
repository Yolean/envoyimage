// Echo dynamic-modules filter implemented with the official Go SDK.
// Parallel to the Rust implementation in echo/ — same wire behaviour,
// different language for comparison.
package main

import (
	sdk "github.com/envoyproxy/envoy/source/extensions/dynamic_modules/sdk/go"
	_ "github.com/envoyproxy/envoy/source/extensions/dynamic_modules/sdk/go/abi"
	"github.com/envoyproxy/envoy/source/extensions/dynamic_modules/sdk/go/shared"
)

func main() {}

func init() {
	sdk.RegisterHttpFilterConfigFactories(map[string]shared.HttpFilterConfigFactory{
		"echo": &echoFilterConfigFactory{},
	})
}
