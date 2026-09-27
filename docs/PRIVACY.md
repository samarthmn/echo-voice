# Echo Voice privacy policy

Updated September 23, 2026. This document describes Echo Voice's application behavior; public distribution is pending release qualification.

## What stays on your Mac

Echo Voice stores recordings, transcripts, speaker labels, notes, vocabulary and annotations in its local application-data folder. It has no account system, analytics service, advertising SDK or hosted meeting backend. Inference uses local model files. The speech service binds to authenticated loopback access; optional Ollama notes connect only to the configured fixed local address, `127.0.0.1:11434`.

## Permissions and capture

Microphone access is used when you select a microphone and start recording. Online mode also uses system-audio access for the selected application. Browser capture may include other audible tabs in that browser. In-person mode does not request application-audio capture. Echo Voice has no screenshot or visual-context feature. Recording requires a consent acknowledgement; you are responsible for obtaining participants' permission.

## Network use

Explicit model setup and updates download data from the model hosts shown in Models settings. Those hosts receive ordinary connection information, such as IP address and requested model files, and apply their own policies. Gated downloads use a token provided during setup; optional persistence uses macOS Keychain. Inference workers are configured offline and do not receive model-access credentials. There is no cloud inference fallback.

Links to GitHub, model-access pages, support or future Store listings open external sites with their own policies. Your separately installed Ollama application has its own configuration; Echo Voice excludes known cloud-backed models and never manages that application's downloads.

## Retention and sharing

Meetings remain until you explicitly delete them. Deletion removes app-managed meeting records, media and pending work. Independent exports and system backups remain under your control. Export and library import operate on folders you select. Echo Voice does not automatically share recordings, transcripts or notes.

Local data is not separately encrypted by Echo Voice. macOS account access and optional FileVault protection apply. Generated labels and notes may be inaccurate; they are not verified identities or facts.

## Diagnostics and contact

Runtime failures can create local diagnostics. Inspect and redact logs before sharing them. Do not upload real meeting content in public issues. Use the repository support/security guidance at https://github.com/samarthmn/echo-voice. Support and privacy links are listed in the repository.
