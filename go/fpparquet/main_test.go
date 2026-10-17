package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func ptr[T any](v T) *T { return &v }

// sampleAssetRows returns three rows covering: all optionals populated, all
// optionals null, and a mixed video row.
func sampleAssetRows() []AssetRow {
	return []AssetRow{
		{
			UUID:                  "11111111-2222-3333-4444-555555555555",
			MediaType:             "photo",
			CapturedAt:            1741910400,
			CapturedAtTZ:          ptr(int32(-25200)),
			AddedAt:               1741996800,
			DurationMs:            nil,
			Width:                 4032,
			Height:                3024,
			FileSize:              3_145_728,
			SHA256:                "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
			OriginalRelpath:       "2025/03/IMG_0001.HEIC",
			Filename:              "IMG_0001.HEIC",
			UTI:                   "public.heic",
			Title:                 ptr("Sunset at the beach"),
			Caption:               ptr("A long exposure shot."),
			IsFavorite:            true,
			IsHidden:              false,
			IsDeleted:             false,
			DeletedAt:             nil,
			Rating:                5,
			CameraMake:            ptr("Apple"),
			CameraModel:           ptr("iPhone 16 Pro"),
			LensModel:             ptr("iPhone 16 Pro back triple camera 6.765mm f/1.78"),
			ISO:                   ptr(int32(64)),
			Aperture:              ptr(1.78),
			ShutterSpeed:          ptr(0.008),
			FocalLength:           ptr(6.765),
			Latitude:              ptr(37.7749),
			Longitude:             ptr(-122.4194),
			Altitude:              ptr(15.5),
			HDRType:               "gainmap",
			IsLivePhoto:           true,
			LivePhotoVideoRelpath: ptr("2025/03/IMG_0001.MOV"),
			LivePhotoStillTimeMs:  ptr(int32(1500)),
			VideoCodec:            nil,
			ColorSpace:            ptr("Display P3"),
			HasAudio:              nil,
			FrameRate:             nil,
			EditVersion:           2,
			AlbumSortIndex:        7,
		},
		{
			// Every optional field nil; required fields at zero values.
			UUID:            "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
			MediaType:       "photo",
			CapturedAt:      0,
			AddedAt:         1,
			Width:           1,
			Height:          1,
			FileSize:        0,
			SHA256:          "",
			OriginalRelpath: "x",
			Filename:        "x",
			UTI:             "public.jpeg",
			HDRType:         "sdr",
		},
		{
			UUID:            "99999999-8888-7777-6666-555555555555",
			MediaType:       "video",
			CapturedAt:      1735689600,
			CapturedAtTZ:    ptr(int32(0)),
			AddedAt:         1735689700,
			DurationMs:      ptr(int32(15533)),
			Width:           3840,
			Height:          2160,
			FileSize:        88_000_000,
			SHA256:          "abcd",
			OriginalRelpath: "2025/01/clip.mp4",
			Filename:        "clip.mp4",
			UTI:             "public.mpeg-4",
			Title:           nil,
			Caption:         ptr(""),
			IsFavorite:      false,
			IsHidden:        true,
			IsDeleted:       true,
			DeletedAt:       ptr(int64(1735690000)),
			Rating:          0,
			CameraMake:      nil,
			CameraModel:     ptr("Canon EOS R5"),
			LensModel:       nil,
			ISO:             nil,
			Aperture:        nil,
			ShutterSpeed:    nil,
			FocalLength:     nil,
			Latitude:        nil,
			Longitude:       nil,
			Altitude:        nil,
			HDRType:         "hlg",
			IsLivePhoto:     false,
			VideoCodec:      ptr("hevc"),
			ColorSpace:      ptr("BT.2020 HLG"),
			HasAudio:        ptr(true),
			FrameRate:       ptr(29.97),
			EditVersion:     0,
			AlbumSortIndex:  0,
		},
	}
}

func sampleTimelineRows(n int) []TimelineIndexRow {
	rows := make([]TimelineIndexRow, n)
	for i := range rows {
		rows[i] = TimelineIndexRow{
			Month:         fmt.Sprintf("2025-%02d", i+1),
			RowCount:      int32(100 + i),
			FirstCaptured: int64(1740000000 + i*1000),
			LastCaptured:  int64(1740000900 + i*1000),
			CoverUUID:     fmt.Sprintf("cover-uuid-%d", i),
			SHA256:        fmt.Sprintf("sha-%d", i),
		}
	}
	return rows
}

