# Cursor Click

I use one Chrome window and let background sessions follow my clicks and typing. The floating status panel shows Chrome launch progress. The built-in local test page opens by default and shows click and typed-character counts for each session.

![Three synchronized browser sessions running](assets/dashboard-running.png)

![Built-in page showing per-session click and typing totals](assets/local-test.png)

## Build and run

On a Mac with Node.js and the Xcode Command Line Tools, run this from the repository folder:

```sh
./build-macos.sh
open "dist/Cursor Click.app"
```

For auto clicking, allow **Terminal** under **System Settings → Privacy & Security → Accessibility**. Click **Start clicking** and move the pointer over your target during the five-second countdown. To stop, press **Control-C** or click **Stop clicking**.

Cursor Click is macOS-only. [MIT License](LICENSE).
