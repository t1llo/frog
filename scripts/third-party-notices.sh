#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Writes one text file with the license and notice files of every package pinned in
# Package.resolved, then those in ThirdPartyLicenses/ for code copied into this repository.
# Run after `swift build`, which fills .build/checkouts.
output="${1:?Usage: third-party-notices.sh <output file>}"
checkouts=".build/checkouts"
rule="================================================================================"

# Packages keep the licenses of code they bundle below their root, so search the
# whole checkout. Shallower files come first. Test fixtures never reach the app.
license_files() {
    find "$1" -type f \( -iname 'LICEN[SC]E*' -o -iname '*-LICEN[SC]E*' -o -iname 'COPYING*' \
        -o -iname 'NOTICE*' -o -iname 'ACKNOWLEDG*' -o -ipath '*licen[sc]es/*' \) \
        -not -path '*/.git/*' -not -path '*/Tests/*' \
        | awk -F/ '{ print NF "\t" $0 }' | LC_ALL=C sort -t "$(printf '\t')" -k1,1n -k2 | cut -f2-
}

pin() { plutil -extract "pins.$1.$2" raw -o - Package.resolved; }

packages=""
texts="$(mktemp)"
trap 'rm -f "$texts"' EXIT
count="$(plutil -extract pins raw -o - Package.resolved)"
for ((index = 0; index < count; index++)); do
    location="$(pin "$index" location)"
    if ! version="$(pin "$index" state.version 2>/dev/null)"; then version="$(pin "$index" state.revision)"; fi
    name="$(basename "$location" .git)"
    checkout="$checkouts/$name"
    if [[ ! -d "$checkout" ]]; then
        echo "$checkout is missing. Run swift build before collecting third-party notices." >&2
        exit 1
    fi
    files="$(license_files "$checkout")"
    # Without a license at its root, a package would ship without its terms.
    if ! grep -qiE "^$checkout/(LICEN[SC]E|COPYING)[^/]*$" <<< "$files"; then
        echo "$checkout has no license file at its root. Do not distribute this bundle." >&2
        exit 1
    fi
    packages+="  $name $version ($location)"$'\n'
    printf '%s\n%s %s\n%s\n%s\n\n' "$rule" "$name" "$version" "$location" "$rule" >> "$texts"
    while IFS= read -r file; do
        printf -- '---- %s ----\n\n' "${file#"$checkout"/}" >> "$texts"
        cat "$file" >> "$texts"
        printf '\n\n' >> "$texts"
    done <<< "$files"
done

copied=""
for file in ThirdPartyLicenses/*; do
    [[ -f "$file" ]] || continue
    if [[ -z "$copied" ]]; then printf '%s\nCode copied into Frog'"'"'s source\n%s\n\n' "$rule" "$rule" >> "$texts"; fi
    copied+="  $(head -n 1 "$file")"$'\n'
    printf -- '---- %s ----\n\n' "$file" >> "$texts"
    cat "$file" >> "$texts"
    printf '\n\n' >> "$texts"
done

{
    cat <<EOF
Frog: third-party notices

Frog is built with the Swift packages listed below. This file reproduces every
license, notice and acknowledgment file found in their source at the pinned
versions, including those of code the packages bundle. Some of these files cover
components that are not part of Frog.

Frog itself is free software under the GNU General Public License, version 3 or
later. Its license is in LICENSE.txt next to this file.

Swift packages:
$packages
EOF
    if [[ -n "$copied" ]]; then printf 'Code copied into Frog'"'"'s source:\n%s\n' "$copied"; fi
    cat "$texts"
} > "$output"
