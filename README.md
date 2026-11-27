# CodeBypass for iPhone (repo and bundle id still say claudette)

Native SwiftUI client for the Claude Phone server (`claude-phone`, Node on :8787 over Tailscale).
Not a web wrapper: it talks to the server's JSON API (`/api/sessions`, `/api/sessions/:id`, `/type`,
`/upload`, `/new`, `/suggest`, `/img`, `/archive`) and gets Apple push from `/api/push/apns`.

First launch asks for the server address and token; both are kept in the Keychain.
Nothing about the server (address, token) is in this repo.

Build: XcodeGen on GitHub Actions (`runs-on: xcode-27`). `build.yml` compiles on every push;
`testflight.yml` signs and uploads (on push to main touching App/ or project.yml, or by hand).
Secrets: APPLE_TEAM_ID, ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8, DIST_P12, DIST_P12_PASSWORD,
PROFILE_APP (base64 of the "Claudette App Store" profile, au.com.strapify.claudette, Push on).
