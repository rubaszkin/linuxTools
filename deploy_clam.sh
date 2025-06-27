#!/bin/bash
# deploy-clamav.sh - Run on all agents

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

INSTALLED_COMPONENTS=()
UPDATED_COMPONENTS=()
ERRORS=()

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root${NC}"
  exit 1
fi

# Install ClamAV if not already installed
if [ -f /etc/debian_version ]; then
    apt update
    if ! dpkg -s clamav clamav-daemon clamav-freshclam &> /dev/null; then
        apt install -y clamav clamav-daemon clamav-freshclam
        INSTALLED_COMPONENTS+=("clamav")
    fi
elif [ -f /etc/redhat-release ]; then
    yum install -y epel-release
    if ! rpm -q clamav clamav-update clamav-scanner-systemd &> /dev/null; then
        yum install -y clamav clamav-update clamav-scanner-systemd
        INSTALLED_COMPONENTS+=("clamav")
    fi
fi

# Create log directory
mkdir -p /var/log/clamav
chmod 755 /var/log/clamav

# Check if clamd is installed
if command -v clamdscan &> /dev/null; then
    echo "[INFO] clamd is installed."

    DB_FILE="/var/lib/clamav/daily.cvd"
    OLD_VER="none"
    if [ -f "$DB_FILE" ]; then
        OLD_VER=$(sigtool --info "$DB_FILE" | grep "Version" | awk '{print $2}')
        echo "[INFO] Current DB version: $OLD_VER"
    else
        echo "[INFO] No existing database found."
    fi

    # Stop freshclam service if running
    if systemctl is-active --quiet clamav-freshclam; then
        systemctl stop clamav-freshclam
    fi

    # Run freshclam and capture output
    FRESHCLAM_OUTPUT=$(mktemp)
    if freshclam -v | tee "$FRESHCLAM_OUTPUT"; then
        NEW_VER=$(sigtool --info "$DB_FILE" | grep "Version" | awk '{print $2}')
        if [ "$NEW_VER" != "$OLD_VER" ]; then
            echo -e "${GREEN}[SUCCESS] Database updated to version $NEW_VER${NC}"
            UPDATED_COMPONENTS+=("clamav-db:$NEW_VER")
        else
            echo -e "${GREEN}[INFO] ClamAV is already installed and database is up to date (version $NEW_VER).${NC}"
        fi
    else
        LATEST_VER=$(grep -oP 'daily\.cvd.*version: \K[0-9]+' "$FRESHCLAM_OUTPUT" | head -1)
        echo -e "${RED}[ERROR] freshclam failed to update the database.${NC}"
        echo -e "${RED}Installed version: $OLD_VER${NC}"
        echo -e "${RED}Latest available version: ${LATEST_VER:-unknown}${NC}"
        ERRORS+=("Database update failed (installed: $OLD_VER, latest: ${LATEST_VER:-unknown})")
    fi

    rm -f "$FRESHCLAM_OUTPUT"

    # Restart freshclam service
    systemctl start clamav-freshclam
else
    echo -e "${RED}[ERROR] clamd is not installed properly.${NC}"
    ERRORS+=("clamd not installed")
fi

# Enable and start ClamAV services
if command -v systemctl &> /dev/null; then
    systemctl enable clamav-freshclam || true
    systemctl start clamav-freshclam || true
    systemctl enable clamav-daemon || true
    systemctl start clamav-daemon || true
fi

# Final summary
echo ""
if [ ${#ERRORS[@]} -gt 0 ]; then
    echo -e "${RED}[FINAL STATUS] Errors occurred during setup:${NC}"
    for err in "${ERRORS[@]}"; do
        echo -e "${RED}- $err${NC}"
    done
elif [ ${#INSTALLED_COMPONENTS[@]} -eq 0 ] && [ ${#UPDATED_COMPONENTS[@]} -eq 0 ]; then
    echo -e "${YELLOW}[FINAL STATUS] All components are already installed and up to date.${NC}"
    echo -e "${YELLOW}ClamAV version: $(clamdscan --version | awk '{print $2}')${NC}"
    echo -e "${YELLOW}Database version: $OLD_VER${NC}"
else
    echo -e "${GREEN}[FINAL STATUS] Installation and updates completed successfully.${NC}"
    if [ ${#INSTALLED_COMPONENTS[@]} -gt 0 ]; then
        echo -e "${GREEN}Installed: ${INSTALLED_COMPONENTS[*]}${NC}"
    fi
    if [ ${#UPDATED_COMPONENTS[@]} -gt 0 ]; then
        echo -e "${GREEN}Updated: ${UPDATED_COMPONENTS[*]}${NC}"
    fi
    echo -e "${GREEN}ClamAV version: $(clamdscan --version | awk '{print $2}')${NC}"
fi