func sampleAlbumRows() []AlbumIndexRow {
	return []AlbumIndexRow{
		{AlbumUUID: "album-1", Name: "Favorites", AlbumType: "builtin", RowCount: 42, CoverUUID: "cover-1", SHA256: "sha-a"},
		{AlbumUUID: "album-2", Name: "Trip to Japan", AlbumType: "manual", RowCount: 0, CoverUUID: "", SHA256: ""},
		{AlbumUUID: "album-3", Name: "Screenshots", AlbumType: "smart", RowCount: 1000, CoverUUID: "cover-3", SHA256: "sha-c"},
	}
}

// roundTrip writes rows (through the JSON wire form, like a real request),
// verifies the reported SHA-256 against the file on disk, reads the file back,
// and returns the decoded rows.
func roundTrip[T any](t *testing.T, path string, rows []T) []T {
	t.Helper()

	// Simulate the protocol: rows cross the boundary as JSON.
	wire, err := json.Marshal(rows)
	if err != nil {
		t.Fatalf("marshal rows: %v", err)
	}
	var decoded []T
	if err := json.Unmarshal(wire, &decoded); err != nil {
		t.Fatalf("unmarshal rows: %v", err)
	}

	n, sum, err := writeParquetFile(path, decoded)
	if err != nil {
		t.Fatalf("writeParquetFile: %v", err)
	}
	if n != len(rows) {
		t.Fatalf("writeParquetFile returned rows=%d, want %d", n, len(rows))
	}

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("reading written file: %v", err)
	}
	fileSum := sha256.Sum256(data)
	if sum != hex.EncodeToString(fileSum[:]) {
		t.Fatalf("reported sha256 %q does not match file contents %q", sum, hex.EncodeToString(fileSum[:]))
	}

	got, err := readParquetFile[T](path, 0, 0)
	if err != nil {
		t.Fatalf("readParquetFile: %v", err)
	}
	return got
}

func TestRoundTripAsset(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nested", "dir", "assets.parquet")
	want := sampleAssetRows()

	// Expected values after a JSON round trip (what the parquet layer sees).
	wire, _ := json.Marshal(want)
	var expected []AssetRow
	if err := json.Unmarshal(wire, &expected); err != nil {
		t.Fatal(err)
	}

	got := roundTrip(t, path, want)
	if !reflect.DeepEqual(got, expected) {
		t.Fatalf("asset round trip mismatch:\n got: %+v\nwant: %+v", got, expected)
	}
}

func TestRoundTripTimelineIndex(t *testing.T) {
	path := filepath.Join(t.TempDir(), "timeline.parquet")
	want := sampleTimelineRows(4)

	wire, _ := json.Marshal(want)
	var expected []TimelineIndexRow
	if err := json.Unmarshal(wire, &expected); err != nil {
		t.Fatal(err)
	}

	got := roundTrip(t, path, want)
	if !reflect.DeepEqual(got, expected) {
		t.Fatalf("timeline_index round trip mismatch:\n got: %+v\nwant: %+v", got, expected)
	}
}

func TestRoundTripAlbumIndex(t *testing.T) {
	path := filepath.Join(t.TempDir(), "albums.parquet")
	want := sampleAlbumRows()

	wire, _ := json.Marshal(want)
	var expected []AlbumIndexRow
	if err := json.Unmarshal(wire, &expected); err != nil {
		t.Fatal(err)
	}

	got := roundTrip(t, path, want)
	if !reflect.DeepEqual(got, expected) {
		t.Fatalf("album_index round trip mismatch:\n got: %+v\nwant: %+v", got, expected)
	}
}

func TestParquetMagic(t *testing.T) {
	path := filepath.Join(t.TempDir(), "assets.parquet")
	roundTrip(t, path, sampleAssetRows())

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(data) < 8 {
		t.Fatalf("file too short: %d bytes", len(data))
	}
	if string(data[:4]) != "PAR1" {
		t.Fatalf("file does not start with PAR1 magic: %q", data[:4])
	}
	if string(data[len(data)-4:]) != "PAR1" {
		t.Fatalf("file does not end with PAR1 magic: %q", data[len(data)-4:])
	}
}

