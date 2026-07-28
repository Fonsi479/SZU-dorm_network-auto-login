# Third-Party Notices

The project itself is licensed under the MIT License in `LICENSE`.

## SRun protocol fact cross-check

No third-party SRun implementation source is copied into this repository. The custom Base64 alphabet and black-box vectors were independently cross-checked against:

- `vidar-team/srun-login`, commit `5a453c5343c0cade8633b0c89607c2d2daa478b8`;
- file `internal/crypotoutil/base64.go` and its tests;
- upstream license: MIT.

These values are used only as protocol facts to verify this repository's clean-room implementation. The complete BX1 fixture uses synthetic inputs chosen for this project.

## Build/runtime dependencies

- Swift Testing, Apache-2.0;
- Python Requests, Apache-2.0;
- PyYAML, MIT;
- keyring, MIT;
- PyInstaller, GPL-2.0-or-later with its exception for distributing bundled applications;
- Pillow, HPND.

The generated SBOM records the resolved versions used for a release. A maintainer must recheck dependency license metadata before public distribution.
