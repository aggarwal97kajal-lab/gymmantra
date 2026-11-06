# User guide PDF

1. Run the `guide-shots` workflow (demo gym + real app screens drawn by `apps/mobile/test_guide`); pictures land on the `guide-shots` branch.
2. Unpack them to `/tmp/shots`, run `python3 conv.py` (resizes to JPEG), `python3 build.py` (HTML), then `node pdf.js` (Chromium/Playwright → `GymMantra_App_Guide.pdf`).
