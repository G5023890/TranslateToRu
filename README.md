# TranslateToRu

Local macOS translator for selected text. Uses NLLB-200 distilled 600M (CTranslate2 int8) for fast offline translation to Russian. Supports English and Hebrew sources.

## Quick start

1. Install model + tokenizer (creates local venv and downloads files):

```bash
cd "/Users/grigorymordokhovich/Documents/Develop/Translate/TranslateToRu"
./scripts/setup_nllb.sh
```

2. Build the app:

```bash
./scripts/build_app.sh
```

3. Run:
- Open `dist/TranslateToRu.app`
- Open **Settings** and click **Auto-fill paths**
- Click **Use NLLB Command** and **Save**

## Settings fields

- **Local Command (NLLB)**
  - Template with variables `{src}`, `{dst}`, `{models}`, `{max_chars}`
- **Scripts path**
  - Example: `/Users/grigorymordokhovich/Documents/Develop/Translate/TranslateToRu/scripts`
- **Models path**
  - Example: `/Users/grigorymordokhovich/Documents/Develop/Translate/TranslateToRu/models`
- **Max chars per chunk**
  - Default `2000` (auto-splitting and stitching)

## Notes

- Hebrew is translated via chain: `he -> en -> ru`.
- Models and venv are kept local and ignored by git.

## Uninstall old apps

```bash
./scripts/uninstall_previous_apps.sh
```

## Troubleshooting

**Translation error: path not found**
- Open Settings and click **Auto-fill paths**, then **Use NLLB Command** and **Save**.
- Make sure these are valid:
  - `scripts_path`
  - `models_path`

**Current working directory missing**
- The project moved. Use the new root:
  - `/Users/grigorymordokhovich/Documents/Develop/Translate/TranslateToRu`

**Tokenizer missing lang_code_to_id**
- The app forces the non-fast tokenizer, and has a fallback for language tokens.
- If error persists, re-run `./scripts/setup_nllb.sh`.

**Slow or truncated output**
- Increase **Max chars per chunk** in Settings.
