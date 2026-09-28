.DEFAULT_GOAL := build

DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
CONFIGURATION ?= release
FROG_BUILD_NUMBER ?= $(shell date -u +%Y%m%d%H%M%S)
FROG_SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Developer ID Application:/ { print $$2; exit }')

export DEVELOPER_DIR CONFIGURATION FROG_BUILD_NUMBER FROG_SIGN_IDENTITY

.PHONY: build
build:
	FROG_APP_ONLY=1 bash scripts/build-app.sh
