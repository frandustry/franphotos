package main

// Row schemas for the three parquet partition kinds understood by fpparquet.
//
// Parquet column names are snake_case and match the JSON field names exactly.
// Nullable fields use Go pointers: JSON null/absent maps to a nil pointer on
// write, and a nil pointer comes back as JSON null on read. Pointer fields
// carry the `optional` parquet tag; required fields do not.

// AssetRow is one row of an "asset" partition file.
type AssetRow struct {
	UUID                  string   `parquet:"uuid" json:"uuid"`
	MediaType             string   `parquet:"media_type" json:"media_type"` // "photo" | "video"
	CapturedAt            int64    `parquet:"captured_at" json:"captured_at"`
	CapturedAtTZ          *int32   `parquet:"captured_at_tz,optional" json:"captured_at_tz"`
	AddedAt               int64    `parquet:"added_at" json:"added_at"`
	DurationMs            *int32   `parquet:"duration_ms,optional" json:"duration_ms"`
	Width                 int32    `parquet:"width" json:"width"`
	Height                int32    `parquet:"height" json:"height"`
	FileSize              int64    `parquet:"file_size" json:"file_size"`
	SHA256                string   `parquet:"sha256" json:"sha256"`
	OriginalRelpath       string   `parquet:"original_relpath" json:"original_relpath"`
	Filename              string   `parquet:"filename" json:"filename"`
	UTI                   string   `parquet:"uti" json:"uti"`
	Title                 *string  `parquet:"title,optional" json:"title"`
	Caption               *string  `parquet:"caption,optional" json:"caption"`
	IsFavorite            bool     `parquet:"is_favorite" json:"is_favorite"`
	IsHidden              bool     `parquet:"is_hidden" json:"is_hidden"`
	IsDeleted             bool     `parquet:"is_deleted" json:"is_deleted"`
	DeletedAt             *int64   `parquet:"deleted_at,optional" json:"deleted_at"`
	Rating                int32    `parquet:"rating" json:"rating"`
	CameraMake            *string  `parquet:"camera_make,optional" json:"camera_make"`
	CameraModel           *string  `parquet:"camera_model,optional" json:"camera_model"`
	LensModel             *string  `parquet:"lens_model,optional" json:"lens_model"`
	ISO                   *int32   `parquet:"iso,optional" json:"iso"`
	Aperture              *float64 `parquet:"aperture,optional" json:"aperture"`
	ShutterSpeed          *float64 `parquet:"shutter_speed,optional" json:"shutter_speed"`
	FocalLength           *float64 `parquet:"focal_length,optional" json:"focal_length"`
	Latitude              *float64 `parquet:"latitude,optional" json:"latitude"`
	Longitude             *float64 `parquet:"longitude,optional" json:"longitude"`
	Altitude              *float64 `parquet:"altitude,optional" json:"altitude"`
	HDRType               string   `parquet:"hdr_type" json:"hdr_type"` // "sdr" | "gainmap" | "hlg" | "pq"
	IsLivePhoto           bool     `parquet:"is_live_photo" json:"is_live_photo"`
	LivePhotoVideoRelpath *string  `parquet:"live_photo_video_relpath,optional" json:"live_photo_video_relpath"`
	LivePhotoStillTimeMs  *int32   `parquet:"live_photo_still_time_ms,optional" json:"live_photo_still_time_ms"`
	VideoCodec            *string  `parquet:"video_codec,optional" json:"video_codec"`
	ColorSpace            *string  `parquet:"color_space,optional" json:"color_space"`
	HasAudio              *bool    `parquet:"has_audio,optional" json:"has_audio"`
	FrameRate             *float64 `parquet:"frame_rate,optional" json:"frame_rate"`
	EditVersion           int32    `parquet:"edit_version" json:"edit_version"`
	AlbumSortIndex        int32    `parquet:"album_sort_index" json:"album_sort_index"`
}

// TimelineIndexRow is one row of a "timeline_index" partition file.
type TimelineIndexRow struct {
	Month         string `parquet:"month" json:"month"` // e.g. "2025-03"
	RowCount      int32  `parquet:"row_count" json:"row_count"`
	FirstCaptured int64  `parquet:"first_captured" json:"first_captured"`
	LastCaptured  int64  `parquet:"last_captured" json:"last_captured"`
	CoverUUID     string `parquet:"cover_uuid" json:"cover_uuid"`
	SHA256        string `parquet:"sha256" json:"sha256"`
}

// AlbumIndexRow is one row of an "album_index" partition file.
type AlbumIndexRow struct {
	AlbumUUID string `parquet:"album_uuid" json:"album_uuid"`
	Name      string `parquet:"name" json:"name"`
	AlbumType string `parquet:"album_type" json:"album_type"` // "manual" | "smart" | "builtin"
	RowCount  int32  `parquet:"row_count" json:"row_count"`
	CoverUUID string `parquet:"cover_uuid" json:"cover_uuid"`
	SHA256    string `parquet:"sha256" json:"sha256"`
}
