# Live Photo Repair

A macOS app that finds Live Photos that were flattened into short videos (for example after a round trip through Google Photos) and turns them back into Live Photos, or into stills.

## Download

Get the latest `Live-Photo-Repair.zip` from the [Releases](../../releases) page, unzip it, and move **Live Photo Repair** to Applications. Requires macOS 15 or later on an Apple silicon or Intel Mac.

The app is not notarized by Apple, so macOS blocks it the first time. To open it:

1. Double-click the app, then click **Done** on the warning.
2. Open **System Settings > Privacy & Security**, scroll down, and click **Open Anyway** next to Live Photo Repair.

Or remove the quarantine flag from Terminal:

```bash
xattr -dr com.apple.quarantine "/Applications/Live Photo Repair.app"
```

## How it works

1. **Scan** finds videos between 0.8 and 4.5 seconds long and rates how likely each one is a former Live Photo:
   - camera evidence: the recording device in the movie's metadata, a camera filename like `IMG_1234.MOV`, or a GPS location
   - a typical Live Photo length (1.2 to 3.6 seconds)
   - an iPhone camera frame: 4:3 or 16:9 and at least 1080 pixels on the short side
   - a matching still: a 4:3 photo taken within 2 seconds, preferring one with the same filename (`IMG_1234.HEIC` and `IMG_1234.MOV`)

   High confidence items are checked automatically.
2. **Pick an action** for each item:
   - *Pair with original still*: full-resolution Live Photo made from the matching photo and the video.
   - *Rebuild Live Photo from video*: the key photo comes from a video frame (picked automatically with Vision's aesthetics score, or chosen by hand).
   - *Convert to still photo*: keeps only the chosen frame.
   - *Remove duplicate video*: used when the matching photo is already a working Live Photo.
3. **Repair** writes a new item to Photos. It keeps the original date, location, favorite and hidden state, and adds the item to the same albums.
4. **Remove Originals** moves the replaced items to Recently Deleted, after you have checked the results. macOS asks you to confirm.

You can also filter by confidence, sort by date, file size or length, **Ignore** videos you want to keep as they are (they stay ignored after a rescan), and **Delete** clips that were never Live Photos. Ignore and Delete are in the toolbar for checked items and in the right-click menu for a single video.

A Live Photo is a still and a QuickTime movie that share a content identifier (Apple maker note key `17` in the image, `com.apple.quicktime.content.identifier` in the movie), plus a `still-image-time` marker in the movie. The video samples are copied without re-encoding.

## Limits

- Photos can't convert an item in place, so each repair creates a new item. Named faces, captions and edits on the original are not carried over.
- A Live Photo rebuilt from the video alone has a still no sharper than the video (about 2 MP).
- With iCloud Photos turned on, originals are downloaded as needed and the changes sync to your other devices.
- Everything deleted goes to Recently Deleted, where it can be recovered for 30 days.

## Building

Requires macOS 15 or later and the Xcode Command Line Tools (`xcode-select --install`) or Xcode.

```bash
./build.sh
open "build/Live Photo Repair.app"
```

The first launch asks for Photos access. Test on a few items before repairing in bulk.

## License

MIT. See [LICENSE](LICENSE).
