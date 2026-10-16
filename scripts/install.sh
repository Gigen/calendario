#!/bin/bash
# Calendario installer: build, sign with your (free) Apple ID and install the app,
# optionally with Google Meet support.
#
#   curl -fsSL https://raw.githubusercontent.com/Gigen/calendario/main/scripts/install.sh | bash
#
# or, from a clone:  ./scripts/install.sh
#
# What it does:
#   1. checks macOS and Xcode, clones the repo if needed
#   2. finds your Apple Team ID (sign in to Xcode once) and picks a unique bundle ID
#   3. optionally sets up Google (creates the Cloud project and enables the APIs with
#      gcloud if you have it; opens the Console pages for the steps Google doesn't
#      offer an API for) and asks for the OAuth client ID
#   4. writes Config/Local.xcconfig, builds a signed Release and installs it to
#      ~/Applications (or /Applications)
#
# Nothing here needs sudo. Re-running is safe; existing answers are offered as defaults.

set -euo pipefail

REPO_URL="https://github.com/Gigen/calendario.git"
DEFAULT_DIR="$HOME/Calendario"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
warn() { printf '\033[33m! %s\033[0m\n' "$*"; }
fail() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
# Read from the terminal even when the script itself comes from a pipe (curl | bash).
ask() {
    local prompt=$1 default=${2:-} answer
    if [[ -n $default ]]; then prompt="$prompt [$default]"; fi
    read -r -p "$prompt: " answer </dev/tty || true
    printf '%s' "${answer:-$default}"
}
yes_no() {
    local answer
    answer=$(ask "$1 (y/n)" "${2:-n}")
    [[ $answer =~ ^[Yy] ]]
}
wait_enter() { read -r -p "  Press Return when done… " _ </dev/tty || true; }
read_setting() {
    # The value of KEY in Config/Local.xcconfig, if present.
    [[ -f Config/Local.xcconfig ]] || return 0
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" Config/Local.xcconfig | tail -1
}

# --- 1. Prerequisites ----------------------------------------------------------

bold "Calendario installer"

[[ $(uname) == Darwin ]] || fail "Calendario is a macOS app."
macos_major=$(sw_vers -productVersion | cut -d. -f1)
(( macos_major >= 15 )) || fail "macOS 15 or later is required (this Mac has $(sw_vers -productVersion))."

if ! xcodebuild -version >/dev/null 2>&1; then
    warn "Xcode isn't installed (or not selected)."
    info "Install Xcode 26 from the App Store, open it once, then run this again."
    open "macappstore://apps.apple.com/app/xcode/id497799835" || true
    exit 1
fi
xcode_major=$(xcodebuild -version | awk 'NR==1 {print $2}' | cut -d. -f1)
(( xcode_major >= 26 )) || fail "Xcode 26 or later is required (found $(xcodebuild -version | head -1))."
info "$(xcodebuild -version | head -1), macOS $(sw_vers -productVersion)"

# Run from the repository; clone it if the script came from curl.
if [[ ! -f Calendario.xcodeproj/project.pbxproj ]]; then
    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)
    if [[ -n $script_dir && -f $script_dir/../Calendario.xcodeproj/project.pbxproj ]]; then
        cd "$script_dir/.."
    else
        target=$(ask "Where should Calendario's source go" "$DEFAULT_DIR")
        if [[ -d $target/.git ]]; then
            info "Updating $target"
            git -C "$target" pull --ff-only
        else
            git clone "$REPO_URL" "$target"
        fi
        cd "$target"
    fi
fi
info "Source: $(pwd)"

# --- 2. Apple signing -----------------------------------------------------------

bold "Apple signing"
team_id=$(read_setting DEVELOPMENT_TEAM)
if [[ -z $team_id || $team_id == YOURTEAMID ]]; then
    team_id=$(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null \
        | sed -n 's/.*teamID = \([A-Z0-9]*\);.*/\1/p' | head -1 || true)
fi
while [[ -z $team_id ]]; do
    warn "No Apple developer team found in Xcode."
    info "Open Xcode > Settings > Accounts and sign in with your Apple ID (a free one works)."
    open -a Xcode || true
    wait_enter
    team_id=$(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null \
        | sed -n 's/.*teamID = \([A-Z0-9]*\);.*/\1/p' | head -1 || true)
done
team_id=$(ask "Apple Team ID" "$team_id")

