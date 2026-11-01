#!/bin/bash

set -e

cd "$(dirname "$0")"

WORKING_LOCATION="$(pwd)"
APPLICATION_NAME=Geranium
CONFIGURATION=Release

rm -rf build
if [ ! -d "build" ]; then
    mkdir build
fi

cd build

rm -f LocationSimulator.tipa

# Build .app
xcodebuild -project "$WORKING_LOCATION/$APPLICATION_NAME.xcodeproj" \
    -scheme Geranium \
    -configuration "$CONFIGURATION" \
    -skipPackagePluginValidation \
    -skipMacroValidation \
    -derivedDataPath "$WORKING_LOCATION/build/DerivedData" \
    -destination 'generic/platform=iOS' \
    ONLY_ACTIVE_ARCH="NO" \
    CODE_SIGNING_ALLOWED="NO"

DD_APP_PATH="$WORKING_LOCATION/build/DerivedData/Build/Products/$CONFIGURATION-iphoneos/$APPLICATION_NAME.app"
TARGET_APP="$WORKING_LOCATION/build/$APPLICATION_NAME.app"
cp -r "$DD_APP_PATH" "$TARGET_APP"

# Remove signature
codesign --remove "$TARGET_APP"
if [ -e "$TARGET_APP/_CodeSignature" ]; then
    rm -rf "$TARGET_APP/_CodeSignature"
fi
if [ -e "$TARGET_APP/embedded.mobileprovision" ]; then
    rm -rf "$TARGET_APP/embedded.mobileprovision"
fi

# Root helper (needed to change the app name / photo icon). Requires Theos.
git submodule update --init --recursive
cd "$WORKING_LOCATION/RootHelper"
make clean
make
cp "$WORKING_LOCATION/RootHelper/.theos/obj/debug/GeraniumRootHelper" "$WORKING_LOCATION/build/Geranium.app/GeraniumRootHelper"
cd -

#cp $WORKING_LOCATION/build/DerivedData/Build/Products/$CONFIGURATION-iphoneos/RootHelper $WORKING_LOCATION/build/Geranium.app/RootHelper

# Is ldid installed ?
if command -v ldid &> /dev/null; then
    echo "ldid is already installed."
else
    # Install ldid using Homebrew
    if command -v brew &> /dev/null; then
        echo "Installing ldid with Homebrew..."
        brew install ldid
        echo "ldid has been installed."
    else
        echo "Homebrew is not installed. Please install Homebrew first."
    fi
fi

# Add entitlements
echo "Adding entitlements"
ldid -S"$WORKING_LOCATION/entitlements.plist" "$TARGET_APP/$APPLICATION_NAME"
# Inject into the Maps thingy
ldid -S"$WORKING_LOCATION/Bookmark Location in Geranium/entitlements.plist" "$TARGET_APP/PlugIns/Bookmark Location in Geranium.appex/Bookmark Location in Geranium"
# idk if this is usefull but uhm
# ldid -S"$WORKING_LOCATION/Bookmark Location in Geranium/entitlements.plist" "$TARGET_APP/PlugIns/Bookmark Location in Geranium.appex/Bookmark Location in Geranium.debug.dylib"
# ldid -S"$WORKING_LOCATION/entitlements.plist" "$TARGET_APP/RootHelper"

# Package .tipa (app folder and file named "LocationSimulator")
OUT_NAME=LocationSimulator
rm -rf Payload
mkdir Payload
cp -r $APPLICATION_NAME.app Payload/$OUT_NAME.app
zip -qr $OUT_NAME.tipa Payload
rm -rf $APPLICATION_NAME.app
rm -rf Payload
