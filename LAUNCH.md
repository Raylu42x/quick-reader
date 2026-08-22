# Launching Quick Reader

Assessment of what it would take to ship this as a product, and the realistic
options. Written 2026-08-21.

## What it is, commercially

A text-to-speech document reader with follow-along highlighting and offline
audio export. The market is crowded — Speechify, NaturalReader, Voice Dream
Reader, and Apple's own built-in Spoken Content all overlap heavily.

What Quick Reader actually has going for it:

- **Fully offline and private.** No account, no upload, no subscription server.
  Most competitors are cloud-based and require sign-in. This is a real,
  defensible differentiator and should be the headline, not a footnote.
- **Audio export.** Turning a document into an `.m4a` you can put in a podcast
  app or listen to in the car is the feature people actually pay for. Speechify
  gates this behind its premium tier.
- **One-time purchase potential.** Because there is no backend, there is no
  recurring cost to cover — so a paid-up-front app is viable where competitors
  are forced into subscriptions.

What it does not have: cloud sync, PDF/EPUB/DOCX import, OCR, web-article
capture, or the neural voices that make Speechify sound good. On-device
AVSpeechSynthesizer Premium voices are decent but audibly behind ElevenLabs-class
TTS.

## Blockers before any public release

These are ordered. Nothing below matters until these are done.

1. **Move storage off `UserDefaults`.** Documents live in `UserDefaults` under
   `v1_documents`. That store is read into memory whole and rewritten on every
   save. Import one full-length book and the app will visibly stall on save and
   carry the entire library in RAM. Migrate `DocumentStore` to a JSON file in
   Application Support, or to SwiftData. This is the single biggest technical
   risk and it gets worse the more users you have to migrate later.
2. **Raise the iOS deployment target problem.** `IPHONEOS_DEPLOYMENT_TARGET` is
   26.5, which excludes every device that hasn't taken the latest major update.
   For a consumer app that is a large share of the addressable market. Drop to
   the previous major version unless a specific API forces otherwise.
3. **Add error surfacing on import.** A non-UTF-8 file currently fails silently —
   `try?` swallows the error and nothing appears. Users will read that as "the
   app is broken." Show an alert.
4. **App icon and screenshots.** `Icon/` has artwork but a store listing needs
   6.7", 6.1", and iPad screenshots plus a macOS set.
5. **Privacy manifest is present** (`PrivacyInfo.xcprivacy`) — verify it declares
   the `UserDefaults` API usage reason, which Apple now requires.

## Path A — App Store, paid up front

The most natural fit.

- **Pricing:** $4.99–$9.99 one-time. Do not attempt a subscription; there is no
  ongoing service to justify it and reviewers will say so.
- **Requirements:** Apple Developer Program, $99/yr. Universal purchase so iOS
  and macOS are covered by one buy.
- **Timeline:** 2–4 weeks of work on the blockers above, then 1–3 days review.
- **Positioning:** "Your documents, read aloud. Completely offline." Lead with
  privacy and export.
- **Risk:** discovery. Nobody searches for a new TTS app. Expect near-zero
  organic installs without external traffic.

## Path B — Free with a paid export unlock

Reading is free; audio export is a one-time in-app purchase.

This is probably the stronger commercial play. It gets the app installed (no
purchase friction), and export is the feature with clear willingness to pay. It
also demos its own value — a user who has read three documents already knows
whether the voice quality works for them.

- **Requires:** StoreKit 2 integration, a non-consumable IAP, and restore-purchase
  handling. Roughly a week on top of Path A.

## Path C — Mac-only, direct distribution

Skip the App Store entirely: notarized `.dmg` sold through Gumroad, Paddle, or
Lemon Squeezy.

- **Pros:** no 15–30% cut, no review, ship whenever, no deployment-target
  politics.
- **Cons:** you handle payment, licensing, updates (Sparkle), and support
  yourself. Mac-only cuts out the iPhone use case, which is where "listen while
  driving" actually lives.
- **Still requires:** Developer ID certificate ($99/yr) for notarization —
  unnotarized apps are effectively unrunnable on modern macOS.

## Path D — Open source, no monetization

Publish under MIT, put it on GitHub, submit to Homebrew Cask.

Reasonable if the goal is portfolio and users rather than revenue. It is also
the lowest-effort path — no IAP, no store listing, no support obligation. The
privacy angle plays especially well with an open-source audience, since the
claim becomes verifiable rather than promised.

## Recommendation

**Path B**, staged:

1. Fix the storage layer and the deployment target. Non-negotiable.
2. Ship free-with-export-unlock to the App Store, universal iOS + macOS.
3. Write one good launch post aimed at the privacy-conscious audience —
   r/apple, r/iOSProgramming, Hacker News "Show HN". The offline claim is the
   hook; without it this is invisible among a hundred TTS apps.
4. Only if there is traction: add PDF and EPUB import, which is the most
   requested feature in every competitor's reviews.

If the goal is to have shipped something rather than to earn from it, Path D is
a third of the work and gets it in front of people this week.
