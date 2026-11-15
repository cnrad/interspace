cask "interspace" do
  version "1.0.0"
  sha256 "95ae279699865bfafcb189c108927e5588dcc57da1116dfe7b0e0321f2af0b3d"

  url "https://github.com/cnrad/interspace/releases/download/v#{version}/Interspace.dmg"
  name "Interspace"
  desc "Fast, customizable space switcher"
  homepage "https://github.com/cnrad/interspace"

  livecheck do
    url :url
    strategy :github_latest
  end

  # Check for Updates in the menu replaces the app in place.
  auto_updates true
  depends_on macos: ">= :sonoma"

  app "Interspace.app"

  # The same steps as scripts/uninstall.sh. Only the app can take itself out of the login items,
  # and macOS can only reset the permissions while it still knows the app.
  uninstall_preflight do
    system_command "#{appdir}/Interspace.app/Contents/MacOS/Interspace",
                   args:         ["--unregister-login-item"],
                   must_succeed: false
    system_command "/usr/bin/tccutil",
                   args:         ["reset", "Accessibility", "com.cnrad.interspace"],
                   must_succeed: false
    system_command "/usr/bin/tccutil",
                   args:         ["reset", "ScreenCapture", "com.cnrad.interspace"],
                   must_succeed: false
  end

  uninstall quit: "com.cnrad.interspace"

  zap trash: "~/Library/Preferences/com.cnrad.interspace.plist"
end
