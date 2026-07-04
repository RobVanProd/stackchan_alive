# Companion C6 Evidence Bundle

- phase: `C6`
- producing_commit: `2519de33b1aea13f444b465d9c46207615a3bc51`
- producing_branch: `codex/companion-c6-gui-rehearsal`
- brain_supervisor_smoke_overall_ok: `true`
- gui_rehearsal_overall_ok: `true`
- diagnostics_exports_attached: `true`
- gui_rehearsal_stop_exit_codes: `0, 0`

## Gate

Start -> robot(sim) turn through the Python brain -> stop -> restart, driven from the GUI; exported diagnostics attached as evidence.

## Commands

- `.\gradlew.bat :app-desktop:brainSupervisorSmoke --rerun-tasks --stacktrace`
- `.\gradlew.bat :app-desktop:c6GuiRehearsalSmoke --rerun-tasks --stacktrace`
- `.\gradlew.bat :app-desktop:runtimeSmoke --rerun-tasks --stacktrace`
- `.\gradlew.bat check --stacktrace`
- `python -m unittest discover -s bridge -p 'test_*.py'`

## Artifacts

| Artifact | SHA256 | Bytes |
| --- | --- | ---: |
| `output/companion/c6-brain-supervisor/BRAIN_SUPERVISOR_SMOKE.json` | `dc2fbc06bc956f4ad872980fbd11da93e6bf241d50e838ba717243e791f8d685` | 5421 |
| `output/companion/c6-brain-supervisor/BRAIN_SUPERVISOR_SMOKE.md` | `9535c36a150003c8c92eb75c0c7fcef9f1ff44448331f7a1f21f7a18ce031ec8` | 1499 |
| `output/companion/c6-brain-supervisor/DIAGNOSTICS_EXPORT.json` | `2f92054c07942006e39b5b320911b58b6e899975a70023f13e897a5af2a44499` | 2314 |
| `output/companion/c6-gui-rehearsal/GUI_REHEARSAL.json` | `648f19fa4dae54485bae14753b07df9f58798a8110d0189f8f40e3c533586ffa` | 5389 |
| `output/companion/c6-gui-rehearsal/GUI_REHEARSAL.md` | `97804d9b19c8c3426c320176879039a4e6ade9ee4cff53a82b987cf97334779f` | 1454 |
| `output/companion/c6-gui-rehearsal/DIAGNOSTICS_EXPORT.json` | `98df53a35a470f56fda5ebf880cc77015921b5dbeb4d60f779eb6ede383db257` | 2313 |
