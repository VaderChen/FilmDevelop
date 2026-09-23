#!/bin/bash
set -euo pipefail
# The visible build is HHmm; Apple's numeric build uses minute-of-day + 1.
# Keep both from one timestamp, including builds that cross midnight.
version_stamp="${PHOTO_STYLE_BUILD_STAMP:-$(TZ=Asia/Taipei /bin/date +%Y%m%d%H%M)}"
[[ "$version_stamp" =~ ^20[0-9]{10}$ ]] || { printf 'Invalid build timestamp\n' >&2; exit 1; }
version_year="${version_stamp:2:2}"
version_date="${version_stamp:4:4}"
version_time="${version_stamp:8:4}"
version_number=$((10#${version_time:0:2} * 60 + 10#${version_time:2:2} + 1))
version_plist="${TARGET_BUILD_DIR:?}/${INFOPLIST_PATH:?}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 1.$version_year.$version_date" "$version_plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version_number" "$version_plist"
/usr/libexec/PlistBuddy -c 'Delete :PhotoStyleBuildTime' "$version_plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :PhotoStyleBuildTime string $version_time" "$version_plist"
printf 'App version: 1.%s.%s build %s\n' "$version_year" "$version_date" "$version_time"
