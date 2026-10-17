// Command fpparquet is a long-lived helper process embedded in the FranPhotos
// app. It reads and writes the app's parquet partition files on behalf of the
// Swift front end.
//
// Protocol: JSON Lines over stdin/stdout. The tool reads one JSON request
// object per line from stdin and writes exactly one JSON response object per
// request to stdout, flushing after each. It keeps processing requests until
// stdin is closed. Nothing but responses is ever written to stdout;
// diagnostics go to stderr.
//
// Requests:
//
//	{"cmd":"ping"}
//	{"cmd":"write","path":"<abs>","kind":"asset|timeline_index|album_index","rows":[{...}]}
//	{"cmd":"read","path":"<abs>","kind":"asset|timeline_index|album_index","offset":0,"limit":0}
//
// Responses:
//
//	{"ok":true,"version":"1"}                     ping
//	{"ok":true,"rows":<n>,"sha256":"<hex>"}       write
//	{"ok":true,"rows":[{...}]}                    read (limit:0 means all rows)
//	{"ok":false,"error":"<message>"}              any failure
package main

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/parquet-go/parquet-go"
)

// protocolVersion is reported in ping responses.
const protocolVersion = "1"

func main() {
	if err := run(os.Stdin, os.Stdout); err != nil {
		fmt.Fprintf(os.Stderr, "fpparquet: %v\n", err)
		os.Exit(1)
	}
}

// run is the protocol loop: read one JSON request per line from in, write one
// JSON response per line to out, flush after each, until EOF on in.
func run(in io.Reader, out io.Writer) error {
	r := bufio.NewReaderSize(in, 64*1024)
	w := bufio.NewWriterSize(out, 64*1024)
	for {
		line, err := r.ReadBytes('\n')
		if len(bytes.TrimSpace(line)) > 0 {
			if werr := writeResponseLine(w, handleLine(line)); werr != nil {
				return fmt.Errorf("writing response: %w", werr)
			}
		}
		if err != nil {
			if err == io.EOF {
				return nil
			}
			return fmt.Errorf("reading request: %w", err)
		}
	}
}

// writeResponseLine marshals resp as one JSON line to w and flushes.
func writeResponseLine(w *bufio.Writer, resp any) error {
	b, err := json.Marshal(resp)
	if err != nil {
		b = []byte(`{"ok":false,"error":"internal: failed to marshal response"}`)
	}
	if _, err := w.Write(b); err != nil {
		return err
	}
	if err := w.WriteByte('\n'); err != nil {
		return err
	}
	return w.Flush()
}

// request is the union of all request fields; cmd selects the operation.
type request struct {
	Cmd    string          `json:"cmd"`
	Path   string          `json:"path"`
	Kind   string          `json:"kind"`
	Offset int             `json:"offset"`
	Limit  int             `json:"limit"`
	Rows   json.RawMessage `json:"rows"`
}

// Response shapes. Field order in the structs matches the documented wire
// order; encoding/json emits fields in declaration order.
type pingResponse struct {
	OK      bool   `json:"ok"`
	Version string `json:"version"`
}

type writeResponse struct {
	OK     bool   `json:"ok"`
	Rows   int    `json:"rows"`
	SHA256 string `json:"sha256"`
}

type readResponse struct {
	OK   bool `json:"ok"`
	Rows any  `json:"rows"`
}

type errorResponse struct {
	OK    bool   `json:"ok"`
	Error string `json:"error"`
}

// handleLine parses one request line and produces its response. It never
// panics: internal panics are converted into error responses so the helper
// process stays alive for subsequent requests.
func handleLine(line []byte) (resp any) {
	defer func() {
		if r := recover(); r != nil {
			resp = errorResponse{OK: false, Error: fmt.Sprintf("internal panic: %v", r)}
		}
	}()

	var req request
	if err := json.Unmarshal(line, &req); err != nil {
		return errorResponse{OK: false, Error: fmt.Sprintf("invalid request JSON: %v", err)}
	}

	switch req.Cmd {
	case "ping":
		return pingResponse{OK: true, Version: protocolVersion}
	case "write":
		return handleWrite(req)
	case "read":
		return handleRead(req)
	default:
		return errorResponse{OK: false, Error: fmt.Sprintf("unknown command %q", req.Cmd)}
	}
}

func checkPath(cmd, path string) *errorResponse {
	if path == "" {
		return &errorResponse{OK: false, Error: cmd + ": missing path"}
	}
	if !filepath.IsAbs(path) {
		return &errorResponse{OK: false, Error: fmt.Sprintf("%s: path is not absolute: %q", cmd, path)}
	}
	return nil
}