func TestReadPaging(t *testing.T) {
	path := filepath.Join(t.TempDir(), "timeline.parquet")
	all := sampleTimelineRows(10)
	if _, _, err := writeParquetFile(path, all); err != nil {
		t.Fatalf("writeParquetFile: %v", err)
	}

	cases := []struct {
		name         string
		offset       int
		limit        int
		wantStartIdx int
		wantLen      int
	}{
		{"all", 0, 0, 0, 10},
		{"first page", 0, 3, 0, 3},
		{"middle page", 3, 4, 3, 4},
		{"tail partial", 8, 10, 8, 2},
		{"exact end", 10, 5, 10, 0},
		{"past end", 25, 5, 10, 0},
		{"negative offset", -2, 2, 0, 2},
		{"negative limit means all", 5, -1, 5, 5},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := readParquetFile[TimelineIndexRow](path, tc.offset, tc.limit)
			if err != nil {
				t.Fatalf("readParquetFile: %v", err)
			}
			if got == nil {
				t.Fatal("rows slice is nil; must be non-nil so JSON encodes []")
			}
			if len(got) != tc.wantLen {
				t.Fatalf("len=%d, want %d", len(got), tc.wantLen)
			}
			for i, row := range got {
				want := all[tc.wantStartIdx+i]
				if row != want {
					t.Fatalf("row %d = %+v, want %+v", i, row, want)
				}
			}
		})
	}
}

func TestReadMissingFile(t *testing.T) {
	_, err := readParquetFile[AssetRow](filepath.Join(t.TempDir(), "nope.parquet"), 0, 0)
	if err == nil {
		t.Fatal("expected error reading missing file")
	}
	if !strings.Contains(err.Error(), "no such file") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestWriteOverwriteSameContent(t *testing.T) {
	// Writing twice must overwrite atomically; second write replaces content.
	dir := t.TempDir()
	path := filepath.Join(dir, "albums.parquet")

	if _, _, err := writeParquetFile(path, sampleAlbumRows()); err != nil {
		t.Fatal(err)
	}
	short := sampleAlbumRows()[:1]
	if _, _, err := writeParquetFile(path, short); err != nil {
		t.Fatal(err)
	}
	got, err := readParquetFile[AlbumIndexRow](path, 0, 0)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got, short) {
		t.Fatalf("overwrite mismatch: got %+v want %+v", got, short)
	}
	// No temp files may be left behind.
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".tmp") {
			t.Fatalf("leftover temp file: %s", e.Name())
		}
	}
}

func TestEmptyWrite(t *testing.T) {
	path := filepath.Join(t.TempDir(), "empty.parquet")
	n, _, err := writeParquetFile(path, []AssetRow{})
	if err != nil {
		t.Fatalf("writeParquetFile empty: %v", err)
	}
	if n != 0 {
		t.Fatalf("rows=%d, want 0", n)
	}
	got, err := readParquetFile[AssetRow](path, 0, 0)
	if err != nil {
		t.Fatalf("readParquetFile empty: %v", err)
	}
	if got == nil || len(got) != 0 {
		t.Fatalf("got %v, want non-nil empty slice", got)
	}
}

