# Play Store Assets

- `icon-512.svg` is the editable source for the Play high-resolution icon.
- `icon-512.png` is the 512 x 512 PNG upload asset.
- `feature-graphic-1024x500.png` is the Play feature graphic upload asset.
- `SCREENSHOT_CAPTURE_PLAN.md` defines the required final-build screenshot coverage.
- `docs/ANDROID_PLAY_PRIVACY_POLICY.md` is the reviewed policy record.
- `site/privacy/index.html` is the public policy page source for
  https://robvanprod.github.io/stackchan_alive/privacy/.
- `PRIVACY_POLICY_DEPLOYMENT.json` binds the live HTTPS response to its source hash,
  deployment commit, and GitHub Pages build.
- `tools/check_privacy_policy_deployment.ps1 -Json` re-fetches and verifies the live page.
- `.github/workflows/pages.yml` deploys the static policy site from `main`.

The visual language matches the in-app Stack-chan face preview: dark square
display, cyan display edge, white block eyes, black pupils, white brows, and pink
mouth.

Final store screenshots should be captured from the connected Android build after
physical robot validation rather than mocked from the simulator. V1 should capture
setup/pairing, live dashboard, Brain/model controls, and persona/diagnostics coverage.
