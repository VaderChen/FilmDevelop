package application

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"reflect"
	"sort"
	"strconv"
	"strings"

	"github.com/VaderChen/FilmDevelop/internal/contract"
)

func (a *App) showEXIF(path string) error {
	data, err := a.services.Native(a.ctx, "metadata", contract.FileRequest{Path: path}, nil)
	if err != nil {
		return err
	}
	var properties object
	if err = json.Unmarshal(data, &properties); err != nil {
		return err
	}
	a.reply("handlePhotoEXIF", object{"filename": filepath.Base(path), "groups": metadataGroups(properties)})
	return nil
}
func metadataGroups(properties object) []object {
	labels := map[string]string{"Make": "相機廠牌", "Model": "相機型號", "LensModel": "鏡頭型號", "DateTimeOriginal": "拍攝時間", "ExposureTime": "曝光時間", "FNumber": "光圈", "ISOSpeedRatings": "ISO", "FocalLength": "焦距", "ExposureBiasValue": "曝光補償", "DateTime": "修改時間", "DateTimeDigitized": "數位化時間", "Software": "軟體版本", "BodySerialNumber": "機身序號", "LensSerialNumber": "鏡頭序號", "LensMake": "鏡頭廠牌", "Orientation": "影像方向", "Compression": "壓縮格式", "ColorSpace": "色彩空間", "Flash": "閃光燈", "MeteringMode": "測光模式", "ExposureProgram": "曝光模式", "WhiteBalance": "白平衡", "ShutterSpeedValue": "快門值（APEX）", "ApertureValue": "光圈值（APEX）", "BrightnessValue": "亮度值", "FocalLenIn35mmFilm": "35mm 等效焦距"}
	groups := map[string][]object{}
	seen := map[string][]any{}
	if w, ok := properties["PixelWidth"]; ok {
		groups["影像資訊"] = append(groups["影像資訊"], object{"label": "影像尺寸", "value": fmt.Sprintf("%v × %v px", w, properties["PixelHeight"])})
	}
	for _, group := range []string{"{TIFF}", "{Exif}", "{ExifAux}", "{GPS}"} {
		fields, _ := properties[group].(object)
		keys := []string{}
		for k := range fields {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, originalKey := range keys {
			value := fields[originalKey]
			key := originalKey
			if group == "{ExifAux}" {
				switch key {
				case "LensInfo":
					key = "LensSpecification"
				case "SerialNumber":
					key = "BodySerialNumber"
				}
			}
			identity := "EXIF:" + key
			if group == "{GPS}" {
				identity = "GPS:" + key
			}
			duplicate := false
			for _, v := range seen[identity] {
				if reflect.DeepEqual(v, value) {
					duplicate = true
				}
			}
			if duplicate {
				continue
			}
			seen[identity] = append(seen[identity], value)
			formatted, ok := metadataValue(value)
			if !ok {
				continue
			}
			if n, ok := value.(float64); ok {
				switch key {
				case "ExposureTime":
					if n > 0 && n < 1 {
						formatted = fmt.Sprintf("1/%.0f s", 1/n)
					} else {
						formatted += " s"
					}
				case "FNumber":
					formatted = "f/" + formatted
				case "FocalLength":
					formatted += " mm"
				}
			}
			category := "其他資訊"
			switch {
			case group == "{GPS}":
				category = "GPS"
			case strings.Contains(key, "Date") || strings.Contains(key, "OffsetTime") || strings.Contains(key, "SubsecTime"):
				category = "日期與時間"
			case key == "Make" || key == "Model" || key == "Software" || strings.Contains(key, "Lens") || strings.Contains(key, "Serial") || strings.Contains(key, "Owner"):
				category = "相機與鏡頭"
			case contains(strings.Fields("Compression Orientation PhotometricInterpretation ColorSpace ComponentsConfiguration CFAPattern PixelXDimension PixelYDimension XResolution YResolution ResolutionUnit ExifVersion FlashPixVersion CompressedBitsPerPixel"), key):
				category = "影像資訊"
			case group == "{Exif}":
				category = "拍攝設定"
			}
			label := labels[key]
			if label == "" {
				label = key
			}
			groups[category] = append(groups[category], object{"label": label, "value": formatted})
		}
	}
	result := []object{}
	for _, title := range []string{"相機與鏡頭", "拍攝設定", "日期與時間", "影像資訊", "GPS", "其他資訊"} {
		if len(groups[title]) > 0 {
			result = append(result, object{"title": title, "rows": groups[title]})
		}
	}
	return result
}
func metadataValue(value any) (string, bool) {
	switch v := value.(type) {
	case string:
		r := []rune(v)
		if len(r) > 4096 {
			r = r[:4096]
		}
		return string(r), true
	case float64:
		return strconv.FormatFloat(v, 'f', -1, 64), true
	case []any:
		parts := []string{}
		for i, x := range v {
			if i >= 32 {
				break
			}
			p, ok := metadataValue(x)
			if ok {
				parts = append(parts, p)
			}
		}
		return strings.Join(parts, ", "), true
	}
	return "", false
}
