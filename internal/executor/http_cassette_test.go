package executor

import (
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestHttpDigest(t *testing.T) {
	d1 := httpDigest("GET", "http://example.com/x", nil)
	d2 := httpDigest("GET", "http://example.com/x", []byte(""))
	if d1 != d2 {
		t.Errorf("nil and empty-string bodies should hash the same: %s vs %s", d1, d2)
	}
	d3 := httpDigest("GET", "http://example.com/x", []byte("body"))
	if d3 == d1 {
		t.Errorf("body should change the hash")
	}
	d4 := httpDigest("POST", "http://example.com/x", nil)
	if d4 == d1 {
		t.Errorf("method should change the hash")
	}
	d5 := httpDigest("GET", "http://example.com/y", nil)
	if d5 == d1 {
		t.Errorf("url should change the hash")
	}
}

func TestHttpCassetteRoundtrip(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "demo.json")
	in := httpCassette{
		Hash:        "abc123",
		Method:      "POST",
		URL:         "https://api.example.com/v1/x",
		RequestBody: `{"q":"hi"}`,
		Status:      201,
		Headers:     http.Header{"Content-Type": []string{"application/json"}},
		Body:        `{"id":42}`,
		UpdatedAt:   "2026-05-11T00:00:00Z",
	}
	if err := writeHttpCassette(path, in); err != nil {
		t.Fatalf("writeHttpCassette: %v", err)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("cassette not at expected path: %v", err)
	}
	out, ok := readHttpCassette(path)
	if !ok {
		t.Fatal("readHttpCassette: not ok")
	}
	if !reflect.DeepEqual(in, out) {
		t.Errorf("roundtrip mismatch:\nin:  %+v\nout: %+v", in, out)
	}
}

func TestReadHttpCassetteMissingFile(t *testing.T) {
	dir := t.TempDir()
	if _, ok := readHttpCassette(filepath.Join(dir, "missing.json")); ok {
		t.Fatal("expected ok=false for missing file")
	}
}
