**Install from the zip**

```sh
shasum -a 256 -c SHA256SUMS                   # verify the download against the published manifest
unzip wifiscan-*-macos-universal.zip
xattr -dr com.apple.quarantine wifiscan.app   # the app is ad-hoc signed; Gatekeeper quarantines downloads
mv wifiscan.app ~/Applications/
ln -sf ~/Applications/wifiscan.app/Contents/MacOS/wifiscan ~/.bin/wifiscan   # a launcher anywhere on your PATH
wifiscan --diag                               # first run registers it with Location Services
```

Universal app (Apple Silicon + Intel), macOS 12 or later. The scan must run from the `.app`
bundle (that is how macOS reveals SSIDs), so keep the bundle intact and symlink the launcher
rather than copying the binary out. Building from source with `make install` skips the
quarantine step and, with a personal signing certificate, keeps the Location grant across
upgrades — see the README.
