# Homebrew cask for BellowFlow. Lives in a tap repository named
# github.com/xuancongwen/homebrew-bellowflow at Casks/bellowflow.rb; users then run
#   brew install --cask xuancongwen/bellowflow/bellowflow
#
# The DMG is small (models download on first start), so the GitHub release asset
# is the download. For each release, set version and paste the hash from the
# release's .sha256 file (`brew bump-cask-pr` can do this too).
cask "bellowflow" do
  version "1.0.0-rc.2"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000" # from BellowFlow-#{version}-macOS-arm64.dmg.sha256

  url "https://github.com/xuancongwen/bellowflow/releases/download/v#{version}/BellowFlow-#{version}-macOS-arm64.dmg"
  name "BellowFlow"
  desc "Local, private dictation with Whisper and a cleanup language model"
  homepage "https://xuancongwen.github.io/bellowflow/"

  livecheck do
    url "https://github.com/xuancongwen/bellowflow/releases"
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: ">= :ventura"

  app "BellowFlow.app"

  # Release candidates are ad-hoc signed; drop this once builds are notarized.
  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/BellowFlow.app"], sudo: false
  end

  uninstall quit: "org.bellowflow.app"

  zap trash: [
    "~/Library/Application Support/BellowFlow",
  ]

  caveats <<~EOS
    BellowFlow needs an Apple Silicon Mac with at least 16 GB of memory.
    On first launch grant Microphone and Accessibility and click Start; the app
    then downloads its models (about 5.3 GB, once). When it reads Ready, press
    Control+Option+Space to dictate.
  EOS
end
