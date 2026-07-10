#!/bin/zsh
# Compila DevSpaces.swift e monta ~/Applications/DevSpaces.app (idempotente).

emulate -LR zsh
set -e

readonly SRC_DIR="${0:A:h}"
readonly APP_DIR="$HOME/Applications/DevSpaces.app"
readonly BIN="$APP_DIR/Contents/MacOS/DevSpaces"

cd "$SRC_DIR"
[[ -f DevSpaces.swift ]] || { print -u2 "build: DevSpaces.swift não existe"; exit 1 }

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

# O CommandLineTools deste Mac tem modulemaps duplicados (module.modulemap de
# 2023 + bridging.modulemap de 2024, ambos definindo SwiftBridging), o que
# quebra QUALQUER swiftc. O overlay abaixo mascara o modulemap velho sem tocar
# no sistema. Fix definitivo (opcional, requer sudo):
#   sudo rm /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap
readonly OVERLAY="$SRC_DIR/.clt-fix-overlay.yaml"
readonly EMPTY_MAP="$SRC_DIR/.empty.modulemap"
: > "$EMPTY_MAP"
cat > "$OVERLAY" <<OVERLAY_EOF
{
  "version": 0,
  "case-sensitive": "false",
  "use-external-names": false,
  "roots": [
    {
      "type": "directory",
      "name": "/Library/Developer/CommandLineTools/usr/include/swift",
      "contents": [
        { "type": "file", "name": "module.modulemap", "external-contents": "$EMPTY_MAP" }
      ]
    }
  ]
}
OVERLAY_EOF

print "▶ compilando DevSpaces.swift…"
swiftc -O -target arm64-apple-macosx14.0 \
  -vfsoverlay "$OVERLAY" -Xcc -ivfsoverlay -Xcc "$OVERLAY" \
  DevSpaces.swift -o "$BIN"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>DevSpaces</string>
	<key>CFBundleIdentifier</key>
	<string>com.raphael.devspaces</string>
	<key>CFBundleName</key>
	<string>DevSpaces</string>
	<key>CFBundleDisplayName</key>
	<string>DevSpaces</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSAppleEventsUsageDescription</key>
	<string>DevSpaces controla o Ghostty para abrir e focar workspaces.</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

# Assinatura ESTÁVEL: com identidade fixa a permissão de Acessibilidade (TCC)
# sobrevive a recompilações. Ad-hoc muda o hash a cada build e o macOS mostra
# o toggle ligado mas ignora a permissão. Criar a identidade (uma vez):
#   openssl req -x509 ... -subj "/CN=DevSpaces Signing" (ver README)
if security find-identity -v -p codesigning 2>/dev/null | grep -q "DevSpaces Signing"; then
  print "▶ assinando (DevSpaces Signing)…"
  codesign --force --sign "DevSpaces Signing" "$APP_DIR"
else
  print "▶ assinando (ad-hoc — permissões TCC caem a cada rebuild)…"
  codesign --force --sign - "$APP_DIR"
fi

print "✔ pronto: $APP_DIR"
