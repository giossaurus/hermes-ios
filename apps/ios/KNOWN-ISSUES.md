# HermesMobile — Known issues

Current limitations and rough edges. This is a personal **pt-BR fork** built with the
maintainer's own Apple team, so some items differ from the upstream TestFlight beta —
notably **background push is available here** (see Notifications).

## Setup / connectivity

- **Desktop must share the same gateway as the phone ("remote mode").** The iOS
  app pairs with ONE gateway (your dashboard gateway). It sees the Hermes
  *desktop's* sessions only when the desktop is **attached to that same shared
  gateway**. In the desktop's default "local" mode it runs its own isolated
  gateway the phone never sees. Workaround: run the desktop attached to the shared
  gateway (set `HERMES_TUI_GATEWAY_URL=ws://<your-gateway-host>:<port>/api/ws?token=…`).
  A one-step "always share" option is planned.
- **Reconnect after a long background can stick on "Reconnecting…".** After the
  app has been backgrounded for a long time, foregrounding occasionally stays on
  "Reconnecting…"; **force-quit + reopen** recovers. Not currently reproducing
  after recent fixes.
- **Tailnet reachability.** The phone must be able to reach your gateway (same LAN
  or Tailscale). A `*.ts.net` connection failure surfaces an "Is Tailscale
  connected?" hint.
- **[fork] App-group rename is incomplete — widgets / Live Activity / share-sheet
  broken.** This fork's entitlements use `group.gio.hermes.app`, but
  `apps/ios/HermesMobile/Support/SharedStore.swift` still hardcodes the old
  `group.ai.hermes.app`. Until the constant matches the entitlement, the widget
  snapshot, Live Activity snapshots, and the share-extension inbox can't cross the
  process boundary. **One-line fix; first on the roadmap.**

## Notifications

- **In-app approvals & clarifications always work** — when the agent needs you, it
  surfaces live in the app, on any gateway.
- **Background push — available in this fork (you build it yourself).** This fork is
  signed with the maintainer's own Apple team (bundle id `gio.hermes.app`), so
  background push (long-turn-done / approval-while-away) and *remote* Live Activity
  updates work once you wire your own APNs key. The iOS side is already in place; on
  the gateway:
  1. Create an APNs Auth Key (`.p8`) in your Apple Developer account; note its Key ID + Team ID.
  2. Set `HERMES_PUSH_ENABLED=1`, `HERMES_APNS_KEY_FILE=…/AuthKey_XXX.p8`,
     `HERMES_APNS_KEY_ID=…`, `HERMES_APNS_TEAM_ID=…`.
  3. **Critical:** set `HERMES_APNS_TOPIC=gio.hermes.app`. The gateway's default topic is
     the *upstream* bundle id (`ai.hermes.app`); without this override APNs rejects every
     push. (It also drives remote Live Activity updates.)
  4. For an Xcode-signed (development) install, also set `HERMES_APNS_USE_SANDBOX=1` (or rely
     on the per-token sandbox/production routing the app already sends).
  In-app approvals & clarifications always work regardless, on any gateway. (On the
  *upstream* TestFlight build, remote push isn't available — its APNs key belongs to that
  publisher; that's the original limitation this fork removes by using your own key.)
- **Enabling:** Settings → Notifications → toggle on → grant the iOS prompt.
  (Earlier builds had the toggle stuck disabled; fixed in the current build.)

## UI polish (cosmetic, self-correcting)

- **Drawer row can briefly flicker during a very long silent turn.** If an agent
  turn goes >10s with no streamed output and the session list refreshes in that
  gap, the row can drop a slot then pop back; it self-corrects at turn end.
- **Accessibility pass in progress.** A handful of controls use fixed font sizes
  / lack VoiceOver labels; a Dynamic Type + contrast sweep is underway. *(In this
  fork, the visible UI is pt-BR but VoiceOver labels are not yet translated —
  planned.)*

## Not yet in this beta

- App Store distribution (this is an external TestFlight beta).
- A hosted/cloud gateway — the app requires your own `hermes-agent` gateway with
  the HermesMobile plugin (see the setup guide).
