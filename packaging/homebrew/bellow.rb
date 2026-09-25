# Homebrew cask for Bellow. Lives in a tap repository named
# github.com/xuancongwen/homebrew-bellow at Casks/bellow.rb; users then run
#   brew install --cask xuancongwen/bellow/bellow
#
# The DMG is small (models download on first start), so the GitHub release asset
# is the download. For each release, set version and paste the hash from the
# release's .sha256 file (`brew bump-cask-pr` can do this too).
cask "bellow" do
  version "1.0.0-rc.6"
  sha256 "5f6bda2a938d1fbb7652ee14bbb71399178b417eb45a04f5993f3f15067d6daf"

  url "https://github.com/xuancongwen/bellow/releases/download/v#{version}/Bellow-#{version}-macOS-arm64.dmg"
  name "Bellow"
  desc "Local, private dictation with Whisper and a cleanup language model"
  homepage "https://xuancongwen.github.io/bellow/"

  livecheck do
    url "https://github.com/xuancongwen/bellow/releases"
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: ">= :ventura"

  app "Bellow.app"

  # Release candidates are ad-hoc signed; drop this once builds are notarized.
  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/Bellow.app"], sudo: false
  end

  uninstall quit: "org.bellow.app"

  zap trash: [
    "~/Library/Application Support/Bellow",
  ]

  caveats <<~EOS
    Bellow needs an Apple Silicon Mac with at least 8 GB of memory.
    On first launch grant Microphone and Accessibility and click Start; the app
    then downloads its models (2 to 3.4 GB, once). When it reads Ready, press
    Control+Option+X to dictate.
  EOS
end
