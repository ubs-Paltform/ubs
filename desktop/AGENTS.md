# Desktop GUI contract

- Keep the frontend dependency-free: plain HTML, CSS, and JavaScript only.
- Keep `build.sh` as the only build engine. The Rust bridge may pass only fixed flags and allow-listed values.
- Never enable publishing from the GUI. Preserve single-build locking and process-group cancellation.
- Keep `ko`, `en`, `ja`, and `zh` catalog keys identical; English is the fallback.
- Run `bash tests/test-desktop-gui.sh` and `cargo test --manifest-path desktop/src-tauri/Cargo.toml --locked --all-targets` after changes.
