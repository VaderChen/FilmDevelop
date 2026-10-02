package exifmeta

import (
	"encoding/binary"
	"math"
)

type field struct {
	name      string
	tag, kind uint16
}

var rootFields = []field{{"ImageDescription", 270, 2}, {"Make", 271, 2}, {"Model", 272, 2}, {"Software", 305, 2}, {"DateTime", 306, 2}, {"Artist", 315, 2}, {"Copyright", 33432, 2}}
var photoFields = []field{
	{"ExposureTime", 33434, 5}, {"FNumber", 33437, 5}, {"ExposureProgram", 34850, 3}, {"SpectralSensitivity", 34852, 2}, {"ISOSpeedRatings", 34855, 3}, {"SensitivityType", 34864, 3}, {"StandardOutputSensitivity", 34865, 4}, {"RecommendedExposureIndex", 34866, 4}, {"ISOSpeed", 34867, 4},
	{"DateTimeOriginal", 36867, 2}, {"DateTimeDigitized", 36868, 2}, {"OffsetTime", 36880, 2}, {"OffsetTimeOriginal", 36881, 2}, {"OffsetTimeDigitized", 36882, 2},
	{"ShutterSpeedValue", 37377, 10}, {"ApertureValue", 37378, 5}, {"BrightnessValue", 37379, 10}, {"ExposureBiasValue", 37380, 10}, {"MaxApertureValue", 37381, 5}, {"SubjectDistance", 37382, 5}, {"MeteringMode", 37383, 3}, {"LightSource", 37384, 3}, {"Flash", 37385, 3}, {"FocalLength", 37386, 5},
	{"SubsecTime", 37520, 2}, {"SubsecTimeOriginal", 37521, 2}, {"SubsecTimeDigitized", 37522, 2}, {"FocalPlaneXResolution", 41486, 5}, {"FocalPlaneYResolution", 41487, 5}, {"FocalPlaneResolutionUnit", 41488, 3}, {"SensingMethod", 41495, 3},
	{"CustomRendered", 41985, 3}, {"ExposureMode", 41986, 3}, {"WhiteBalance", 41987, 3}, {"DigitalZoomRatio", 41988, 5}, {"FocalLenIn35mmFilm", 41989, 3}, {"SceneCaptureType", 41990, 3}, {"GainControl", 41991, 3}, {"Contrast", 41992, 3}, {"Saturation", 41993, 3}, {"Sharpness", 41994, 3}, {"SubjectDistanceRange", 41996, 3},
	{"ImageUniqueID", 42016, 2}, {"CameraOwnerName", 42032, 2}, {"BodySerialNumber", 42033, 2}, {"LensSpecification", 42034, 5}, {"LensMake", 42035, 2}, {"LensModel", 42036, 2}, {"LensSerialNumber", 42037, 2},
}
var gpsFields = []field{{"Version", 0, 1}, {"LatitudeRef", 1, 2}, {"Latitude", 2, 5}, {"LongitudeRef", 3, 2}, {"Longitude", 4, 5}, {"AltitudeRef", 5, 1}, {"Altitude", 6, 5}, {"TimeStamp", 7, 5}, {"Satellites", 8, 2}, {"Status", 9, 2}, {"MeasureMode", 10, 2}, {"DOP", 11, 5}, {"SpeedRef", 12, 2}, {"Speed", 13, 5}, {"TrackRef", 14, 2}, {"Track", 15, 5}, {"ImgDirectionRef", 16, 2}, {"ImgDirection", 17, 5}, {"MapDatum", 18, 2}, {"DateStamp", 29, 2}, {"Differential", 30, 3}, {"HPositioningError", 31, 5}}

// Native 是非標準 RAW／HEIF 容器的備援；標準 EXIF 優先保留原始位元組。
func (m *Metadata) FillProperties(properties map[string]any) {
	if m.root == nil {
		*m = empty()
	}
	groups := []map[string]any{properties}
	for _, name := range []string{"{TIFF}", "{Exif}", "{ExifAux}"} {
		if group, ok := properties[name].(map[string]any); ok {
			groups = append(groups, group)
		}
	}
	for _, group := range groups {
		for _, set := range []struct {
			fields []field
			target directory
		}{{rootFields, m.root}, {photoFields, m.photo}} {
			for _, f := range set.fields {
				if _, ok := set.target[f.tag]; ok {
					continue
				}
				v := group[f.name]
				if v == nil && f.name == "BodySerialNumber" {
					v = group["SerialNumber"]
				}
				if v == nil && f.name == "LensSpecification" {
					v = group["LensInfo"]
				}
				if e, ok := propertyEntry(f, v, m.order); ok {
					set.target[f.tag] = e
				}
			}
		}
	}
	if group, ok := properties["{GPS}"].(map[string]any); ok {
		for _, f := range gpsFields {
			if _, ok := m.gps[f.tag]; ok {
				continue
			}
			v := group[f.name]
			if f.tag == 2 || f.tag == 4 {
				if value, ok := v.(float64); ok {
					value = math.Abs(value)
					degrees := math.Floor(value)
					minutes := math.Floor((value - degrees) * 60)
					v = []any{degrees, minutes, ((value-degrees)*60 - minutes) * 60}
				}
			}
			if e, ok := propertyEntry(f, v, m.order); ok {
				m.gps[f.tag] = e
			}
		}
	}
}
func propertyEntry(f field, value any, order binary.ByteOrder) (entry, bool) {
	e := entry{tag: f.tag, kind: f.kind}
	if value == nil {
		return e, false
	}
	if f.kind == 2 {
		s, ok := value.(string)
		if !ok || len(s) == 0 || len(s) > 65500 {
			return e, false
		}
		e.data = append([]byte(s), 0)
		e.count = uint32(len(e.data))
		return e, true
	}
	values, ok := value.([]any)
	if !ok {
		values = []any{value}
	}
	if len(values) > 4096 {
		return e, false
	}
	for _, v := range values {
		n, ok := v.(float64)
		if !ok || math.IsNaN(n) || math.IsInf(n, 0) {
			return e, false
		}
		b := make([]byte, typeSize[f.kind])
		switch f.kind {
		case 1:
			if n < 0 || n > 255 {
				return e, false
			}
			b[0] = byte(n)
		case 3:
			if n < 0 || n > 65535 {
				return e, false
			}
			order.PutUint16(b, uint16(n))
		case 4:
			if n < 0 || n > 0xffffffff {
				return e, false
			}
			order.PutUint32(b, uint32(n))
		case 5, 10:
			limit := float64(0xffffffff)
			if f.kind == 10 {
				limit = 0x7fffffff
			}
			if math.Abs(n) > limit || f.kind == 5 && n < 0 {
				return e, false
			}
			denominator := int64(1000000)
			if math.Abs(n) > limit/float64(denominator) {
				denominator = 1
			}
			numerator := int64(math.Round(n * float64(denominator)))
			a := numerator
			if a < 0 {
				a = -a
			}
			d := denominator
			for d != 0 {
				a, d = d, a%d
			}
			if a != 0 {
				numerator /= a
				denominator /= a
			}
			order.PutUint32(b, uint32(numerator))
			order.PutUint32(b[4:], uint32(denominator))
		default:
			return e, false
		}
		e.data = append(e.data, b...)
	}
	e.count = uint32(len(values))
	return e, e.count > 0
}
