# Cursor Click

I wanted one app for my auto clicker and Chrome sessions, so I put both in Cursor Click. The dashboard runs up to 40 separate browser sessions. I can work in the main Chrome window and mirror its clicks and keystrokes to background sessions, or run them all in the background.

The clicker stops if its target window closes or loses focus. It also pauses when the dashboard refreshes the tabs every eight hours.

## Screenshots

Three sessions running against the built-in test page.

![Cursor Click dashboard showing three active browser sessions](assets/dashboard-running.png)

The test page gives me a quick way to check clicks and keyboard input before using a real site.

![Built-in test page showing two clicks in the session counter](assets/local-test.png)

## Run it on a Mac

You'll need Node.js and the Xcode Command Line Tools. From the repo folder, run:

```sh
./build-macos.sh
open "dist/Cursor Click.app"
```

Try the built-in test page first. To use the auto clicker, give Cursor Click Accessibility permission, click **Start clicking**, and move the pointer over the target window during the floating five-second countdown. **Control-C** or **Stop clicking** stops it.

Cursor Click is macOS-only for now. [MIT License](LICENSE).
