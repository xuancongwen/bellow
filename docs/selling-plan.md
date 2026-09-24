# BellowFlow: plan for selling the app

Written 2026-09-23. Parked until friends-and-family testing is done. Nothing
here is started; it is the plan to pick up later.

## Premise

The source stays MIT and free to build. What is sold is the convenient build:
Developer ID signed, notarized, auto-updating, with support. This is the
VoiceInk model (GPLv3 source, $29 for the signed build), and it is the only
model that fits a privacy-first, fully local app whose entire stack is
permissively licensed. The licenses allow selling outright; nothing in them
needs to change.

## Market (research of 2026-09-23)

Requirement: Apple Silicon, 16 GB+, macOS 13+.

| Filter | Estimate for active Macs |
| --- | --- |
| Apple Silicon | ~75% |
| 16 GB or more, of those | ~60% |
| macOS 13+, of those | ~95% |
| Qualifying share | ~43%, about 60 to 70 million Macs |

Every Mac sold since late 2024 has 16 GB, so the share rises a few points a
year. The comfortable experience (24 GB+) is under a quarter of Macs. The
buyer is technical and privacy-minded, and accepts a 5 GB model download.

Competitors: Wispr Flow $15/mo (cloud). Superwhisper $8.49/mo, $85/yr, $250
lifetime (local). Voibe $149 lifetime. MacWhisper ~$69. VoiceInk $29/$49/$69
lifetime per 1/2/3 Macs (open source, local). OpenWhispr free.

## Pricing

- **$29 one-time, one Mac.** Optional $49 for up to three Macs. No
  subscription: there are no recurring costs, and the audience resents rent.
- The README and site say plainly that building from source is free.
- Free tier stays exactly what exists today: the ad-hoc-signed DMG on GitHub
  Releases and the Homebrew cask. Paid tier adds notarization, Sparkle
  auto-updates, and an email for support.
- 14-day no-questions refund. Consider a launch price of $19 for the first
  month.
- Break-even on Apple's $99/year is four sales.

## Sales channel

- Merchant of record: Lemon Squeezy or Paddle (5 to 10 percent, handles VAT
  and sales tax, issues license keys, hosts the paid download). No business
  entity needed to start; a sole proprietorship is fine in the US.
- Not the Mac App Store: the sandbox conflicts with typing into other apps
  and running an Ollama subprocess, and the review process fights a 5 GB
  model download.
- License check: light. The paid DMG lives behind the merchant's download
  link; an optional license-key validation on first launch (merchant API,
  cached offline forever after) deters casual sharing without DRM. Never
  block dictation over a license problem.

## Prerequisites before charging

Product, in order:

1. Developer ID signing and notarization (README "Signing and
   notarization": program membership, certificate, app-specific password,
   five repository secrets). Expect one re-prompt for Microphone and
   Accessibility when the signature identity changes.
2. Sparkle for auto-updates: see `docs/auto-update-plan.md` (keys, CI
   secrets, integration steps).
3. The open items on the README validation list: memory and latency on 16 GB
   and 24 GB Macs, sleep/wake and repeated launch/quit, forced engine
   failures, the cleanup-prompt quality benchmark.
4. Uninstaller path documented (app plus Application Support folder), and a
   support email address. (The Gatekeeper instruction was already corrected
   in rc.4: System Settings → Privacy & Security → Open Anyway.)

Business:

- Short EULA for the paid build (the MIT text still covers the source).
- Privacy policy: one page stating nothing is collected, the only network use
  is the model download, and where the models come from.
- Refund policy on the sales page; the merchant enforces it.

## Marketing materials

- Landing page: the current GitHub Pages site grows a "Buy" button, a
  30-second screen recording of a dictation with cleanup, a comparison table
  against Superwhisper and Wispr Flow (local, one-time, open source, no
  account), and the system requirements up front to avoid refunds.
- Launch posts: Show HN, r/macapps, r/LocalLLaMA, Product Hunt, Mastodon and
  Bluesky Mac communities. Lead with "fully local, including the cleanup
  model" and "MIT, build it yourself if you like."
- Listings: alternativeto.net, MacUpdate, the Homebrew cask (free tier),
  Awesome-macOS lists.
- Assets needed: app icon at 1024 px (exists via `scripts/make-icon.swift`),
  three screenshots (setup window, overlay while listening, before/after
  transcript), the recording above, a one-paragraph description, and a
  press-style FAQ (privacy, memory, offline, models).

## Phases

| Phase | Gate | Work |
| --- | --- | --- |
| 0. Friends and family (now) | Enough people dictating daily to trust it | Ship rc builds, collect failures, fix; no sales work |
| 1. Hardening | Validation list closed, signing in CI | Notarization, Sparkle, 16 GB and 24 GB testing, quality benchmark |
| 2. Soft launch | Sales page live, 10 paid users | Merchant account, EULA and privacy page, paid DMG, support email |
| 3. Launch | Materials ready | Posts and listings above; watch refunds and support load |

## Numbers to watch after launch

Site visits to download, download to first "Ready", first "Ready" to still
dictating a week later (ask, since the app collects nothing), refund rate, and
support minutes per sale. Price is not the lever; reach and reliability are.
