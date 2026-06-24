# Hermes Agent — iOS app (HermesMobile)

Your Hermes agent, on your phone. Live-streaming chat, approvals, push
notifications + Live Activities, device pairing, and file/attachment support —
talking directly to **your own** `hermes-agent` gateway. No third‑party servers:
the app connects only to the gateway you run.

> **Personal fork (pt-BR).** This is a personal, Brazilian-Portuguese-localized
> fork of **[ab0991-oss/hermes-ios](https://github.com/ab0991-oss/hermes-ios)** (the
> iOS app), which builds on **[NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent)**
> (the gateway). Splash/backdrop artwork and the "nous" theme are © Nous Research.
> Full attribution in [NOTICE](NOTICE) / [License & credits](#license--credits) —
> and see [what this fork adds](#what-this-fork-adds).

---

## What you need first

HermesMobile is a **client for a gateway you host**. Before installing the app
you need:

1. A machine running **[hermes-agent](https://hermes-agent.nousresearch.com)**
   (your Mac, a Linux box, etc.).
2. That gateway running the **HermesMobile plugin** (adds multi‑client streaming,
   pairing, and push). The plugin is a self‑contained add‑on — see **Set up the
   gateway** below.
3. The phone able to **reach the gateway** — same Wi‑Fi/LAN, or over
   [Tailscale](https://tailscale.com) (recommended for "anywhere" access).

---

## Set up the gateway — the easy way (let your agent do it)

If you already run Hermes, the fastest path is to **paste this prompt into your
Hermes agent** and let it set everything up:

```
Set up the HermesMobile iOS app support on this Hermes gateway for me.

1. Clone the project and run its installer against this hermes-agent checkout:
   git clone https://github.com/giossaurus/hermes-ios.git
   hermes-ios/dist/hermes-mobile/install.sh "$(pwd)"
   (add --dry-run after the path first if you want to preview the changes.)
2. Export these (the installer prints the exact values), then restart the gateway:
   export HERMES_GATEWAY_BROADCAST=1
   export HERMES_DASHBOARD_SESSION_TOKEN="$(cat ~/.hermes/dashboard.token)"
3. Verify with `hermes plugins list` — "hermes-mobile" should be "enabled".
4. Run `hermes mobile-pair` and show me the QR code / pairing link so I can scan
   it from the iOS app.

If any step errors, diagnose and fix it, then continue. Summarize what you did.
```

That's it — your agent applies the plugin, restarts the gateway, and hands you a
pairing QR.

### …or set it up by hand

From the root of your `hermes-agent` checkout:

```bash
# 1. Clone this repo and run the installer against your hermes-agent checkout
#    (additive — stock files are only extended; add --dry-run to preview).
git clone https://github.com/giossaurus/hermes-ios.git
hermes-ios/dist/hermes-mobile/install.sh  /path/to/your/hermes-agent

# 2. Export these (the installer prints them), then restart the gateway.
export HERMES_GATEWAY_BROADCAST=1
export HERMES_DASHBOARD_SESSION_TOKEN="$(cat ~/.hermes/dashboard.token)"

# 3. Verify + get a pairing code.
hermes plugins list      # hermes-mobile -> enabled
hermes mobile-pair       # prints a QR + hermesapp://pair deep-link
```

Full installer details + rollback: [`dist/hermes-mobile/INSTALL.md`](dist/hermes-mobile/INSTALL.md).

---

## Get the app on your phone

> **This fork is build-it-yourself.** The public TestFlight link below is the
> **original author's** upstream build (in English) — **not** this pt-BR fork. To run
> *this* version you build it yourself (Option 2); to install it over-the-air, publish
> it to **your own** TestFlight under your Apple Developer account.

### Option 1 — Original author's TestFlight (upstream, English — not this fork)

The upstream public beta, maintained by
[ab0991-oss](https://github.com/ab0991-oss/hermes-ios):

1. Install Apple's **TestFlight** app (from the App Store).
2. Open the public invite link: **https://testflight.apple.com/join/TeMvfFaS**
3. Tap **Install** to get the app.

### Option 2 — Build this fork yourself (pt-BR)

Requirements: a Mac with **Xcode 26+**, an Apple ID for signing.

```bash
git clone https://github.com/giossaurus/hermes-ios.git   # this pt-BR fork
cd hermes-ios/apps/ios
brew install xcodegen           # if you don't have it
xcodegen generate               # generates HermesMobile.xcodeproj
open HermesMobile.xcodeproj
```

In Xcode: pick your team under **Signing & Capabilities**, select your iPhone,
and **Run**. (First run on a personal team: trust the developer profile under
Settings → General → VPN & Device Management.) To install over-the-air, archive and
upload to **your own** TestFlight.

---

## Pair the app to your gateway

1. On the gateway host, run `hermes mobile-pair`.
2. In the app, tap **Scan pairing code** and scan the QR — or **Enter manually**
   with the URL + token it prints.
3. You're in. Sessions stream live; start chatting.

> **Tip:** for sessions you start in the Hermes **desktop** to show up on the
> phone, the desktop must share the same gateway (see Known issues).

---

## Features

- Live multi‑client streaming — desktop ↔ phone mirror the same sessions.
- Approvals + clarifications inline and via push (approve/deny from the lock
  screen).
- Push notifications for approvals, questions, and long turns finishing.
- Live Activities + Dynamic Island — watch a turn run from the lock screen.
- Home‑screen widgets (status, usage).
- File browse + attachment upload, voice dictation, Face ID lock.

---

## What this fork adds

On top of upstream, this fork adds:

- **Brazilian-Portuguese (pt-BR) localization** with an **in-app language switcher**
  (Settings → Language) that applies **live, no restart**. English ⇄ Português;
  product/technical terms (Hermes, Skills, Gateway, Token, model names) stay in English.
- **"nous" theme backdrop** — a warm corner glow + subtle texture behind the chat,
  matching the Hermes desktop look (assets © Nous Research — see [NOTICE](NOTICE)).
- **Cold-launch splash** — a `#0000F2` brand screen with the Nous "psyche" animation
  and a HERMES / AGENT wordmark, crossfading into the app.
- **Original app icon** restored, plus a small **Swift 6 concurrency-warning** cleanup.

Roadmap + fork-specific limitations: see [Known issues](apps/ios/KNOWN-ISSUES.md).

---

## Known issues

See [`KNOWN-ISSUES.md`](apps/ios/KNOWN-ISSUES.md). Highlights for the first beta:
desktop must share the gateway for its sessions to appear on the phone; a
rare "stuck on reconnecting" after a long background (force‑quit recovers); an
accessibility pass is in progress.

---

## Troubleshooting

- **Can't connect / "Is Tailscale connected?"** — the phone must reach the
  gateway. Confirm the URL works in the phone's browser, and that Tailscale (if
  used) is connected on both ends.
- **No notifications** — first, open the app's **Settings → Notifications**,
  toggle it on, and grant the iOS permission prompt. Note: **push needs an APNs
  signing key for the app you're running**, which only the app's signer holds. If
  you **built the app yourself**, set your team's key on the gateway
  (`HERMES_APNS_KEY_FILE` / `HERMES_APNS_KEY_ID` / `HERMES_APNS_TEAM_ID`). On the
  **TestFlight build**, remote push isn't available from a self-hosted gateway
  (its push key belongs to the app's publisher) — live chat, sync, and the
  on-device Live Activity timer still work.
- **Desktop sessions not visible** — run the desktop attached to the same shared
  gateway the phone paired with (Known issues).

---

## Privacy & security

The app talks **only** to the gateway you run — there is no HermesMobile cloud
service. Your pairing token is stored in the iOS Keychain. Push goes through
Apple's APNs using **your** gateway's signing key. Full policy:
[PRIVACY.md](PRIVACY.md).

---

## Support

Questions / bugs: open an issue at https://github.com/giossaurus/hermes-ios/issues.

---

## License & credits

MIT — see [LICENSE](LICENSE) and [NOTICE](NOTICE).

- **iOS app** — forked from [ab0991-oss/hermes-ios](https://github.com/ab0991-oss/hermes-ios) (MIT).
- **Gateway** — [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) (MIT);
  the seam patch (`dist/hermes-mobile/seams.patch`) derives from it.
- **Artwork & branding** — the splash animation (the "psyche" figure), the backdrop
  texture, and the "nous" theme are **© Nous Research**, from the Hermes design system,
  reproduced here with attribution. These are Nous Research brand assets (not the MIT
  code); confirm usage rights before redistributing publicly. See [NOTICE](NOTICE).

This fork is © 2026 Giovanni Della Dea, for personal pt-BR use.
