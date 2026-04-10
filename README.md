# zigxll-standalone

A standalone Excel XLL add-in built with [ZigXLL](https://github.com/AlexJReid/zigxll).

This is a **template repository**. [Create your own repo from this template](https://github.com/AlexJReid/zigxll-standalone/generate) to get started quickly.

## Cross-compilation setup

Although Excel XLL assemblies only run on Windows, on non-Windows platforms ZigXLL cross-compiles Windows XLL add-ins from macOS or Linux with the help of the most excellent [xwin](https://jake-shadle.github.io/xwin/).

**Windows:**
Skip this section.

**macOS:**
```bash
brew install xwin
xwin --accept-license splat --output ~/.xwin
```

**Linux:**
```bash
cargo install xwin
xwin --accept-license splat --output ~/.xwin
```

If Cargo isn't available, install Rust via [rustup.rs](https://rustup.rs/) or download a prebuilt binary from the [xwin releases page](https://github.com/Jake-Shadle/xwin/releases).

See the [ZigXLL README](https://github.com/AlexJReid/zigxll) for more details.

## Building the XLL

```bash
zig build
```

The XLL will be output to `zig-out/lib/standalone.xll`.

## RTD Server

This XLL includes a Timer RTD server that ticks a counter every ~2 seconds.

| ProgID | CLSID |
|--------|-------|
| `standalone.timer` | `{B2C3D4E5-F6A7-8901-2345-6789ABCDEF01}` |

The RTD server is registered automatically when the XLL is loaded into Excel (writes to `HKCU\Software\Classes`, no admin needed).

**Usage in Excel:**

- Direct RTD call: `=RTD("standalone.timer", , "tick")`
- Wrapper function: `=TIMER()`

## Adding more functions

Add your Excel functions to `src/functions.zig` using the function in that file as a guide.

## Try out the pre-built XLL

1. Go to the [Actions tab](../../actions) and click on the latest successful workflow run
2. Scroll down to the very bottom and download the **zigxll-standalone** artifact
3. Extract the XLL file from the zip to a safe location - desktop works
4. You will need to unblock it. More info: https://support.microsoft.com/en-gb/topic/excel-is-blocking-untrusted-xll-add-ins-by-default-1e3752e2-1177-4444-a807-7b700266a6fb
5. Double-click `standalone.xll` to load it into Excel