bundle_id=$(read_setting PRODUCT_BUNDLE_IDENTIFIER)
if [[ -z $bundle_id || $bundle_id == com.yourname.calendario ]]; then
    short=$(id -un | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')
    bundle_id="com.${short:-me}.calendario"
fi
info "The bundle ID must be unique across all Apple developers."
bundle_id=$(ask "Bundle ID" "$bundle_id")
[[ $bundle_id =~ ^[A-Za-z0-9.-]+\.[A-Za-z0-9-]+$ ]] || fail "That bundle ID isn't valid (letters, digits, dots, hyphens)."

# --- 3. Google (optional) -------------------------------------------------------

client_id=$(read_setting GOOGLE_CLIENT_ID)
bold "Google Meet and invitees (optional)"
if [[ -n $client_id ]]; then
    info "Using the existing Google client ID."
    if yes_no "Set Google up again" n; then client_id=""; else skip_google=1; fi
fi
if [[ -z ${skip_google:-} ]] && yes_no "Set up Google now? You can skip this and run the installer again later" n; then
    project_id=""
    console="https://console.cloud.google.com"
    if command -v gcloud >/dev/null 2>&1; then
        info "Using gcloud to create the project and enable the APIs."
        gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | grep -q . || gcloud auth login
        project_id=$(ask "Google Cloud project ID to create (or an existing one)" "calendario-$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 6)")
        gcloud projects describe "$project_id" >/dev/null 2>&1 || gcloud projects create "$project_id" --name="Calendario"
        gcloud services enable calendar-json.googleapis.com people.googleapis.com --project "$project_id"
        info "Project $project_id ready, Calendar and People APIs enabled."
    else
        info "gcloud isn't installed (optional: brew install --cask google-cloud-sdk)."
        info "Create a project and enable two APIs in the pages that open now:"
        open "$console/projectcreate"
        wait_enter
        project_id=$(ask "The project ID you created")
        open "$console/apis/library/calendar-json.googleapis.com?project=$project_id"
        open "$console/apis/library/people.googleapis.com?project=$project_id"
        info "Click Enable on both pages."
        wait_enter
    fi

    q="?project=$project_id"
    bold "  Consent screen (Google has no API for this part)"
    info "Branding: app name 'Calendario', your email as support and developer contact."
    open "$console/auth/branding$q"; wait_enter
    info "Audience: External. Add your Google accounts as test users, then click"
    info "'Publish app' (In production). Apps left in Testing get signed out every 7 days."
    open "$console/auth/audience$q"; wait_enter
    info "Data access > Add or remove scopes, add:"
    info "  https://www.googleapis.com/auth/calendar.events.owned"
    info "  https://www.googleapis.com/auth/calendar.calendarlist.readonly"
    info "  https://www.googleapis.com/auth/directory.readonly   (coworker suggestions)"
    open "$console/auth/scopes$q"; wait_enter

    bold "  OAuth client"
    info "Create client > Application type: iOS (it's what Google's macOS sign-in uses)"
    info "  Bundle ID: $bundle_id"
    info "  Team ID:   $team_id"
    open "$console/auth/clients/create$q"
    while :; do
        client_id=$(ask "Paste the Client ID (…apps.googleusercontent.com)")
        [[ $client_id =~ ^[0-9]+-[a-z0-9]+\.apps\.googleusercontent\.com$ ]] && break
        warn "That doesn't look like an OAuth client ID."
    done
fi

# --- 4. Configure, build, install -------------------------------------------------

bold "Building"
cat > Config/Local.xcconfig <<EOF
// Written by scripts/install.sh. Git-ignored.
CODE_SIGN_IDENTITY = Apple Development
DEVELOPMENT_TEAM = $team_id
PRODUCT_BUNDLE_IDENTIFIER = $bundle_id
GOOGLE_CLIENT_ID = $client_id
EOF
info "Wrote Config/Local.xcconfig"

log=$(mktemp -t calendario-build)
# -allowProvisioningUpdates lets Xcode register the app ID and signing certificate
# with your Apple account, as it would when you press Run.
if ! xcodebuild -project Calendario.xcodeproj -scheme Calendario -configuration Release \
        -derivedDataPath build -allowProvisioningUpdates build >"$log" 2>&1; then
    grep -E "error:" "$log" | head -20 >&2 || true
    fail "Build failed. Full log: $log"
fi
app="build/Build/Products/Release/Calendario.app"
[[ -d $app ]] || fail "Build succeeded but $app is missing. Log: $log"

if [[ -w /Applications ]]; then dest=/Applications; else dest="$HOME/Applications"; mkdir -p "$dest"; fi
osascript -e 'quit app "Calendario"' >/dev/null 2>&1 || true
rm -rf "$dest/Calendario.app"
cp -R "$app" "$dest/"
bold "Installed $dest/Calendario.app"
info "Open it, click Allow Access for Calendars (and Reminders in the sidebar)."
[[ -n $client_id ]] && info "Then connect Google in Calendario > Settings > Accounts."
open "$dest/Calendario.app"
