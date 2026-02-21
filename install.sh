#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_DIR="$SCRIPT_DIR/package"

# Ensure scripts are executable
chmod +x "$PACKAGE_DIR/contents/ui/"*.sh 2>/dev/null || true

# Try to install; if already installed, update instead
if kpackagetool6 -t Plasma/Applet -i "$PACKAGE_DIR" 2>/dev/null; then
    echo "Applet installed successfully."
else
    echo "Applet already installed, updating..."
    kpackagetool6 -t Plasma/Applet -u "$PACKAGE_DIR"
    echo "Applet updated successfully."
fi

echo ""
echo "You can now add 'Next Boot' to your panel via the Plasma widget selector."
echo "To remove: kpackagetool6 -t Plasma/Applet -r org.kde.plasma.nextboot"
