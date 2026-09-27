# Using Echo Voice

## Set up

The **Setup Guide** opens on first launch while no speech model is ready. Its steps are: welcome, runtime check, speech model, optional notes and speaker grouping, permissions, and a summary. Nothing downloads and no permission prompt appears until you click the matching button. **Skip Setup** closes it; reopen it from **Help → Setup Guide…**, the sidebar status indicator, or **Settings → General**.

The sidebar status indicator summarises readiness: **Ready to record**, **Setup required** (no speech model yet), **Downloading n%**, **Microphone access needed** or **Library needs attention**. Click it for the checklist with the next action for each item. The menu bar item shows the same status.

Downloads run one at a time. Each shows a progress bar, the bytes transferred, and a cancel control; cancelling keeps verified files for a later retry. You can keep browsing and reviewing while a model downloads, but recording and processing wait until the download finishes or is cancelled, because installs restart the local runtime. The New Meeting button explains this while it is unavailable. A speech model downloaded from the guide becomes the default automatically. In Settings, a download replaces the default only when the current default cannot run yet; a task you turned off stays off.

### Permissions

**Settings → Audio & Permissions** and the Setup Guide show each permission. Microphone access shows Granted, Not yet allowed (with **Allow Access**) or Denied (with **Open System Settings**), and updates when you return from System Settings. macOS offers no way to check selected-app audio access in advance, so that row shows the last observed result: it is marked working after meeting audio is actually captured, and blocked if creating the application audio tap fails. It is not needed for in-person recordings.

## Choose a recording mode

**Online meeting** records the selected meeting application's output and your selected microphone. Choose the browser for Google Meet, or the Zoom/Teams application. Other audible browser tabs may be included. With headphones, leave speakerphone processing off. With Mac speakers, enable echo cancellation to create a separate cleaned microphone track; both raw tracks remain intact. A single-source online recording requires an explicit choice.

Speakerphone processing requires both a selected microphone and meeting application. A microphone-only recording uses raw microphone audio for transcription.

Changing the listening setup preserves your latest microphone mute choice, including a mute requested while the input is restarting.

**In person** records only the selected microphone. The built-in input is preferred initially; the selected device is shown. No meeting application or system-audio permission is needed. Echo cancellation is off because there is no remote reference. Speaker grouping processes the room microphone after recording. Labels are generic and overlap may remain uncertain; this is attribution, not isolated voice extraction.

Acknowledge recording consent before starting. **Test audio inputs — optional** can help troubleshoot a device, but it is not a prerequisite. Startup opens the selected devices and estimates storage using their real formats. Missing models do not prevent durable recording.

The new-meeting sheet has a **Live transcription** switch, on by default. Turn it off before starting if you want to see the transcript only after recording ends. If you start with it on, **Stop live transcription** in the recording controls stops new live recognition for the rest of that meeting; recording continues, existing text stays visible, and final processing fills the remainder after Stop. Pausing, resuming, or recovering the meeting cannot restart live transcription. The switch is available only before a new recording, not while recording or when resuming an interrupted meeting.

You can start with the Echo Voice microphone muted, or use the microphone button during recording. This affects Echo Voice capture only; it does not mute your microphone in Meet, Zoom, Teams, or another app. The selected application keeps recording, and muted microphone time remains a gap. Use **Inputs…** during recording to choose a different microphone or application, or to select **Speakerphone** when Mac speakers replace headphones. Echo Voice does not silently substitute an input or broaden capture if a selected source disappears.

## Models in the workspace

Welcome shows defaults for new meetings. The setup sheet shows the choices about to be saved. The recording header shows the saved configuration. Review shows the active transcript and displayed notes version; “Selected” means a model has not produced that result yet. Unknown historical provenance is “Not recorded.” Model details contain exact revisions or Ollama digests.

Click a model item to open its settings section. Browsing models does not change defaults. Use **Use as Default** explicitly. The New Meeting sheet marks speech models that are not downloaded and preselects a downloaded one when your default is not ready. Native models can be downloaded, verified or removed. Saved text survives model removal; queued jobs require their original model. Ollama models are managed by Ollama and cannot be downloaded or removed by Echo Voice.

Notes use either Native or a local Ollama instance at `127.0.0.1:11434`. Select a compatible local generation model. No automatic provider fallback occurs. Configure Ollama's own cloud features off if they are enabled; Echo Voice does not modify another application's settings.

## Review and replay

Replay is available after recording ends. Conversation combines the appropriate tracks; in-person Conversation uses the room microphone. Click a word or timestamp to seek. The active passage and usable aligned words follow playback. Some Parakeet timing is approximate; edited/unaligned passages use passage timing.

Manual scrolling or selecting text stops auto-follow. Choose **Follow playback** to resume. Change speed or jump five seconds from the player. Select text to save a highlight; filtering to highlights does not skip unhighlighted audio. Bookmark any point, including silence or a gap.

Speaker labels do not verify identity. Rename a label for readability. Where word timings support a speaker change, the passage exposes the attribution boundaries without changing its text or evidence anchors.

After a meeting, choose **Review speakers** to hear short samples of each locally grouped voice and edit its meeting-scoped label. If grouping was off when you recorded, you can run it for the existing transcript. Overlapping or uncertain voices are marked; a label is not proof of a person's identity.

The trash icon beside a passage's edit control permanently deletes that time interval from all Echo Voice managed audio tracks, including any simultaneous speech, and from transcript history. The confirmation shows the interval and affected material. Reliable words outside a deleted interval can remain as separate passages; an overlapping passage without reliable word timing is removed in full, as the confirmation explains. Later timestamps stay fixed. Deletion is unavailable while recording and has no Undo. Existing exports, external backups, and filesystem snapshots are outside the app's deletion scope.

Deletion also removes recognition metadata derived from that interval. For older transcripts whose original recognition metadata has no reliable source timing, that metadata is cleared throughout the meeting; retained passage text and word timing remain available.

## Vocabulary and regeneration

Add preferred spellings and literal “Heard as” aliases in **Settings → Vocabulary**. Whisper also receives bounded vocabulary hints; Parakeet applies text corrections. Optional similar-sounding correction is off by default. Entries are snapshotted for each transcription run.

**Regenerate transcript…** creates a version from saved audio. Current text remains available on failure/cancellation. Previous edits, notes and annotations remain in history. Activate a completed version when playback/editing is finished. Notes regeneration is separate; changed transcript or speaker evidence marks existing notes outdated.

## Import a library

In an empty installation, use **Settings → Storage → Import Echo Voice Library…**. Quit the source app and select its complete `EchoVoice` data folder, not an export directory. Import snapshots its database, copies media, verifies registered audio checksums, and leaves the source intact. Quit and reopen the destination app to finish the journaled switch.

This supports moving a Direct library into a Store container through a user-selected folder. It does not merge two nonempty libraries, import executable runtimes or copy model credentials. Existing destination models remain separate. Never run both installations against the same library.

Completed recordings may use lossless managed compression to reduce disk use. Playback and exports still use the original audio samples; exported audio is an ordinary playable file. Keep a backup before opening a compacted library with an older Echo Voice build, because older builds may not understand the newer storage representation.
