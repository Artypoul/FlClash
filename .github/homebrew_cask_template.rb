cask "flashco" do
  version "VERSION"

  on_macos do
    arch arm: "arm64", intel: "amd64"

    sha256 arm:   "ARM_SHA256",
           intel: "AMD_SHA256"

    url "https://github.com/Artypoul/Flashco/releases/download/v#{version}/Flashco-#{version}-macos-#{arch}.dmg"
  end

  name "Flashco"
  desc "Multi-platform proxy client based on ClashMeta"
  homepage "https://github.com/Artypoul/Flashco"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on :macos

  app "Flashco.app"

  postflight_steps do
    run "/usr/bin/xattr",
        args:           ["-rd", "com.apple.quarantine", "{{appdir}}/Flashco.app"],
        writable_paths: ["Flashco.app"],
        writable_base:  :appdir
  end

  uninstall quit: "com.follow.flashco"

  zap trash: [
    "~/Library/Application Support/com.follow.flashco",
    "~/Library/Caches/com.follow.flashco",
    "~/Library/Preferences/com.follow.flashco.plist",
    "~/Library/Saved Application State/com.follow.flashco.savedState",
  ]
end
