# Homebrew cask for BellowFlow. Lives in a tap repository named
# github.com/xuancongwen/homebrew-bellowflow at Casks/bellowflow.rb; users then run
#   brew install --cask xuancongwen/bellowflow/bellowflow
#
# Homebrew downloads exactly one file per cask, so `url` must point at the whole
# DMG at a single address (Hugging Face, R2, S3...), not at the split parts on
# GitHub Releases. Update version, url, and sha256 for each release (`brew
# bump-cask-pr` or a step in the release workflow can do this).
cask "bellowflow" do
  version "1.0.0-rc.1"
  sha256 "f40899fdf18ed85a2b2a6c912010a2942921e0e31061936b5cc29f66c88333ca"

  url "https://huggingface.co/xuancongwen/bellowflow/resolve/v#{version}/BellowFlow-#{version}-macOS-arm64.dmg"
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
    On first launch grant Microphone and Accessibility, click Start, and
    press Control+Option+Space to dictate.
  EOS
end
