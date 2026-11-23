# LLMits

See how much of your Claude, ChatGPT and Cursor plans you've used, right in your Mac's menu bar.

The name is LLM + limits, and it's pronounced "limits".

<img src="docs/llmits-banner.png" alt="On the left, the LLMits menu bar icon, a grid of red dots beside 100%, above its open menu, which lists Claude's and ChatGPT's limits, each with a usage bar, a pace mark and a reset time. Top right: by default the icon shows your most urgent limit across your services. Its dots light up from the left, a column for every 20%, turn orange from 75% and all turn red from 90%. Bottom right: the Show in Menu Bar submenu with three limits ticked. Each becomes its own row of five dots, and together they make an icon showing 100%, the most urgent of the three." width="830">

## Install

You'll need:

- **macOS Sonoma 14.5 or later.**
- **Claude Code, the Codex CLI or Cursor (any of them), signed in.** LLMits uses their logins, so there's nothing else to set up. To keep a login current, use its tool now and then, and sign in again when it asks.
  - **For Claude:** install [Claude Code](https://code.claude.com), run `claude` and sign in with a Claude subscription such as Pro or Max (type `/login` if it doesn't ask).
  - **For ChatGPT:** install the [Codex CLI](https://github.com/openai/codex), then run `codex login` and sign in with your ChatGPT account.
  - **For Cursor:** install [Cursor](https://cursor.com) and sign in to the app.
- **Apple's Command Line Tools** (or Xcode), to build the app. If they're missing, macOS offers to install them; run the installer again once that's done.

Then paste this into Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/karannavani/llmits/main/install.sh | bash
```

In about a minute, it checks your Mac has what it needs, builds LLMits into the Applications folder in your home folder and opens it. You're welcome to [read the script](install.sh) first.

To start LLMits whenever you log in, choose **Launch at Login** from its menu.

## Using it

- **In the menu bar**, LLMits shows a small grid of dots and a percentage for your most urgent limit, across all your services. The grid lights up from the left as you use the limit, a column for each fifth. It turns **orange** at 75%, and at 90% every dot lights up **red**. (If a service rates a limit itself, LLMits uses that instead.)
- **To show other limits there**, tick up to three in **Show in Menu Bar** (choose **Most Urgent Limit** to go back). One alone fills the grid. With two or three, each gets its own row of five dots, a dot for each fifth used, that turns orange or red on its own, and the percentage is for the most urgent.
- **Click it** to see every limit, grouped by service, with a bar and its reset time.
- **The mark on each bar** shows how much of the time between resets has passed. A bar past its mark means you're using that limit faster than an even pace.
- **LLMits checks your usage every 5 minutes.** It also checks when you open the menu, wake your Mac or choose **Refresh** (Command-R), unless its numbers are under 2 minutes old.
- **If a check fails**, the last numbers stay, with a note saying what happened. After 15 minutes without an update, that service's bars grey out, and its dots in the menu bar fade.
- **Each service appears** within 5 minutes of you signing in to its tool. If you sign out or switch accounts, LLMits can take about 20 minutes to notice.
- **To quit**, choose **Quit LLMits**, or hold Command and drag the icon out of the menu bar. To open it again, search for LLMits in Spotlight.

## Troubleshooting

| What you see | What it means |
| --- | --- |
| No icon in the menu bar | LLMits may not be running: open it from Spotlight. If you use a menu bar manager such as Bartender or Ice, look in its hidden section. macOS also hides icons when the menu bar is crowded, especially beside the notch. On macOS Tahoe 26 or later, make sure LLMits is allowed in **System Settings > Menu Bar**. |
| A service is missing | Sign in to its tool (see [Install](#install)). A Codex login that uses an OpenAI API key has no ChatGPT plan limits to show. If you keep Codex's files somewhere other than `~/.codex`, install with `CODEX_HOME` set. For Cursor, LLMits reads the Cursor app's login, so sign in there (the `cursor-agent` CLI's login alone isn't read yet). |
| "Login expired. Run Claude Code to renew it." | Normal if you haven't used Claude Code for a while. Run it once (signing in again if it asks) and LLMits catches up within a minute. For ChatGPT, run Codex instead; for Cursor, open the Cursor app. |
| "Too many requests. Retrying at 21:15." | The service asked for fewer checks. LLMits waits until then, even after a restart, and longer (up to an hour) if it keeps happening. |
| "Couldn't read your Claude Code login. Trying again shortly." | The keychain (or Codex's login file) couldn't be read, for example straight after waking. LLMits tries again in a minute. |
| "You're offline. Retrying automatically." | LLMits tries again every minute. |
| The installer mentions Xcode or Swift | If it says Swift 6 or later is required, update the Command Line Tools in **System Settings > General > Software Update** (or Xcode, in the App Store). If it mentions Xcode's licence, run `sudo xcodebuild -license accept` and enter your Mac's password. Then run the installer again. |

LLMits logs a line for each check (never any login details). To see the last hour:

```bash
/usr/bin/log show --last 1h --predicate 'subsystem == "io.github.karannavani.llmits"'
```

## Update

Run the install command again. It installs the latest version, restarts LLMits and removes Claude Usage Bar (its old name) if you have it. If Claude Usage Bar started at login, turn on **Launch at Login** again from LLMits's menu, and remove the old entry in **System Settings > General > Login Items** if it's still there.

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/karannavani/llmits/main/install.sh | bash -s -- --uninstall
```

If you turned on Launch at Login, also remove LLMits in **System Settings > General > Login Items**.

## How it works

- **Claude:** LLMits reads the login Claude Code keeps in your keychain (the `Claude Code-credentials` item) with macOS's `security` tool, then asks `https://api.anthropic.com/api/oauth/usage`, the endpoint behind Claude Code's `/usage` command.
- **ChatGPT:** it reads the login the Codex CLI keeps in `~/.codex/auth.json`, then asks `https://chatgpt.com/backend-api/wham/usage`, the endpoint Codex uses. Codex shares these limits with other parts of your ChatGPT plan, such as ChatGPT Work.
- **Cursor:** it reads the login the Cursor app keeps in its settings database (`~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`, opened read-only), then asks `https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage`, the endpoint behind Cursor's own usage display. Some plans, such as Cursor included with SuperGrok, share their usage with another subscription; LLMits shows whatever cycle Cursor reports, weekly or monthly.
- **It only reads these logins.** It never renews or changes them; each tool renews its own when you use it.
- **It's light:** about 16 MB of memory (22 MB once you've opened the menu), and no CPU between checks.

### Privacy

Your Claude login is only ever sent to `api.anthropic.com`, your ChatGPT login only to `chatgpt.com`, and your Cursor login only to `api2.cursor.sh`. Apart from its settings, LLMits keeps only the last numbers it showed (and any wait a service asked for) and a log line for each check. It has no analytics or other network traffic.

## Design

LLMits follows Apple's [Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar) for menu bar extras:

- Its menu bar icon adapts to light, dark and tinted menu bars.
- Colour only ever means a warning, and a critical limit also lights all its dots.
- Every limit has a full VoiceOver description, with its usage, pace and reset time.
- Launch at Login stays off until you turn it on.
- The app icon is a layered Liquid Glass icon that adapts to each of macOS's icon styles.

## Development

```bash
git clone https://github.com/karannavani/llmits.git
cd llmits
./install.sh
```

Running `./install.sh` from a clone builds and installs that checkout. While you work, `swift test` runs the tests, and `swift run` starts the app without bundling it (so without Launch at Login or the section logos).

| Path | What's there |
| --- | --- |
| `Sources/UsageCore` | Each service's logins, requests and responses (`Claude/`, `ChatGPT/`, `Cursor/`), the `UsageTracker` that decides what to fetch and show, and formatting. No AppKit, and unit-tested. |
| `Sources/LLMits` | The menu bar item and its menu. |
| `Support` | The app's `Info.plist`; its icon, as made in Icon Composer (`AppIcon.icon`) and compiled (`CompiledIcon`); and the Claude, OpenAI and Cursor logos with their sources (`Logos`). |
| `scripts/build-app.sh` | Builds `build/LLMits.app`; `--install` also copies it to `~/Applications` and opens it. |
| `scripts/build-icon.sh` | Compiles `AppIcon.icon` into `CompiledIcon` (needs Xcode 26 or later). Run it after changing the icon and commit the result, so the app builds without Xcode. |
| `install.sh` | The one-line installer and uninstaller. |

## Disclaimer

LLMits is unofficial and not affiliated with or endorsed by Anthropic or OpenAI. It's also not affiliated with Anysphere (Cursor) or xAI. It relies on undocumented endpoints, so it may stop working at any time. Claude and the Claude logo are trademarks of Anthropic; ChatGPT, Codex and the OpenAI logo are trademarks of OpenAI; Cursor and the Cursor logo are trademarks of Anysphere. The logos in [`Support/Logos`](Support/Logos) come from each company's own brand resources and aren't covered by the MIT licence.

## Licence

[MIT](LICENSE)
