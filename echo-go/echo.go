package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"strings"

	"github.com/envoyproxy/envoy/source/extensions/dynamic_modules/sdk/go/shared"
)

// envoyVersion is injected at build time via
//
//	go build -ldflags "-X main.envoyVersion=$ENVOY_VERSION".
var envoyVersion = "unknown"

type echoConfigJSON struct {
	PathPrefix *string `json:"path_prefix,omitempty"`
}

type echoFilterConfigFactory struct {
	shared.EmptyHttpFilterConfigFactory
}

func (f *echoFilterConfigFactory) Create(_ shared.HttpFilterConfigHandle, raw []byte) (shared.HttpFilterFactory, error) {
	pathPrefix := "/"
	if len(bytes.TrimSpace(raw)) > 0 {
		dec := json.NewDecoder(bytes.NewReader(raw))
		dec.DisallowUnknownFields()
		var cfg echoConfigJSON
		if err := dec.Decode(&cfg); err != nil {
			return nil, fmt.Errorf("echo: invalid filter_config JSON: %w", err)
		}
		if cfg.PathPrefix != nil {
			pathPrefix = *cfg.PathPrefix
		}
	}
	return &echoFilterFactory{pathPrefix: pathPrefix, hostname: readHostname()}, nil
}

func readHostname() string {
	if h := os.Getenv("HOSTNAME"); h != "" {
		return h
	}
	if b, err := os.ReadFile("/etc/hostname"); err == nil {
		if s := strings.TrimSpace(string(b)); s != "" {
			return s
		}
	}
	return "envoy"
}

type echoFilterFactory struct {
	shared.EmptyHttpFilterFactory
	pathPrefix string
	hostname   string
}

func (f *echoFilterFactory) Create(handle shared.HttpFilterHandle) shared.HttpFilter {
	return &echoFilter{handle: handle, pathPrefix: f.pathPrefix, hostname: f.hostname}
}

type echoFilter struct {
	shared.EmptyHttpFilter
	handle     shared.HttpFilterHandle
	pathPrefix string
	hostname   string
}

type echoBody struct {
	Hostname string              `json:"hostname"`
	Server   echoServer          `json:"server"`
	Request  echoRequest         `json:"request"`
	Headers  map[string][]string `json:"headers"`
}

type echoServer struct {
	Name    string `json:"name"`
	Version string `json:"version"`
}

type echoRequest struct {
	Method        string `json:"method"`
	Path          string `json:"path"`
	RealPath      string `json:"real_path"`
	Query         string `json:"query"`
	Scheme        string `json:"scheme"`
	Authority     string `json:"authority"`
	RequestURI    string `json:"request_uri"`
	ClientAddress string `json:"client_address"`
	Protocol      string `json:"protocol"`
}

func (f *echoFilter) OnRequestHeaders(headers shared.HeaderMap, _ bool) shared.HeadersStatus {
	pathFull := headers.GetOne(":path").ToString()
	method := headers.GetOne(":method").ToString()
	realPath := pathFull
	query := ""
	if i := strings.Index(pathFull, "?"); i >= 0 {
		realPath = pathFull[:i]
		query = pathFull[i+1:]
	}
	if !strings.HasPrefix(realPath, f.pathPrefix) {
		return shared.HeadersStatusContinue
	}

	scheme := headers.GetOne(":scheme").ToString()
	authority := headers.GetOne(":authority").ToString()
	sourceAddr := ""
	if buf, ok := f.handle.GetAttributeString(shared.AttributeIDSourceAddress); ok {
		sourceAddr = buf.ToString()
	}

	h := map[string][]string{}
	for _, kv := range headers.GetAll() {
		k := strings.ToLower(kv[0].ToString())
		if strings.HasPrefix(k, ":") {
			continue
		}
		h[k] = append(h[k], kv[1].ToString())
	}

	requestURI := pathFull
	if scheme != "" && authority != "" {
		requestURI = scheme + "://" + authority + pathFull
	}

	body := echoBody{
		Hostname: f.hostname,
		Server:   echoServer{Name: "envoy", Version: envoyVersion},
		Request: echoRequest{
			Method:        method,
			Path:          pathFull,
			RealPath:      realPath,
			Query:         query,
			Scheme:        scheme,
			Authority:     authority,
			RequestURI:    requestURI,
			ClientAddress: sourceAddr,
			Protocol:      "HTTP/1.1",
		},
		Headers: h,
	}

	js, err := json.MarshalIndent(&body, "", "  ")
	if err != nil {
		js = []byte("{}")
	}

	respHeaders := [][2]string{
		{"content-type", "application/json; charset=utf-8"},
		{"cache-control", "no-store, no-cache, must-revalidate, max-age=0"},
		{"pragma", "no-cache"},
	}
	// Same HEAD compromise as the Rust filter: envoy auto-computes
	// content-length from the body bytes; passing the full body on
	// HEAD would leave a content-length header on the response that
	// hangs HTTP/1.1 clients (curl 8.5 etc). Empty body for HEAD.
	var bodyBytes []byte
	if !strings.EqualFold(method, "HEAD") {
		bodyBytes = js
	}
	f.handle.SendLocalResponse(200, respHeaders, bodyBytes, "echo")
	return shared.HeadersStatusStop
}
