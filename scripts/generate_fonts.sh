#!/usr/bin/env bash
set -euo pipefail

# Regenerate the round display's fonts from the fonts bundled with LVGL.
#
# moto_font_latin_*: the same Montserrat options LVGL uses for its built-in
#   lv_font_montserrat_* (see their "Opts:" headers), widened from ASCII to
#   Latin-1 so pt-BR text keeps its accents. The 16 and 20 px sizes fall back
#   to moto_font_cjk_16 for Chinese text.
# moto_font_cjk_16: every CJK character used by the device catalog
#   (scripts/i18n/build_catalog.py writes the list). It falls back to LVGL's
#   1,434-glyph lv_font_source_han_sans_sc_16_cjk for free text such as track
#   titles sent by the phone.

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
font_dir="third_party/lvgl/scripts/built_in_font"
asset_dir="shared/nav_ui/assets"
cjk_symbols="$(tr -d '\n' < shared/i18n/generated/device_cjk_symbols.txt)"

cd "${repo_dir}"

# Pinned converter; its dependencies are bundled and it has no install scripts.
lv_font_conv() {
  npm_config_ignore_scripts=true npx --yes lv_font_conv@1.5.3 "$@"
}

for size in 16 20 28 48; do
  fallback=()
  if [[ "${size}" == 16 || "${size}" == 20 ]]; then
    fallback=(--lv-fallback moto_font_cjk_16)
  fi
  lv_font_conv \
    --no-compress --no-prefilter --bpp 4 --size "${size}" \
    --font "${font_dir}/Montserrat-Medium.ttf" -r 0x20-0x7F,0xA0-0xFF \
    --format lvgl --force-fast-kern-format \
    --lv-font-name "moto_font_latin_${size}" ${fallback[@]+"${fallback[@]}"} \
    -o "${asset_dir}/moto_font_latin_${size}.c"
done

lv_font_conv \
  --no-compress --no-prefilter --bpp 4 --size 16 \
  --font "${font_dir}/SourceHanSansSC-Normal.otf" --symbols "${cjk_symbols}" \
  --format lvgl \
  --lv-font-name moto_font_cjk_16 \
  --lv-fallback lv_font_source_han_sans_sc_16_cjk \
  -o "${asset_dir}/moto_font_cjk_16.c"
