#!/bin/zsh
# Renders background.html into the 1x and 2x pictures dmgbuild puts behind the DMG window.
# Only needed after editing background.html; the PNGs are committed.
set -e
DIR=${0:A:h}
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
for scale in 1 2; do
  out="$DIR/background.png"; [ $scale = 2 ] && out="$DIR/background@2x.png"
  "$CHROME" --headless --disable-gpu --hide-scrollbars --virtual-time-budget=5000 \
    --force-device-scale-factor=$scale --window-size=640,400 \
    --screenshot="$out" "file://$DIR/background.html" 2>/dev/null
done
sips -g pixelWidth -g pixelHeight "$DIR/background.png" "$DIR/background@2x.png" | grep pixel