// TestProtocolLoop exercises the in-process stdio loop end to end, including
// error paths, and verifies the process keeps answering after failures.
func TestProtocolLoop(t *testing.T) {
	dir := t.TempDir()
	assetPath := filepath.Join(dir, "assets.parquet")

	rowsJSON, _ := json.Marshal(sampleAssetRows())
	writeReq := fmt.Sprintf(`{"cmd":"write","path":%q,"kind":"asset","rows":%s}`, assetPath, rowsJSON)
	readReq := fmt.Sprintf(`{"cmd":"read","path":%q,"kind":"asset","offset":1,"limit":1}`, assetPath)
	readAllReq := fmt.Sprintf(`{"cmd":"read","path":%q,"kind":"asset"}`, assetPath)
	missingReq := fmt.Sprintf(`{"cmd":"read","path":%q,"kind":"asset"}`, filepath.Join(dir, "missing.parquet"))

	input := strings.Join([]string{
		`{"cmd":"ping"}`,
		`{"cmd":"bogus"}`,
		`not json`,
		writeReq,
		readReq,
		readAllReq,
		missingReq,
		`{"cmd":"write","path":"relative/path.parquet","kind":"asset","rows":[]}`,
		`{"cmd":"ping"}`,
	}, "\n") + "\n"

	var out bytes.Buffer
	if err := run(strings.NewReader(input), &out); err != nil {
		t.Fatalf("run: %v", err)
	}

	lines := strings.Split(strings.TrimRight(out.String(), "\n"), "\n")
	if len(lines) != 9 {
		t.Fatalf("got %d response lines, want 9:\n%s", len(lines), out.String())
	}

	type resp struct {
		OK      bool            `json:"ok"`
		Version string          `json:"version"`
		Rows    json.RawMessage `json:"rows"`
		SHA256  string          `json:"sha256"`
		Error   string          `json:"error"`
	}
	decode := func(i int) resp {
		var r resp
		if err := json.Unmarshal([]byte(lines[i]), &r); err != nil {
			t.Fatalf("line %d not valid JSON: %v (%q)", i, err, lines[i])
		}
		return r
	}

	if r := decode(0); !r.OK || r.Version != "1" {
		t.Fatalf("ping response: %+v", r)
	}
	if r := decode(1); r.OK || !strings.Contains(r.Error, "unknown command") {
		t.Fatalf("unknown cmd response: %+v", r)
	}
	if r := decode(2); r.OK || !strings.Contains(r.Error, "invalid request JSON") {
		t.Fatalf("bad JSON response: %+v", r)
	}
	if r := decode(3); !r.OK || string(r.Rows) != "3" || len(r.SHA256) != 64 {
		t.Fatalf("write response: %+v", r)
	}
	// Paged read: exactly one row, the second asset.
	var page []AssetRow
	if r := decode(4); !r.OK {
		t.Fatalf("paged read failed: %+v", r)
	} else if err := json.Unmarshal(r.Rows, &page); err != nil {
		t.Fatalf("decoding paged rows: %v", err)
	}
	wantWire, _ := json.Marshal(sampleAssetRows())
	var wantAll []AssetRow
	json.Unmarshal(wantWire, &wantAll)
	if len(page) != 1 || !reflect.DeepEqual(page[0], wantAll[1]) {
		t.Fatalf("paged read got %+v, want [%+v]", page, wantAll[1])
	}
	// Full read: all rows in order.
	var all []AssetRow
	if r := decode(5); !r.OK {
		t.Fatalf("read failed: %+v", r)
	} else if err := json.Unmarshal(r.Rows, &all); err != nil {
		t.Fatalf("decoding rows: %v", err)
	}
	if !reflect.DeepEqual(all, wantAll) {
		t.Fatalf("full read mismatch:\n got: %+v\nwant: %+v", all, wantAll)
	}
	if r := decode(6); r.OK || r.Error == "" {
		t.Fatalf("missing file response: %+v", r)
	}
	if r := decode(7); r.OK || !strings.Contains(r.Error, "not absolute") {
		t.Fatalf("relative path response: %+v", r)
	}
	if r := decode(8); !r.OK || r.Version != "1" {
		t.Fatalf("final ping response (process must stay alive): %+v", r)
	}

	// Empty-row write must encode "rows":[] (not null) on read back.
	emptyPath := filepath.Join(dir, "empty.parquet")
	input2 := fmt.Sprintf("{\"cmd\":\"write\",\"path\":%q,\"kind\":\"album_index\",\"rows\":[]}\n{\"cmd\":\"read\",\"path\":%q,\"kind\":\"album_index\"}\n", emptyPath, emptyPath)
	var out2 bytes.Buffer
	if err := run(strings.NewReader(input2), &out2); err != nil {
		t.Fatalf("run: %v", err)
	}
	if !strings.Contains(out2.String(), `"rows":[]`) {
		t.Fatalf("empty read must encode rows as []: %s", out2.String())
	}
}

