#!/usr/bin/env bash
# Ajusta la carpeta android que genera «flutter create» en el CI (el repo no la versiona). Lo usan los tres flujos que
# compilan: el canal de prueba (build-apk.yml), el de producción (aolab-android-prod/build-prod.yml) y la verificación.
#
#   bash tool/configurar_android.sh <applicationId> "<nombre visible>"
#
# - applicationId y nombre del canal (cl.makki.aolab = producción, cl.makki.aolab.test = prueba).
# - Permisos de red y micrófono (audios de evidencia).
# - Entrar con Microsoft (flutter_appauth): el retorno msauth://<paquete>/<firma> lo recibe la actividad de AppAuth, que
#   necesita appAuthRedirectScheme; y la actividad principal no puede llevar taskAffinity="" (con él, el navegador no
#   vuelve a la app). Más las consultas de paquetes para abrir el navegador en Android 11 o más.
# Es idempotente: correrlo dos veces deja lo mismo.
set -euo pipefail
APP_ID=${1:?applicationId}
NOMBRE=${2:?nombre visible}
cd "$(dirname "$0")/.."
GRADLE_KTS=android/app/build.gradle.kts
GRADLE=android/app/build.gradle
MANIFEST=android/app/src/main/AndroidManifest.xml
[ -f "$MANIFEST" ] || { echo "Falta $MANIFEST: corre antes flutter create" >&2; exit 1; }

if [ -f "$GRADLE_KTS" ]; then
  sed -i -E "s/applicationId = \"[^\"]+\"/applicationId = \"$APP_ID\"/" "$GRADLE_KTS"
  grep -q appAuthRedirectScheme "$GRADLE_KTS" || \
    sed -i -E 's/^(\s*)defaultConfig \{/\1defaultConfig {\n\1    manifestPlaceholders["appAuthRedirectScheme"] = "msauth"/' "$GRADLE_KTS"
  grep -q 'manifestPlaceholders\["appAuthRedirectScheme"\] = "msauth"' "$GRADLE_KTS"
elif [ -f "$GRADLE" ]; then
  sed -i -E "s/applicationId \"[^\"]+\"/applicationId \"$APP_ID\"/" "$GRADLE"
  grep -q appAuthRedirectScheme "$GRADLE" || \
    sed -i -E "s/^(\s*)defaultConfig \{/\1defaultConfig {\n\1    manifestPlaceholders += [appAuthRedirectScheme: 'msauth']/" "$GRADLE"
  grep -q appAuthRedirectScheme "$GRADLE"
else
  echo "No está android/app/build.gradle(.kts)" >&2; exit 1
fi

sed -i -E "s/android:label=\"[^\"]+\"/android:label=\"$NOMBRE\"/" "$MANIFEST"
sed -i 's/ *android:taskAffinity=""//' "$MANIFEST"
for permiso in INTERNET RECORD_AUDIO; do
  grep -q "android.permission.$permiso" "$MANIFEST" || \
    sed -i "s#<application#<uses-permission android:name=\"android.permission.$permiso\"/>\n    <application#" "$MANIFEST"
done
if ! grep -q CustomTabsService "$MANIFEST"; then
  CONSULTAS='        <intent>\n            <action android:name="android.intent.action.VIEW"/>\n            <category android:name="android.intent.category.BROWSABLE"/>\n            <data android:scheme="https"/>\n        </intent>\n        <intent>\n            <action android:name="android.support.customtabs.action.CustomTabsService"/>\n        </intent>'
  if grep -q '<queries>' "$MANIFEST"; then
    sed -i "s#<queries>#<queries>\n$CONSULTAS#" "$MANIFEST"
  else
    sed -i "s#</manifest>#    <queries>\n$CONSULTAS\n    </queries>\n</manifest>#" "$MANIFEST"
  fi
fi

echo "== applicationId =="; grep -h applicationId "$GRADLE_KTS" "$GRADLE" 2>/dev/null || true
echo "== appAuthRedirectScheme =="; grep -h appAuthRedirectScheme "$GRADLE_KTS" "$GRADLE" 2>/dev/null || true
grep -q 'taskAffinity=""' "$MANIFEST" && { echo "Quedó taskAffinity vacío" >&2; exit 1; }
echo "android listo para $APP_ID"
