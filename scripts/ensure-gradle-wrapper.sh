#!/usr/bin/env bash
# Generate the Gradle Wrapper from a verified official Gradle distribution.
# This uses a temporary minimal project so wrapper generation does not have to
# evaluate or resolve the Android/Flutter project plugins first.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
ANDROID_DIR="${1:-$PROJECT_ROOT/android_app/android}"

GRADLE_VERSION="9.5.0"
GRADLE_SHA256="553c78f50dafcd54d65b9a444649057857469edf836431389695608536d6b746"
WRAPPER_JAR_SHA256="497c8c2a7e5031f6aa847f88104aa80a93532ec32ee17bdb8d1d2f67a194a9c7"
DIST_URL="https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip"

if [[ ! -d "$ANDROID_DIR" ]]; then
  echo "ERROR: Android project directory not found: $ANDROID_DIR" >&2
  exit 1
fi

WRAPPER_DIR="$ANDROID_DIR/gradle/wrapper"
WRAPPER_JAR="$WRAPPER_DIR/gradle-wrapper.jar"
WRAPPER_PROPERTIES="$WRAPPER_DIR/gradle-wrapper.properties"
WRAPPER_UNIX="$ANDROID_DIR/gradlew"
WRAPPER_WINDOWS="$ANDROID_DIR/gradlew.bat"

mkdir -p "$WRAPPER_DIR"

# Reuse an already-generated wrapper only when all expected files, URLs and
# official checksums match the pinned Gradle 9.5.0 toolchain.
if [[ -s "$WRAPPER_JAR" && -s "$WRAPPER_UNIX" && -s "$WRAPPER_WINDOWS" && -s "$WRAPPER_PROPERTIES" ]]; then
  actual_wrapper_sha="$(sha256sum "$WRAPPER_JAR" | awk '{print $1}')"
  if grep -Fq "gradle-${GRADLE_VERSION}-bin.zip" "$WRAPPER_PROPERTIES" \
    && grep -Fxq "distributionSha256Sum=${GRADLE_SHA256}" "$WRAPPER_PROPERTIES" \
    && [[ "$actual_wrapper_sha" == "$WRAPPER_JAR_SHA256" ]]; then
    echo "[OK] Verified Gradle Wrapper ${GRADLE_VERSION} is already present."
    exit 0
  fi
fi

CACHE_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/secretplay-gradle-${GRADLE_VERSION}"
ZIP_PATH="$CACHE_ROOT/gradle-${GRADLE_VERSION}-bin.zip"
DIST_DIR="$CACHE_ROOT/gradle-${GRADLE_VERSION}"
mkdir -p "$CACHE_ROOT"

if [[ ! -s "$ZIP_PATH" ]]; then
  echo "[i] Downloading official Gradle ${GRADLE_VERSION} distribution..."
  curl --fail --location --silent --show-error "$DIST_URL" --output "$ZIP_PATH"
fi

echo "${GRADLE_SHA256}  ${ZIP_PATH}" | sha256sum --check --status || {
  rm -f "$ZIP_PATH"
  echo "ERROR: Gradle distribution SHA-256 verification failed." >&2
  exit 1
}

if [[ ! -x "$DIST_DIR/bin/gradle" ]]; then
  rm -rf "$DIST_DIR"
  mkdir -p "$DIST_DIR"
  unzip -q "$ZIP_PATH" -d "$CACHE_ROOT"
fi

GRADLE_EXE="$DIST_DIR/bin/gradle"
if [[ ! -x "$GRADLE_EXE" ]]; then
  echo "ERROR: Gradle executable not found after extraction: $GRADLE_EXE" >&2
  exit 1
fi

BOOTSTRAP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/secretplay-wrapper-bootstrap.XXXXXX")"
cleanup() {
  rm -rf "$BOOTSTRAP_DIR"
}
trap cleanup EXIT

printf "rootProject.name = 'secretplay-wrapper-bootstrap'\n" > "$BOOTSTRAP_DIR/settings.gradle"
: > "$BOOTSTRAP_DIR/build.gradle"

echo "[i] Generating wrapper launchers and JAR with Gradle ${GRADLE_VERSION}..."
(
  cd "$BOOTSTRAP_DIR"
  "$GRADLE_EXE" --no-daemon --console=plain wrapper \
    --gradle-version "$GRADLE_VERSION" \
    --distribution-type bin
)

GENERATED_JAR="$BOOTSTRAP_DIR/gradle/wrapper/gradle-wrapper.jar"
if [[ ! -s "$GENERATED_JAR" || ! -s "$BOOTSTRAP_DIR/gradlew" || ! -s "$BOOTSTRAP_DIR/gradlew.bat" ]]; then
  echo "ERROR: Gradle did not generate all wrapper files." >&2
  exit 1
fi

generated_wrapper_sha="$(sha256sum "$GENERATED_JAR" | awk '{print $1}')"
if [[ "$generated_wrapper_sha" != "$WRAPPER_JAR_SHA256" ]]; then
  echo "ERROR: Generated Gradle Wrapper JAR SHA-256 did not match the official checksum." >&2
  exit 1
fi

cp "$BOOTSTRAP_DIR/gradlew" "$WRAPPER_UNIX"
cp "$BOOTSTRAP_DIR/gradlew.bat" "$WRAPPER_WINDOWS"
cp "$GENERATED_JAR" "$WRAPPER_JAR"
chmod +x "$WRAPPER_UNIX"

cat > "$WRAPPER_PROPERTIES" <<PROPERTIES
distributionBase=GRADLE_USER_HOME
distributionPath=wrapper/dists
distributionUrl=https\://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip
distributionSha256Sum=${GRADLE_SHA256}
networkTimeout=60000
validateDistributionUrl=true
zipStoreBase=GRADLE_USER_HOME
zipStorePath=wrapper/dists
PROPERTIES

echo "[OK] Gradle Wrapper ${GRADLE_VERSION} generated and checksums verified."