// TestStdioIntegration builds the real binary, spawns it as a subprocess, and
// drives the documented protocol over its stdin/stdout pipes.
func TestStdioIntegration(t *testing.T) {
	bin := filepath.Join(t.TempDir(), "fpparquet")
	build := exec.Command("go", "build", "-trimpath", "-o", bin, ".")
	build.Env = append(os.Environ(), "CGO_ENABLED=0")
	if out, err := build.CombinedOutput(); err != nil {
		t.Fatalf("go build: %v\n%s", err, out)
	}

	dir := t.TempDir()
	assetPath := filepath.Join(dir, "partitions", "assets.parquet")

	cmd := exec.Command(bin)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}

	enc := json.NewEncoder(stdin)
	dec := json.NewDecoder(stdout)

	type resp struct {
		OK      bool            `json:"ok"`
		Version string          `json:"version"`
		Rows    json.RawMessage `json:"rows"`
		SHA256  string          `json:"sha256"`
		Error   string          `json:"error"`
	}
	roundTripRPC := func(req any) resp {
		t.Helper()
		if err := enc.Encode(req); err != nil {
			t.Fatalf("sending request: %v", err)
		}
		var r resp
		if err := dec.Decode(&r); err != nil {
			t.Fatalf("reading response: %v (stderr: %s)", err, stderr.String())
		}
		return r
	}

	// 1. ping
	if r := roundTripRPC(map[string]any{"cmd": "ping"}); !r.OK || r.Version != "1" {
		t.Fatalf("ping: %+v", r)
	}

	// 2. write
	assets := sampleAssetRows()
	wr := roundTripRPC(map[string]any{
		"cmd":  "write",
		"path": assetPath,
		"kind": "asset",
		"rows": assets,
	})
	if !wr.OK || string(wr.Rows) != "3" {
		t.Fatalf("write: %+v", wr)
	}
	data, err := os.ReadFile(assetPath)
	if err != nil {
		t.Fatalf("written file: %v", err)
	}
	if string(data[:4]) != "PAR1" {
		t.Fatalf("missing PAR1 magic: %q", data[:4])
	}
	sum := sha256.Sum256(data)
	if wr.SHA256 != hex.EncodeToString(sum[:]) {
		t.Fatalf("sha256 mismatch: response %q file %q", wr.SHA256, hex.EncodeToString(sum[:]))
	}

	// 3. read all
	rr := roundTripRPC(map[string]any{
		"cmd":  "read",
		"path": assetPath,
		"kind": "asset",
	})
	var got []AssetRow
	if !rr.OK {
		t.Fatalf("read: %+v", rr)
	}
	if err := json.Unmarshal(rr.Rows, &got); err != nil {
		t.Fatal(err)
	}
	wantWire, _ := json.Marshal(assets)
	var want []AssetRow
	json.Unmarshal(wantWire, &want)
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("stdio round trip mismatch:\n got: %+v\nwant: %+v", got, want)
	}

	// 4. paged read
	pr := roundTripRPC(map[string]any{
		"cmd":    "read",
		"path":   assetPath,
		"kind":   "asset",
		"offset": 2,
		"limit":  1,
	})
	var page []AssetRow
	if !pr.OK {
		t.Fatalf("paged read: %+v", pr)
	}
	if err := json.Unmarshal(pr.Rows, &page); err != nil {
		t.Fatal(err)
	}
	if len(page) != 1 || !reflect.DeepEqual(page[0], want[2]) {
		t.Fatalf("paged read got %+v, want [%+v]", page, want[2])
	}

	// 5. missing file must report ok:false without killing the process
	mr := roundTripRPC(map[string]any{
		"cmd":  "read",
		"path": filepath.Join(dir, "does-not-exist.parquet"),
		"kind": "asset",
	})
	if mr.OK || mr.Error == "" {
		t.Fatalf("missing file: %+v", mr)
	}

	// 6. still alive after errors
	if r := roundTripRPC(map[string]any{"cmd": "ping"}); !r.OK {
		t.Fatalf("ping after error: %+v", r)
	}

	// Closing stdin must terminate the process with exit code 0.
	stdin.Close()
	if err := cmd.Wait(); err != nil {
		t.Fatalf("process did not exit cleanly: %v (stderr: %s)", err, stderr.String())
	}
	if stderr.Len() != 0 {
		t.Fatalf("unexpected stderr output: %s", stderr.String())
	}
}
