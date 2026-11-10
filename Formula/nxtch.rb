# Builds nxtch from source, the same way build.sh does by hand.
#   brew tap skyphose/nxtch https://github.com/skyphose/nxtch
#   brew install nxtch
class Nxtch < Formula
  desc "Per-app volume, a file shelf and clipboard history in the MacBook notch"
  homepage "https://github.com/skyphose/nxtch"
  url "https://github.com/skyphose/nxtch.git", tag: "v0.5.0"
  license "MIT"
  head "https://github.com/skyphose/nxtch.git", branch: "main"

  # Builds with the command line tools Homebrew already needs. Full Xcode is not required.
  depends_on macos: :sonoma

  def install
    # Ad hoc signature: the build has no access to your keychain.
    ENV["SIGN_ID"] = "-"
    system "./build.sh"
    prefix.install "Nxtch.app"
    libexec.install "build.sh"
    (bin/"nxtch").write <<~SH
      #!/bin/sh
      # nxtch              start it
      # nxtch --uninstall  remove settings, history and permissions (then: brew uninstall nxtch)
      APP="#{opt_prefix}/Nxtch.app"
      if [ "$1" = "--uninstall" ]; then
        NXTCH_APP="$APP" NXTCH_KEEP_APP=1 exec "#{opt_libexec}/build.sh" --uninstall
      fi
      exec open "$APP"
    SH
  end

  def caveats
    <<~EOS
      Start it with:
        nxtch
      macOS asks for audio and Accessibility again after every upgrade, because the build is
      signed ad hoc. Only approve those prompts right after an upgrade you ran yourself.

      brew uninstall leaves your settings and clipboard history behind. To remove them first:
        nxtch --uninstall
    EOS
  end

  test do
    assert_predicate prefix/"Nxtch.app/Contents/MacOS/Nxtch", :executable?
  end
end