func handleWrite(req request) any {
	if e := checkPath("write", req.Path); e != nil {
		return *e
	}
	if len(req.Rows) == 0 {
		return errorResponse{OK: false, Error: "write: missing rows"}
	}
	switch req.Kind {
	case "asset":
		var rows []AssetRow
		if err := json.Unmarshal(req.Rows, &rows); err != nil {
			return errorResponse{OK: false, Error: fmt.Sprintf("write: decoding asset rows: %v", err)}
		}
		return doWrite(req.Path, rows)
	case "timeline_index":
		var rows []TimelineIndexRow
		if err := json.Unmarshal(req.Rows, &rows); err != nil {
			return errorResponse{OK: false, Error: fmt.Sprintf("write: decoding timeline_index rows: %v", err)}
		}
		return doWrite(req.Path, rows)
	case "album_index":
		var rows []AlbumIndexRow
		if err := json.Unmarshal(req.Rows, &rows); err != nil {
			return errorResponse{OK: false, Error: fmt.Sprintf("write: decoding album_index rows: %v", err)}
		}
		return doWrite(req.Path, rows)
	default:
		return errorResponse{OK: false, Error: fmt.Sprintf("write: unknown kind %q", req.Kind)}
	}
}

func doWrite[T any](path string, rows []T) any {
	n, sum, err := writeParquetFile(path, rows)
	if err != nil {
		return errorResponse{OK: false, Error: err.Error()}
	}
	return writeResponse{OK: true, Rows: n, SHA256: sum}
}

func handleRead(req request) any {
	if e := checkPath("read", req.Path); e != nil {
		return *e
	}
	switch req.Kind {
	case "asset":
		return doRead[AssetRow](req)
	case "timeline_index":
		return doRead[TimelineIndexRow](req)
	case "album_index":
		return doRead[AlbumIndexRow](req)
	default:
		return errorResponse{OK: false, Error: fmt.Sprintf("read: unknown kind %q", req.Kind)}
	}
}

func doRead[T any](req request) any {
	rows, err := readParquetFile[T](req.Path, req.Offset, req.Limit)
	if err != nil {
		return errorResponse{OK: false, Error: err.Error()}
	}
	return readResponse{OK: true, Rows: rows}
}

// writeParquetFile writes rows as a snappy-compressed parquet file to path.
// The write is atomic: rows go to a temp file in the same directory, which is
// fsynced and renamed over path. Parent directories are created as needed.
// Returns the row count and the hex SHA-256 of the file bytes.
func writeParquetFile[T any](path string, rows []T) (int, string, error) {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return 0, "", fmt.Errorf("write: creating directory %s: %w", dir, err)
	}
	tmp, err := os.CreateTemp(dir, ".fpparquet-*.tmp")
	if err != nil {
		return 0, "", fmt.Errorf("write: creating temp file in %s: %w", dir, err)
	}
	tmpName := tmp.Name()
	committed := false
	defer func() {
		if !committed {
			tmp.Close()
			os.Remove(tmpName)
		}
	}()
	if err := tmp.Chmod(0o644); err != nil {
		return 0, "", fmt.Errorf("write: chmod temp file: %w", err)
	}

	h := sha256.New()
	w := parquet.NewGenericWriter[T](io.MultiWriter(tmp, h), parquet.Compression(&parquet.Snappy))
	if _, err := w.Write(rows); err != nil {
		w.Close()
		return 0, "", fmt.Errorf("write: encoding rows: %w", err)
	}
	if err := w.Close(); err != nil {
		return 0, "", fmt.Errorf("write: finalizing parquet stream: %w", err)
	}
	if err := tmp.Sync(); err != nil {
		return 0, "", fmt.Errorf("write: syncing temp file: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return 0, "", fmt.Errorf("write: closing temp file: %w", err)
	}
	if err := os.Rename(tmpName, path); err != nil {
		return 0, "", fmt.Errorf("write: renaming into place: %w", err)
	}
	committed = true
	return len(rows), hex.EncodeToString(h.Sum(nil)), nil
}

// readParquetFile reads rows of type T from the parquet file at path and
// applies offset/limit in file row order. limit <= 0 means all remaining rows.
// The returned slice is never nil so it marshals to JSON [].
func readParquetFile[T any](path string, offset, limit int) ([]T, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("read: %w", err)
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return nil, fmt.Errorf("read: stat %s: %w", path, err)
	}
	rows, err := parquet.Read[T](f, st.Size())
	if err != nil {
		return nil, fmt.Errorf("read: decoding parquet %s: %w", path, err)
	}
	if offset < 0 {
		offset = 0
	}
	if offset > len(rows) {
		offset = len(rows)
	}
	rows = rows[offset:]
	if limit > 0 && limit < len(rows) {
		rows = rows[:limit]
	}
	if rows == nil {
		rows = []T{}
	}
	return rows, nil
}
