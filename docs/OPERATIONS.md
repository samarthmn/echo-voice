# Operating and recovering Echo Voice

## Permissions and inputs

Grant microphone and system-audio access when macOS requests it. The app's Privacy Settings button opens the system controls. Relaunch after changing a permission if macOS requires it. In-person mode needs only microphone permission.

If a source is missing, open the meeting application, start its audio, and refresh the input list. Browser helper processes belong to their selected browser; unrelated audible tabs can be included. The input test is optional. For single-source recording, deliberately select the single-source option. Starting recording checks the actual selected devices.

Use headphones when acoustic conditions make speakerphone cancellation unreliable. Echo cancellation preserves both raw tracks and creates a separately labelled cleaned microphone track for recognition. Inspect the raw microphone when reviewing uncertain text; echo reduction is not guaranteed before the physical validation gate is passed.

## Interrupted capture

The app marks active meetings interrupted on startup and reconciles durable chunk sidecars. Recoverable completed chunks are attached to their meeting. A crash during an unfinished chunk retains its partial bytes and initial timing metadata and creates an explicit timeline gap; those unverified bytes are not treated as playable or transcribed audio. At most the open chunk on each track is affected by this boundary. Choose the interrupted meeting in New Meeting to resume, or finalize the saved material. Timeline gaps remain visible.

Device removal, selected-process changes, and sleep require attention. Use **Inputs…** to reselect the microphone or meeting application while recording; the healthy track can continue through a change to the other track. If the selected source is gone, choose a replacement explicitly. Echo Voice does not silently switch to another microphone or capture all system audio. Recheck inputs after sleep before resuming.

The recording's original live-transcription choice is durable. **Stop live transcription** is one-way for that meeting, including after pause/resume or crash recovery. A meeting that started without live transcription is transcribed after Stop. A temporary recognition-worker error does not count as an explicit stop.

Below 3 GB free, make room outside the active meeting's managed directory. Below 1 GB, capture stops and saved chunks remain. Do not delete or move database/media files to resolve space pressure while recording. Export or back up completed meetings, verify the copies, then delete through the app.

Completed registered audio chunks may be compressed losslessly in the background. Capture still budgets for uncompressed audio and bounded staging space. The app verifies the decoded checksum before publishing a compressed representation; interrupted publication retains a valid representation for recovery. Exports decode to ordinary CAF/WAV audio. Do not edit or remove managed compressed files directly, and do not assume an older app binary can open a compacted library.

Decoded playback files are disposable. Startup recovery and first playback remove stale decoded files from previous app sessions while preserving active readers. A resumed muted microphone does not need to be connected; its fresh format is checked again before unmuting.

## Processing failures

Audio remains available if the service exits or models are missing. Finish model setup or reinstall a damaged production app, then choose Generate / Retry. Retry uses persisted jobs and stable audio windows. Final transcript retries preserve corrected text. Worker failures do not replace recordings.

Speaker grouping can exceed the global memory/clustering budget on difficult long sessions. Use the 30-minute retry offered by the review screen. Labels are visibly scoped to each window and should not be treated as the same person across windows.

Notes can be partial when a stage fails. Review partial/outdated badges and follow evidence links. If a generation fails, completed versions remain available. Editing a transcript marks dependent notes outdated; regeneration saves a new version.

Choose Generate / Retry again to fill missing notes sections or request another draft for the same evidence. A saved partial draft and any edits remain in the version history. If microphone audio has no matching echo reference, that interval is shown as unprocessed and the raw microphone remains available for playback/export; the app does not silently transcribe echo-contaminated audio as a clean track.

## Setup failures

Setup is explicit and retryable. Check free space and connectivity. Gated model access can take time after accepting conditions; use a read token from the account that has access. Do not paste tokens into logs or source files. The app optionally keeps the token in macOS Keychain and excludes it from processing workers.

Production runtimes are included in the signed app and are updated with the app. Development runtime repair uses pinned source archives and dependency locks and is unavailable during recording or analysis. A failed model download is not marked ready. Model verification checks immutable revision metadata and content hashes.

Repair quarantines a model snapshot containing extra files or links and reuses only files whose content hashes match the pinned manifest. It never follows a link to modify an outside target. Interrupted repair resumes from the retained quarantine. Successful repair keeps unexpected files in quarantine for inspection; remove them only after confirming they are not needed.

## Export, delete, and backup

Each export has its own directory. Its manifest maps labelled audio chunks onto the original timeline, including gaps. Export completion is an atomic rename; failed partial staging is not presented as a completed export. A destination error leaves the meeting intact.

Deletion journals its operation before moving files. Startup finishes interrupted deletion or restores a failed operation according to the durable state. An independently created export is outside this deletion boundary. The operating system may retain backups or snapshots separately.

A damaged meeting-deletion journal or failed cleanup blocks operations, including background compression, for its owning meeting while healthy meetings remain available. Use **Retry deletion recovery** in the meeting or error message after resolving the reported file or space problem. Database-wide integrity failures still use the library recovery screen.

Passage deletion is a separate all-track interval operation. It stops conflicting playback and processing, removes overlapping transcript history and derived work, and leaves a timeline gap so later speech keeps its timestamp. If deletion is interrupted, the meeting blocks conflicting operations until **Retry deletion recovery** completes. There is no Undo after completion; use a separate verified backup if you need independent retention.

For a consistent backup, quit the app and copy `~/Library/Application Support/EchoVoice` to storage you control. Restore with the app closed. Copy the whole directory, not just `echo.sqlite`. Keep at least one verified backup before moving an existing library between Macs.

## Diagnostics

Record the visible error, app version, macOS version, selected device/application, and whether the issue occurred during capture or processing. Do not include private meeting content or tokens in a public issue. Development reports belong under project `tmp/`; keep only the files needed to reproduce the issue.
