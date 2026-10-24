# media

the five-bar mark, wordmark, `showcase.svg`, and `social-preview.svg` are original artwork by hoang ngo, covered by the [mit license](../LICENSE). geometric shapes and system fonts only; no stock images or third-party logos. `social-preview.png` is a 1200 × 630 render of the svg, not an app screenshot.

```bash
rsvg-convert --width 1200 --height 630 --output media/social-preview.png media/social-preview.svg
```

## native captures

captured october 23, 2026 from macapy 0.1.0 (build 1), launched with `--sample` on macos. these show the final frontend-polish debug build in an uncommitted working tree based on `3fc079b`.

executable sha-256: `54561ff89d3e4754bd015d41b3546e5e8be1f68e6f9c3b74528de5ee32c846e6`.

| file | view |
|---|---|
| `sample-live.jpg` | live transcript and scripted catch-up answer |
| `sample-history.jpg` | saved transcript and reviewable outcomes |
| `sample-memory.jpg` | reviewed facts, pending memory, and source links |
| `sample-brief.jpg` | local brief for a fictional upcoming event |
| `sample-action-review.jpg` | exact reminder review; creation was not executed |

all five jpegs are direct native window captures. no generated content, compositing, retouching, or cropping. the workspaces are 1200 × 760; the review sheet is 600 × 519. native chrome and the pointer remain as captured. the titlebar’s purple screen-sharing indicator belongs to macos during inspection.

the sample reuses production views with in-memory stores and scripted adapters. people, meetings, documents, destinations, and replies are fictional. no microphone permission, speech installation, key, real meeting data, or external write was used. the readme and small workspace footer describe this boundary; the large sample badge was removed at the author’s request.

## visual tour

`sample-tour.mp4` and `sample-tour.gif` show the four workspace captures in the order above, twelve seconds each. **48 seconds, no audio, and no claim of real-time interaction or latency.** ffmpeg pads the original images to a 1200 × 772 white canvas without scaling. the mp4 uses h.264; the gif uses a reduced palette. the jpegs retain the sharpest text.

to reproduce: run `--sample`, choose catch up, then visit history, memory, and briefs. open an action’s reminder control and choose review exact item for the final sheet; stop before creation. these assets demonstrate the interface, not transcription accuracy, model quality, or live-provider performance.
