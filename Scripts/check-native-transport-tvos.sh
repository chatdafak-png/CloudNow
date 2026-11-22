#!/usr/bin/env bash
set -euo pipefail

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/cloudnow-nvst.XXXXXXXX")
trap 'rm -rf "$work_dir"' EXIT

sdk=$(xcrun --sdk appletvos --show-sdk-path)
compiler=$(xcrun --sdk appletvos --find clang)
deployment_target=26.2
target="arm64-apple-tvos$deployment_target"
jobs=$(sysctl -n hw.ncpu)

openssl_version=3.5.8
openssl_sha=a8f84a39918ec6415ce765d9b429d313ba97b8143169c172e734b9514464f5b2
openssl_archive="$work_dir/openssl.tar.gz"
openssl_source="$work_dir/openssl-$openssl_version"
sctp_revision=07f871bda23943c43c9e74cc54f25130459de830
sctp_source="$work_dir/usrsctp"
sctp_build="$work_dir/sctp-build"

printf '%s\n' 'Building OpenSSL for tvOS'
curl -fLsS --retry 3 -o "$openssl_archive" \
    "https://github.com/openssl/openssl/releases/download/openssl-$openssl_version/openssl-$openssl_version.tar.gz"
printf '%s  %s\n' "$openssl_sha" "$openssl_archive" | shasum -a 256 -c -
tar -xzf "$openssl_archive" -C "$work_dir"
(
    cd "$openssl_source"
    # Configure parses standalone argument values as additional build targets.
    CC="$compiler" CFLAGS="-target $target -isysroot $sdk -fapplication-extension" \
        ./Configure darwin64-arm64-cc \
        no-shared no-tests no-apps no-module no-engine no-asm no-async
    make -j "$jobs" build_libs
)

printf '%s\n' 'Building usrsctp for tvOS'
git clone --quiet --depth 1 --branch 0.9.5.0 https://github.com/sctplab/usrsctp.git "$sctp_source"
test "$(git -C "$sctp_source" rev-parse HEAD)" = "$sctp_revision"
# usrsctp 0.9.5.0 declares a policy version older than CMake 4 supports.
cmake -S "$sctp_source" -B "$sctp_build" -G Ninja \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=tvOS \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_SYSROOT="$sdk" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$deployment_target" \
    -DCMAKE_C_COMPILER="$compiler" \
    '-DCMAKE_C_FLAGS=-fapplication-extension -Wno-unused-but-set-variable -Wno-strict-prototypes' \
    -Dsctp_build_programs=OFF \
    -Dsctp_build_shared_lib=OFF \
    -Dsctp_debug=OFF \
    -Dsctp_werror=OFF
cmake --build "$sctp_build" --target usrsctp --parallel "$jobs"

# Pull the DTLS-SRTP and SCTP symbols the native transport will call into a tvOS binary.
cat > "$work_dir/link-check.c" <<'C'
#include <openssl/ssl.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <usrsctp.h>

int main(void) {
    SSL_CTX *context = SSL_CTX_new(DTLS_client_method());
    if (context == NULL) {
        return 1;
    }
    int result = SSL_CTX_set_tlsext_use_srtp(context, "SRTP_AES128_CM_SHA1_80");
    SSL_CTX_free(context);
    usrsctp_init(0, NULL, NULL);
    return usrsctp_finish() == 0 ? result : 1;
}
C

printf '%s\n' 'Linking both libraries into a tvOS executable'
"$compiler" -target "$target" -isysroot "$sdk" -fapplication-extension \
    -I "$openssl_source/include" -I "$sctp_source/usrsctplib" \
    "$work_dir/link-check.c" "$openssl_source/libssl.a" "$openssl_source/libcrypto.a" \
    "$sctp_build/usrsctplib/libusrsctp.a" -o "$work_dir/link-check"
xcrun vtool -show-build "$work_dir/link-check" | tee "$work_dir/platform.txt"
grep -E 'platform[[:space:]]+TVOS([[:space:]]|$)' "$work_dir/platform.txt"
